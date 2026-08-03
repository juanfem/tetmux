import Foundation

/// Owns every control-mode channel and the model derived from it.
///
/// One channel per host serves as both command plane and output plane for the attached session
/// (Phase 0, Spike 2). All session logic lives here exactly once: local and remote differ only in
/// which process `PtyTransport` spawns.
public actor SessionService {
    // MARK: - Stored state

    private var hosts: [String: HostState] = [:]
    private var hostOrder: [String] = []
    private var connections: [String: Connection] = [:]
    private var stateContinuations: [UUID: AsyncStream<[HostState]>.Continuation] = [:]
    private var diagnosticLogger: (@Sendable (String) -> Void)?

    /// Repaint budget for `capture-pane` on reattach (F4.16).
    private let captureScrollbackLines = 2000
    /// Keystrokes are coalesced into one `send-keys` per display frame (§3.2, P6.4).
    private let keyFlushInterval = Duration.milliseconds(8)
    /// Resize requests are debounced and coalesced (§3.3).
    private let resizeDebounce = Duration.milliseconds(100)
    /// Anything larger goes through a paste buffer instead of `send-keys` (§3.2).
    private let pasteThreshold = 512
    /// Ceiling on one `set-buffer` command line. A clipboard can hold megabytes, and one command line
    /// that size is a single write the pty has to absorb before anything else moves.
    private let pasteChunkBytes = 4096
    /// Names each paste's buffer uniquely.
    private var pasteSequence = 0


    public init() {}

    // MARK: - Connection bookkeeping

    /// A live channel. Reference type so the many small mutations below do not each rewrite a
    /// struct back into the dictionary; it never escapes the actor.
    private final class Connection {
        let epoch = UUID()
        let transport: PtyTransport
        let sessionTarget: String
        var codec = ControlCodec()
        var version: TmuxVersion?

        /// Commands we have written and are awaiting a `%begin` block for, in the order tmux will
        /// answer them. tmux command numbers are server-wide and start at an arbitrary value, so
        /// they cannot be predicted — but responses are strictly ordered, which is enough.
        var pending: [PendingCommand] = []
        var current: PendingCommand?

        /// tmux emits one `%begin`/`%end` block of its own on attach, before we can write anything.
        /// Writing before it lands would misalign `pending` by one for the life of the channel, so
        /// commands wait here until the handshake completes.
        var handshakeComplete = false
        var outbox: [PendingCommand] = []
        /// Raw bytes seen before the protocol started — an ssh banner, a password prompt, a
        /// host-key warning. Surfaced verbatim if the channel dies without ever speaking tmux.
        var preHandshakeLog: [UInt8] = []

        var readTask: Task<Void, Never>?
        var rttTask: Task<Void, Never>?
        var keyFlushTask: Task<Void, Never>?
        var resizeTask: Task<Void, Never>?
        var topologyRefreshTask: Task<Void, Never>?

        /// Whether a secret has already been written on this channel. One attempt per channel: a
        /// rejected password answered again is how accounts get locked out, and the retry the user
        /// really wants is a fresh connection with a fresh prompt.
        var answeredPrompt = false
        /// The prompt we have already told the UI about, so the same bytes arriving in a later read
        /// do not raise it twice.
        var reportedPrompt: AuthenticationPrompt.Kind?

        var pendingKeys: [String: [UInt8]] = [:]
        var repaintedPanes: Set<String> = []

        var desiredSize: (cols: Int, rows: Int)?
        var lastSentSize: (cols: Int, rows: Int)?
        var userInitiatedDisconnect = false

        /// Whether this session's windows are sized individually (`window-size manual`) rather than
        /// from the client's size. Needs tmux 2.9; below that there is one size for everything.
        var sizesWindowsIndividually = false
        /// Per-window sizes requested by whichever macOS window is showing each tmux window.
        var desiredWindowSizes: [String: (cols: Int, rows: Int)] = [:]
        var lastSentWindowSizes: [String: (cols: Int, rows: Int)] = [:]
        /// Which view owns each tmux window's size.
        ///
        /// One tmux window can be on screen in two macOS windows of different sizes. Letting both
        /// drive `resize-window` makes them fight: each `%layout-change` prompts the other to ask for
        /// its own size back, forever. The focused view owns the size; the other letterboxes.
        var windowSizeOwners: [String: UUID] = [:]
        var windowResizeTask: Task<Void, Never>?

        init(transport: PtyTransport, sessionTarget: String) {
            self.transport = transport
            self.sessionTarget = sessionTarget
        }

        func cancelTimers() {
            rttTask?.cancel()
            keyFlushTask?.cancel()
            resizeTask?.cancel()
            windowResizeTask?.cancel()
            topologyRefreshTask?.cancel()
        }
    }

    private struct PendingCommand {
        let text: String
        let kind: Kind
        var lines: [Data] = []

        enum Kind {
            /// A block we did not originate (the attach handshake) or whose result we ignore.
            case ignore
            case version
            case listSessions
            case listWindows
            case listPanes
            case listClients
            /// `target` scopes the repaint to a single subscriber. The same pane can be on screen in
            /// two macOS windows, and the payload begins by clearing the screen *and* the scrollback —
            /// broadcasting a late joiner's repaint would wipe the history the other window is holding.
            case capturePane(paneId: String, target: UUID?)
            case roundTrip(sentAt: ContinuousClock.Instant)
        }
    }

    private var reconnectAttempts: [String: Int] = [:]

    private var outputSubscribers: [String: [String: [UUID: AsyncStream<Data>.Continuation]]] = [:]
    /// The session to reattach to when a channel is re-established, by host.
    ///
    /// Not the same thing as the target the *first* connect used: `switch-client` moves the client,
    /// and control mode streams `%output` only for the attached session. Reattaching to the
    /// original target after a drop would silently strand the user on a session whose panes repaint
    /// once and then never move again. Kept as a name rather than a `$id` so it still resolves if
    /// the tmux server was restarted underneath us.
    private var reconnectTarget: [String: String] = [:]

    // MARK: - Host registry

    public func addHost(_ config: HostConfig) {
        if hosts[config.id] == nil {
            hostOrder.append(config.id)
        }
        // Preserve live connection state if the host is merely being re-registered.
        if var existing = hosts[config.id] {
            existing.config = config
            hosts[config.id] = existing
        } else {
            hosts[config.id] = HostState(config: config)
        }
        broadcastState()
    }

    public func getHosts() -> [HostState] {
        hostOrder.compactMap { hosts[$0] }
    }

    public func getHost(_ hostId: String) -> HostState? {
        hosts[hostId]
    }

    public func removeHost(hostId: String) {
        disconnectHost(hostId: hostId)
        finishSubscribers(hostId: hostId)
        reconnectTarget.removeValue(forKey: hostId)
        hosts.removeValue(forKey: hostId)
        hostOrder.removeAll { $0 == hostId }
        broadcastState()
    }

    public func stateStream() -> AsyncStream<[HostState]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: [HostState].self)
        stateContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateContinuation(id) }
        }
        continuation.yield(getHosts())
        return stream
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    public func setDiagnosticLogger(_ logger: (@Sendable (String) -> Void)?) {
        diagnosticLogger = logger
    }


    private func broadcastState() {
        let snapshot = getHosts()
        for continuation in stateContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private func log(_ message: @autoclosure () -> String) {
        diagnosticLogger?(message())
    }

    // MARK: - Connecting

    /// Opens a control-mode channel to `hostId`.
    ///
    /// Idempotent: calling it for a host that is already connecting or connected does nothing, so
    /// wake/network notifications and impatient clicking cannot spawn duplicate channels.
    public func connectHost(
        hostId: String,
        targetSession: String? = nil,
        attachOnly: Bool = false
    ) async throws {
        guard var host = hosts[hostId] else { return }
        if let existing = connections[hostId] {
            if host.connectionState.isActive { return }
            teardown(hostId: hostId, connection: existing)
        }

        let sessionTarget = targetSession ?? reconnectTarget[hostId] ?? defaultSessionName(for: host.config)
        reconnectTarget[hostId] = sessionTarget
        host.connectionState = .connecting
        hosts[hostId] = host
        broadcastState()

        let transport = PtyTransport()
        let connection = Connection(transport: transport, sessionTarget: sessionTarget)

        do {
            let (executable, arguments) = try invocation(for: host.config, sessionTarget: sessionTarget, attachOnly: attachOnly)
            log("[\(hostId)] spawn \(executable) \(arguments.map { "\"\($0)\"" }.joined(separator: " "))")

            let stream = try transport.spawn(
                executable: executable,
                arguments: arguments,
                environment: childEnvironment(),
                initialSize: (cols: 200, rows: 50)
            )
            connections[hostId] = connection

            let epoch = connection.epoch
            connection.readTask = Task { [weak self] in
                do {
                    for try await data in stream {
                        await self?.ingest(hostId: hostId, epoch: epoch, data: data)
                    }
                    await self?.channelClosed(hostId: hostId, epoch: epoch, error: nil)
                } catch {
                    await self?.channelClosed(hostId: hostId, epoch: epoch, error: error)
                }
            }
        } catch {
            host.connectionState = .failed(reason: describe(error))
            hosts[hostId] = host
            broadcastState()
            throw error
        }
    }

    public func disconnectHost(hostId: String) {
        guard let connection = connections[hostId] else { return }
        connection.userInitiatedDisconnect = true
        restoreWindowSizePolicy(hostId: hostId, connection: connection)
        teardown(hostId: hostId, connection: connection)
        reconnectAttempts[hostId] = 0
        withHost(hostId) { $0.connectionState = .disconnected }
    }

    private func defaultSessionName(for config: HostConfig) -> String {
        "tetmux-main"
    }

    private func invocation(
        for config: HostConfig,
        sessionTarget: String,
        attachOnly: Bool
    ) throws -> (executable: String, arguments: [String]) {
        if config.isLocal {
            guard let tmux = PtyTransport.resolveExecutable("tmux", path: searchPath()) else {
                throw PtyError.executableNotFound("tmux")
            }
            return (tmux, TmuxCommand.localArguments(sessionName: sessionTarget, attachOnly: attachOnly))
        }

        let remoteCommand = TmuxCommand.remoteCommand(sessionName: sessionTarget, attachOnly: attachOnly)

        if let custom = config.customCommand, !custom.isEmpty {
            // The user's wrapper replaces ssh entirely; we still append our own tmux invocation so
            // the control-mode contract is identical.
            return ("/bin/sh", ["-c", "\(custom) \(TmuxCommand.quote(remoteCommand))"])
        }

        return ("/usr/bin/ssh", TmuxCommand.sshArguments(
            destination: config.sshDestination,
            port: config.port,
            controlPath: try controlPath(),
            remoteCommand: remoteCommand,
            forwards: config.forwards,
            expectsPasswordPrompt: config.usesPassword
        ))
    }

    /// `ControlMaster` socket location. Kept short deliberately: a unix socket path is capped at
    /// 104 bytes, and `~/Library/Application Support/…` plus ssh's 40-character `%C` hash runs
    /// close enough to that ceiling to fail on long usernames.
    private func controlPath() throws -> String {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("tetmux", isDirectory: true)
        // ssh will not create this itself; without it ControlMaster silently degrades.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("cm-%C").path
    }

    private func searchPath() -> String {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        // A GUI app launched from Finder inherits a minimal PATH that has no Homebrew in it.
        return "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + inherited
    }

    private func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath()
        // T5.1: what the panes advertise. tmux passes this through to programs inside them.
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        return env
    }

    private func describe(_ error: Error) -> String {
        (error as? PtyError)?.description ?? error.localizedDescription
    }

    // MARK: - Reading

    private func ingest(hostId: String, epoch: UUID, data: Data) {
        guard let connection = connections[hostId], connection.epoch == epoch else { return }

        if !connection.handshakeComplete {
            connection.preHandshakeLog.append(contentsOf: data)
            if connection.preHandshakeLog.count > 8192 {
                connection.preHandshakeLog.removeFirst(connection.preHandshakeLog.count - 8192)
            }
            detectAuthenticationPrompt(hostId: hostId, connection: connection)
        }

        let events = connection.codec.feed(data)
        guard !events.isEmpty else { return }

        let before = hosts[hostId]
        for event in events {
            handle(event, hostId: hostId, connection: connection)
        }
        // Only topology changes redraw the UI. Broadcasting on every %output would rebuild the
        // whole SwiftUI tree for each chunk of terminal output, which tears down the very terminal
        // views the output is meant to be painting into.
        if hosts[hostId] != before {
            broadcastState()
        }
    }

    private func handle(_ event: ControlEvent, hostId: String, connection: Connection) {
        switch event {
        case .begin(_, let number, _):
            log("[\(hostId)] %begin \(number)")
            connection.current = connection.pending.isEmpty ? PendingCommand(text: "", kind: .ignore) : connection.pending.removeFirst()

        case .commandResultLine(_, _, let bytes):
            connection.current?.lines.append(bytes)

        case .end:
            let completed = connection.current
            connection.current = nil
            if let completed {
                complete(completed, hostId: hostId, connection: connection)
            }
            completeHandshakeIfNeeded(hostId: hostId, connection: connection)

        case .error(_, let number, _):
            let failed = connection.current
            connection.current = nil
            let message = (failed?.lines ?? []).map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
            log("[\(hostId)] %error \(number): \(message)")
            if let failed, case .capturePane(let paneId, _) = failed.kind {
                // The pane vanished between subscribe and capture; let a later attempt retry.
                connection.repaintedPanes.remove(paneId)
            }
            completeHandshakeIfNeeded(hostId: hostId, connection: connection)

        case .output(let paneId, let data), .extendedOutput(let paneId, _, let data):
            deliver(data, hostId: hostId, paneId: paneId)

        case .layoutChange(let windowId, let layout, _, _):
            withHost(hostId) { host in
                Self.mutateWindow(&host, windowId: windowId) { $0.apply(layoutString: layout) }
            }

        case .windowAdd(let windowId):
            withHost(hostId) { host in
                Self.mutateWindow(&host, windowId: windowId) { _ in }
            }
            scheduleTopologyRefresh(hostId: hostId)

        case .windowClose(let windowId), .unlinkedWindowClose(let windowId):
            forgetWindowGeometry(hostId: hostId, windowId: windowId)
            withHost(hostId) { host in
                for index in host.sessions.indices {
                    host.sessions[index].windows.removeAll { $0.id == windowId }
                    if host.sessions[index].activeWindowId == windowId {
                        host.sessions[index].activeWindowId = host.sessions[index].windows.first?.id
                    }
                }
            }

        case .windowRenamed(let windowId, let name), .unlinkedWindowRenamed(let windowId, let name):
            withHost(hostId) { host in
                Self.mutateWindow(&host, windowId: windowId) { $0.name = name }
            }

        case .windowPaneChanged(let windowId, let paneId):
            withHost(hostId) { host in
                Self.mutateWindow(&host, windowId: windowId) { window in
                    window.activePaneId = paneId
                    for index in window.panes.indices {
                        window.panes[index].isActive = window.panes[index].id == paneId
                    }
                }
            }

        case .sessionChanged(let sessionId, let name):
            withHost(hostId) { host in
                for index in host.sessions.indices {
                    host.sessions[index].isAttached = host.sessions[index].id == sessionId
                }
                if let index = host.sessions.firstIndex(where: { $0.id == sessionId }) {
                    host.sessions[index].name = name
                } else {
                    host.sessions.append(TmuxSession(id: sessionId, name: name, isAttached: true))
                }
                host.activeSessionId = sessionId
            }
            // Where a reconnect has to land. `switch-client` arrives here too, so this tracks the
            // session the client is really on rather than the one it originally attached to.
            reconnectTarget[hostId] = name
            // `window-size` is a session option, so the session we just moved to needs it too.
            applyWindowSizePolicy(hostId: hostId, connection: connection)
            // The client just moved to a different session. Panes we are already showing belong to
            // the old one and will go silent, and panes in the new one have sent us nothing yet, so
            // everything on screen needs repainting from tmux's scrollback.
            repaintSubscribedPanes(hostId: hostId)
            scheduleTopologyRefresh(hostId: hostId)

        case .sessionRenamed(let sessionId, let name):
            withHost(hostId) { host in
                let target = sessionId ?? host.activeSessionId
                guard let target, let index = host.sessions.firstIndex(where: { $0.id == target }) else { return }
                host.sessions[index].name = name
            }
            // A rename of the session we are attached to has to move the reconnect target with it.
            syncReconnectTarget(hostId: hostId)

        case .sessionWindowChanged(let sessionId, let windowId):
            withHost(hostId) { host in
                guard let index = host.sessions.firstIndex(where: { $0.id == sessionId }) else { return }
                host.sessions[index].activeWindowId = windowId
                for windowIndex in host.sessions[index].windows.indices {
                    host.sessions[index].windows[windowIndex].isActive =
                        host.sessions[index].windows[windowIndex].id == windowId
                }
            }

        case .sessionsChanged, .unlinkedWindowAdd:
            scheduleTopologyRefresh(hostId: hostId)

        case .pause(let paneId):
            log("[\(hostId)] flow control paused for \(paneId)")

        case .continuePane(let paneId):
            log("[\(hostId)] flow control resumed for \(paneId)")
            // Whatever was dropped while paused has to come from the pane itself.
            connection.repaintedPanes.remove(paneId)
            requestRepaint(hostId: hostId, paneId: paneId)

        case .clientDetached, .clientSessionChanged:
            break

        case .exit(let reason):
            log("[\(hostId)] %exit \(reason ?? "")")
            withHost(hostId) { host in
                host.connectionState = .degraded(reason: reason ?? "tmux server exited")
            }

        case .unknownNotification(let line):
            // R3.3: unknown notifications are logged and ignored, never fatal.
            log("[\(hostId)] unhandled notification: \(line)")
        }
    }

    // MARK: - Authentication prompts

    /// Notices that ssh is sitting on a prompt and publishes it, so something with a keyboard can
    /// answer. Without this a GUI simply hangs at "Connecting…" until ssh gives up: the prompt is on
    /// a pty nobody is looking at.
    private func detectAuthenticationPrompt(hostId: String, connection: Connection) {
        guard !connection.answeredPrompt else { return }
        guard let kind = SshPromptDetector.pendingPrompt(in: connection.preHandshakeLog) else { return }
        guard connection.reportedPrompt != kind else { return }
        connection.reportedPrompt = kind

        let text = SshPromptDetector.promptText(in: connection.preHandshakeLog) ?? "Password:"
        log("[\(hostId)] ssh is waiting on a \(kind == .password ? "password" : "key passphrase") prompt")
        withHost(hostId) { host in
            host.authenticationPrompt = AuthenticationPrompt(kind: kind, text: text)
        }
        // Broadcast here rather than leaving it to `ingest`: a prompt produces no protocol events at
        // all, and `ingest` returns before its diff when the codec yielded nothing. This fires once
        // per prompt, so it cannot become the per-`%output` broadcast storm that tears down views.
        broadcastState()
    }

    /// Answers the prompt ssh is waiting on.
    ///
    /// Written straight to the transport rather than through `send`: this is not a tmux command. It
    /// must not enter the pending-command FIFO — an entry there would misalign every `%begin` for the
    /// life of the channel — and it happens before the handshake, where `send` would queue it in the
    /// outbox and deliver it far too late.
    ///
    /// The secret is never logged, never stored on the connection, and never put in
    /// `preHandshakeLog`, which is surfaced to the user verbatim when a channel dies.
    public func answerAuthenticationPrompt(hostId: String, secret: String) {
        guard let connection = connections[hostId], !connection.answeredPrompt else { return }
        connection.answeredPrompt = true
        withHost(hostId) { $0.authenticationPrompt = nil }
        broadcastState()

        // ssh reads a line from the tty. It disables echo itself, so nothing comes back.
        guard var bytes = secret.data(using: .utf8) else { return }
        bytes.append(0x0a)
        let written = connection.transport.write(bytes)
        log("[\(hostId)] answered ssh prompt (\(written ? "written" : "write failed"))")
    }

    /// Abandons a prompt: no secret is available, so the connection cannot proceed.
    public func cancelAuthenticationPrompt(hostId: String) {
        guard let connection = connections[hostId] else { return }
        connection.userInitiatedDisconnect = true
        withHost(hostId) { $0.authenticationPrompt = nil }
        teardown(hostId: hostId, connection: connection)
        withHost(hostId) { $0.connectionState = .disconnected }
        broadcastState()
    }

    // MARK: - Handshake and command results

    private func completeHandshakeIfNeeded(hostId: String, connection: Connection) {
        guard !connection.handshakeComplete else { return }
        connection.handshakeComplete = true
        connection.preHandshakeLog.removeAll()
        // Whatever ssh asked for, it got: the protocol is speaking.
        withHost(hostId) { $0.authenticationPrompt = nil }

        withHost(hostId) { host in
            host.connectionState = .connected
        }
        reconnectAttempts[hostId] = 0

        // Flush anything the UI queued while we were still connecting.
        let queued = connection.outbox
        connection.outbox.removeAll()

        send("display-message -p '#{version}'", kind: .version, hostId: hostId, connection: connection)
        // The `window-size` policy waits for that version: which of the two sizing models is available
        // depends on it, and choosing wrongly either collapses every pane toward 80x24 or leaves a
        // torn-off window unable to size itself. See `applyWindowSizePolicy`.
        send("list-clients -F \(TmuxCommand.quote(TmuxCommand.clientsFormat))",
             kind: .listClients, hostId: hostId, connection: connection)
        refreshTopology(hostId: hostId, connection: connection)
        // Panes that were already on screen before this channel existed — the reconnect case — have
        // a live subscriber and no content: control mode streams only what changes from now on, so
        // without this they would sit at whatever they showed when the old channel died (F4.16).
        repaintSubscribedPanes(hostId: hostId)

        for command in queued {
            send(command.text, kind: command.kind, hostId: hostId, connection: connection)
        }

        startRoundTripTimer(hostId: hostId, connection: connection)
        flushResize(hostId: hostId)
    }

    private func complete(_ command: PendingCommand, hostId: String, connection: Connection) {
        let text = { command.lines.map { String(decoding: $0, as: UTF8.self) } }

        switch command.kind {
        case .ignore:
            break

        case .version:
            guard let raw = text().first, let version = TmuxVersion(raw) else { break }
            connection.version = version
            withHost(hostId) { $0.tmuxVersion = version.raw }
            if !version.supportsControlMode {
                withHost(hostId) { host in
                    host.connectionState = .degraded(
                        reason: "tmux \(version.raw) is below the control-mode floor (2.4); passthrough required"
                    )
                }
            }
            // The size we asked for before knowing the version may have used the wrong syntax.
            connection.lastSentSize = nil
            applyWindowSizePolicy(hostId: hostId, connection: connection)

            flushResize(hostId: hostId)

        case .listSessions:
            applySessions(text(), hostId: hostId)

        case .listWindows:
            applyWindows(text(), hostId: hostId)

        case .listPanes:
            applyPanes(text(), hostId: hostId)

        case .listClients:
            log("[\(hostId)] clients: \(text().joined(separator: ", "))")

        case .capturePane(let paneId, let target):
            deliver(Self.repaintPayload(from: command.lines), hostId: hostId, paneId: paneId, target: target)

        case .roundTrip(let sentAt):
            let elapsed = ContinuousClock.now - sentAt
            let milliseconds = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15
            withHost(hostId) { $0.rttMilliseconds = milliseconds }
        }
    }

    /// Turns `capture-pane -p -e -J` output into bytes a terminal emulator can replay (F4.16).
    private static func repaintPayload(from lines: [Data]) -> Data {
        var lines = lines
        // capture-pane pads the screen to its full height; replaying twenty blank rows just pushes
        // the real content off the top of the view.
        while let last = lines.last, last.allSatisfy({ $0 == UInt8(ascii: " ") }) {
            lines.removeLast()
        }

        var payload = Data()
        // Home, clear screen, clear scrollback: this is a repaint, not an append.
        payload.append(contentsOf: Array("\u{1b}[H\u{1b}[2J\u{1b}[3J".utf8))
        for (index, line) in lines.enumerated() {
            if index > 0 { payload.append(contentsOf: [0x0d, 0x0a]) }
            payload.append(line)
        }
        payload.append(contentsOf: Array("\u{1b}[0m".utf8))
        return payload
    }

    // MARK: - Topology queries

    private func scheduleTopologyRefresh(hostId: String) {
        guard let connection = connections[hostId], connection.handshakeComplete else { return }
        guard connection.topologyRefreshTask == nil else { return }
        connection.topologyRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            await self?.runTopologyRefresh(hostId: hostId)
        }
    }

    private func runTopologyRefresh(hostId: String) {
        guard let connection = connections[hostId] else { return }
        connection.topologyRefreshTask = nil
        refreshTopology(hostId: hostId, connection: connection)
    }

    private func refreshTopology(hostId: String, connection: Connection) {
        send("list-sessions -F \(TmuxCommand.quote(TmuxCommand.sessionsFormat))",
             kind: .listSessions, hostId: hostId, connection: connection)
        send("list-windows -a -F \(TmuxCommand.quote(TmuxCommand.windowsFormat))",
             kind: .listWindows, hostId: hostId, connection: connection)
        send("list-panes -a -F \(TmuxCommand.quote(TmuxCommand.panesFormat))",
             kind: .listPanes, hostId: hostId, connection: connection)
    }

    private func applySessions(_ lines: [String], hostId: String) {
        withHost(hostId) { host in
            var seen: Set<String> = []
            for line in lines {
                let fields = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count >= 3 else { continue }
                let id = String(fields[0])
                let attached = fields[1] == "1"
                let name = String(fields[2])
                seen.insert(id)
                if let index = host.sessions.firstIndex(where: { $0.id == id }) {
                    host.sessions[index].name = name
                    host.sessions[index].isAttached = attached
                } else {
                    host.sessions.append(TmuxSession(id: id, name: name, isAttached: attached))
                }
            }
            host.sessions.removeAll { !seen.contains($0.id) }
            host.sessions.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if host.activeSessionId == nil || !seen.contains(host.activeSessionId!) {
                host.activeSessionId = host.sessions.first { $0.isAttached }?.id ?? host.sessions.first?.id
            }
        }
        // Catches a rename we learned about from `list-sessions` rather than from a notification —
        // another client renaming the session while our channel was down, for instance.
        syncReconnectTarget(hostId: hostId)
    }

    /// Keeps `reconnectTarget` pointing at the *current* name of the session this client is on.
    ///
    /// The target is a name rather than a `$id` so it still resolves after a tmux server restart,
    /// which means a rename invalidates it. A stale name is worse than a failed lookup: the
    /// reconnect path runs `new-session -A -s <name>`, so it would helpfully create an empty
    /// session under the old name and strand the user in it, with every real pane elsewhere.
    ///
    /// `activeSessionId` is used rather than `isAttached` deliberately — `session_attached` counts
    /// *any* client, so a user with a plain `tmux attach` open elsewhere would otherwise redirect
    /// our reconnect to their session.
    private func syncReconnectTarget(hostId: String) {
        guard let host = hosts[hostId],
              let activeId = host.activeSessionId,
              let session = host.sessions.first(where: { $0.id == activeId }) else { return }
        reconnectTarget[hostId] = session.name
    }

    private func applyWindows(_ lines: [String], hostId: String) {
        withHost(hostId) { host in
            var seenBySession: [String: Set<String>] = [:]
            for line in lines {
                let fields = line.split(separator: "|", maxSplits: 5, omittingEmptySubsequences: false)
                guard fields.count >= 6 else { continue }
                let sessionId = String(fields[0])
                let windowId = String(fields[1])
                let isActive = fields[2] == "1"
                let hasActivity = fields[3] == "1"
                let layout = String(fields[4])
                let name = String(fields[5])

                seenBySession[sessionId, default: []].insert(windowId)

                guard let sessionIndex = host.sessions.firstIndex(where: { $0.id == sessionId }) else { continue }
                if let windowIndex = host.sessions[sessionIndex].windows.firstIndex(where: { $0.id == windowId }) {
                    host.sessions[sessionIndex].windows[windowIndex].name = name
                    host.sessions[sessionIndex].windows[windowIndex].isActive = isActive
                    host.sessions[sessionIndex].windows[windowIndex].hasActivity = hasActivity
                    host.sessions[sessionIndex].windows[windowIndex].apply(layoutString: layout)
                } else {
                    var window = TmuxWindow(id: windowId, name: name, isActive: isActive, hasActivity: hasActivity)
                    window.apply(layoutString: layout)
                    host.sessions[sessionIndex].windows.append(window)
                }
                if isActive {
                    host.sessions[sessionIndex].activeWindowId = windowId
                }
            }

            for sessionIndex in host.sessions.indices {
                let sessionId = host.sessions[sessionIndex].id
                guard let seen = seenBySession[sessionId] else { continue }
                host.sessions[sessionIndex].windows.removeAll { !seen.contains($0.id) }
                if let active = host.sessions[sessionIndex].activeWindowId,
                   !seen.contains(active) {
                    host.sessions[sessionIndex].activeWindowId = host.sessions[sessionIndex].windows.first?.id
                }
                if host.sessions[sessionIndex].activeWindowId == nil {
                    host.sessions[sessionIndex].activeWindowId = host.sessions[sessionIndex].windows.first?.id
                }
            }
        }
    }

    private func applyPanes(_ lines: [String], hostId: String) {
        withHost(hostId) { host in
            for line in lines {
                let fields = line.split(separator: "|", maxSplits: 6, omittingEmptySubsequences: false)
                guard fields.count >= 7 else { continue }
                let windowId = String(fields[0])
                let paneId = String(fields[1])
                let isActive = fields[2] == "1"
                let cols = Int(fields[3]) ?? 80
                let rows = Int(fields[4]) ?? 24
                let command = String(fields[5])
                let path = String(fields[6])

                Self.mutateWindow(&host, windowId: windowId) { window in
                    if let index = window.panes.firstIndex(where: { $0.id == paneId }) {
                        window.panes[index].isActive = isActive
                        window.panes[index].cols = cols
                        window.panes[index].rows = rows
                        window.panes[index].command = command
                        window.panes[index].currentPath = path
                    } else {
                        window.panes.append(TmuxPane(
                            id: paneId, command: command, currentPath: path,
                            isActive: isActive, cols: cols, rows: rows
                        ))
                    }
                    if isActive { window.activePaneId = paneId }
                }
            }
        }
    }

    // MARK: - Model helpers

    private func withHost(_ hostId: String, _ body: (inout HostState) -> Void) {
        guard var host = hosts[hostId] else { return }
        body(&host)
        hosts[hostId] = host
    }

    /// Finds a window anywhere in the host, creating it in the active session if it is new.
    private static func mutateWindow(_ host: inout HostState, windowId: String, _ body: (inout TmuxWindow) -> Void) {
        for sessionIndex in host.sessions.indices {
            if let windowIndex = host.sessions[sessionIndex].windows.firstIndex(where: { $0.id == windowId }) {
                body(&host.sessions[sessionIndex].windows[windowIndex])
                return
            }
        }
        // A window we have not been told about yet: park it on the attached session. The next
        // list-windows fills in the name and layout.
        let sessionIndex: Int
        if let active = host.activeSessionId, let index = host.sessions.firstIndex(where: { $0.id == active }) {
            sessionIndex = index
        } else if !host.sessions.isEmpty {
            sessionIndex = 0
        } else {
            return  // No session yet; %session-changed will arrive and a refresh will follow.
        }
        var window = TmuxWindow(id: windowId, name: windowId)
        body(&window)
        host.sessions[sessionIndex].windows.append(window)
        if host.sessions[sessionIndex].activeWindowId == nil {
            host.sessions[sessionIndex].activeWindowId = windowId
        }
    }

    // MARK: - Sending commands

    private func send(_ text: String, kind: PendingCommand.Kind, hostId: String, connection: Connection) {
        let command = PendingCommand(text: text, kind: kind)
        guard connection.handshakeComplete else {
            connection.outbox.append(command)
            return
        }
        guard let data = (text + "\n").data(using: .utf8) else { return }
        // Enqueue before writing: tmux answers in order, and the reply can arrive before this
        // function returns if the actor suspends.
        connection.pending.append(command)
        if !connection.transport.write(data) {
            connection.pending.removeLast()
            log("[\(hostId)] write failed for: \(text)")
        }
    }

    private func send(_ text: String, kind: PendingCommand.Kind = .ignore, hostId: String) {
        guard let connection = connections[hostId] else { return }
        send(text, kind: kind, hostId: hostId, connection: connection)
    }

    // MARK: - Pane output

    /// Hands pane bytes to the views showing it. `target` restricts delivery to one subscriber, which
    /// only a repaint ever does.
    private func deliver(_ data: Data, hostId: String, paneId: String, target: UUID? = nil) {
        guard let subscribers = outputSubscribers[hostId]?[paneId], !subscribers.isEmpty else { return }

        if let target {
            subscribers[target]?.yield(data)
            return
        }
        for continuation in subscribers.values {
            continuation.yield(data)
        }
    }

    /// Streams a pane's output. On first subscription the pane is repainted from tmux's own
    /// scrollback, because control mode sends nothing at all for a pane that is merely sitting
    /// there — attaching to an existing session would otherwise show an empty terminal (F4.16).
    ///
    /// A *second* subscriber to a pane — the same tmux window open in two macOS windows — gets its own
    /// repaint, addressed to it alone. Without that it would sit blank until the pane next produced
    /// output, because `repaintedPanes` remembers that the pane was already captured; broadcasting the
    /// repaint instead would clear the first window's scrollback.
    public func subscribeToPane(hostId: String, paneId: String) -> AsyncStream<Data> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        let isAdditionalViewer = outputSubscribers[hostId]?[paneId]?.isEmpty == false
        outputSubscribers[hostId, default: [:]][paneId, default: [:]][id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(hostId: hostId, paneId: paneId, id: id) }
        }
        requestRepaint(hostId: hostId, paneId: paneId, target: isAdditionalViewer ? id : nil)
        return stream
    }

    private func unsubscribe(hostId: String, paneId: String, id: UUID) {
        outputSubscribers[hostId]?[paneId]?.removeValue(forKey: id)
        if outputSubscribers[hostId]?[paneId]?.isEmpty == true {
            outputSubscribers[hostId]?.removeValue(forKey: paneId)
            // Next time this pane is displayed it needs a fresh repaint.
            connections[hostId]?.repaintedPanes.remove(paneId)
        }

    }

    private func requestRepaint(hostId: String, paneId: String, target: UUID? = nil) {
        guard let connection = connections[hostId] else { return }
        // A repaint for one specific viewer is never suppressed and never marks the pane as painted:
        // it exists precisely because the pane is already painted somewhere else.
        if target == nil {
            guard !connection.repaintedPanes.contains(paneId) else { return }
            connection.repaintedPanes.insert(paneId)
        }
        send(
            "capture-pane -p -e -J -t \(paneId) -S -\(captureScrollbackLines)",
            kind: .capturePane(paneId: paneId, target: target), hostId: hostId, connection: connection
        )
    }

    /// Forces a repaint even if the pane was captured before — used after reattach (F4.16).
    public func repaintPane(hostId: String, paneId: String) {
        connections[hostId]?.repaintedPanes.remove(paneId)
        requestRepaint(hostId: hostId, paneId: paneId)
    }

    /// Repaints every pane currently on screen for a host.
    private func repaintSubscribedPanes(hostId: String) {
        guard let panes = outputSubscribers[hostId]?.keys else { return }
        connections[hostId]?.repaintedPanes.removeAll()
        for paneId in panes {
            requestRepaint(hostId: hostId, paneId: paneId)
        }
    }

    /// Moves this client to another session.
    ///
    /// Necessary because control mode only sends `%output` for the session the client is attached
    /// to: picking a different session in the sidebar has to move the client, not merely change
    /// what the UI draws, or every pane in it would render once and then sit frozen.
    public func switchSession(hostId: String, sessionId: String) {
        send("switch-client -t \(TmuxCommand.quote(sessionId))", hostId: hostId)
    }

    // MARK: - Input

    /// Queues keystrokes for a pane. Under control mode every keystroke is a command with a
    /// `%begin`/`%end` round trip, so they are coalesced into one `send-keys` per frame (§3.2).
    public func sendKeys(hostId: String, paneId: String, bytes: [UInt8]) {
        guard !bytes.isEmpty, let connection = connections[hostId] else { return }
        connection.pendingKeys[paneId, default: []].append(contentsOf: bytes)

        guard connection.keyFlushTask == nil else { return }
        connection.keyFlushTask = Task { [weak self, interval = keyFlushInterval] in
            try? await Task.sleep(for: interval)
            await self?.flushKeys(hostId: hostId)
        }
    }

    public func sendKeys(hostId: String, paneId: String, text: String) {
        sendKeys(hostId: hostId, paneId: paneId, bytes: Array(text.utf8))
    }

    private func flushKeys(hostId: String) {
        guard let connection = connections[hostId] else { return }
        connection.keyFlushTask = nil
        let batches = connection.pendingKeys
        connection.pendingKeys.removeAll(keepingCapacity: true)

        for (paneId, bytes) in batches where !bytes.isEmpty {
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            send("send-keys -H -t \(paneId) \(hex)", kind: .ignore, hostId: hostId, connection: connection)
        }
    }

    /// Pastes text into a pane. Large content goes through a tmux buffer: a megabyte of
    /// `send-keys -H` is a megabyte of command line and will wedge the channel (§3.2).
    ///
    /// The buffer is built with `TmuxCommand.doubleQuoted`, not `quote`. Clipboard text is routinely
    /// multi-line, and a single-quoted tmux string cannot carry a newline: the command line ends at the
    /// first one, tmux reports an unterminated string, and every following line of the paste is
    /// interpreted as a *command*. Under the old encoding a two-line paste over the threshold produced
    /// two `%error`s and pasted nothing.
    ///
    /// Small pastes still go through `send-keys -H`, which is hex and therefore newline-safe already.
    public func paste(hostId: String, paneId: String, text: String) {
        guard !text.isEmpty, let connection = connections[hostId] else { return }
        guard text.utf8.count > pasteThreshold else {
            sendKeys(hostId: hostId, paneId: paneId, text: text)
            return
        }

        // A name per paste. Two panes pasting at once would otherwise append into each other's buffer,
        // because the chunks below are separate commands and nothing keeps them contiguous.
        pasteSequence += 1
        let buffer = "tetmux-paste-\(pasteSequence)"

        for (index, chunk) in TmuxCommand.chunk(text, maxEscapedBytes: pasteChunkBytes).enumerated() {
            // The first command creates or replaces the buffer; the rest append to it.
            let mode = index == 0 ? "" : "-a "
            send(
                "set-buffer \(mode)-b \(buffer) -- \(TmuxCommand.doubleQuoted(chunk))",
                kind: .ignore, hostId: hostId, connection: connection
            )
        }
        // -p emits bracketed-paste markers when the pane's application asked for them (T5.4), and -d
        // drops the buffer afterwards so a clipboard's worth of text does not linger on the server.
        send("paste-buffer -d -p -b \(buffer) -t \(paneId)", kind: .ignore, hostId: hostId, connection: connection)
    }

    // MARK: - Geometry (§3.3 — tmux is authoritative)

    /// Asks tmux for a client size. The view never resizes a surface on its own; it waits for the
    /// `%layout-change` that comes back.
    public func requestClientSize(hostId: String, cols: Int, rows: Int) {
        guard cols > 0, rows > 0, let connection = connections[hostId] else { return }
        connection.desiredSize = (cols, rows)
        guard connection.resizeTask == nil else { return }
        connection.resizeTask = Task { [weak self, debounce = resizeDebounce] in
            try? await Task.sleep(for: debounce)
            await self?.flushResize(hostId: hostId)
        }
    }

    private func flushResize(hostId: String) {
        guard let connection = connections[hostId] else { return }
        connection.resizeTask = nil
        guard connection.handshakeComplete, let size = connection.desiredSize else { return }
        guard connection.lastSentSize == nil
            || connection.lastSentSize! != size else { return }
        connection.lastSentSize = size

        // tmux 3.2 changed `refresh-client -C` from `W,H` to `WxH`.
        let modern = connection.version.map { $0 >= TmuxVersion("3.2")! } ?? true
        let argument = modern ? "\(size.cols)x\(size.rows)" : "\(size.cols),\(size.rows)"
        send("refresh-client -C \(argument)", kind: .ignore, hostId: hostId, connection: connection)
        // For ssh this also travels to the remote pty, which is how the far end learns we resized.
        connection.transport.resize(cols: UInt16(clamping: size.cols), rows: UInt16(clamping: size.rows))
    }

    // MARK: - Per-window geometry (§3.3)

    /// Decides how this session's windows get their size, once the server version is known.
    ///
    /// **tmux 2.9 and newer:** `window-size manual`, and one `resize-window` per window that is
    /// actually on screen. This is what lets a torn-off macOS window size its tmux window
    /// independently — with a single client there is otherwise exactly one size for every window it
    /// shows, so the second macOS window would be stuck with the first one's grid.
    ///
    /// **Older:** `window-size latest`, which has no per-window equivalent. Without *something* here
    /// an old or small client clamps every window toward 80x24 and every pane collapses (F4.17).
    ///
    /// Set on the attached session rather than globally: it is a session option, and changing it
    /// server-wide would resize windows for the user's other clients too. `disconnectHost` puts it
    /// back — see the note there about what an unclean drop leaves behind.
    private func applyWindowSizePolicy(hostId: String, connection: Connection) {
        guard let version = connection.version else { return }
        let target = TmuxCommand.quote(reconnectTarget[hostId] ?? connection.sessionTarget)

        guard version >= TmuxVersion("2.9")! else {
            connection.sizesWindowsIndividually = false
            send("set-option -t \(target) window-size latest", kind: .ignore, hostId: hostId, connection: connection)
            return
        }

        connection.sizesWindowsIndividually = true
        send("set-option -t \(target) window-size manual", kind: .ignore, hostId: hostId, connection: connection)
        // Anything we sent before the option was in place may have been overridden by tmux's own
        // sizing, so nothing is assumed to have taken effect.
        connection.lastSentWindowSizes.removeAll()
        flushWindowResizes(hostId: hostId)
    }


    /// Puts `window-size` back to whatever the session inherited, on the way out.
    ///
    /// `window-size manual` is a change to the user's own session, and a manual size persists — a later
    /// plain `tmux attach` would find windows that no longer follow the terminal.
    ///
    /// Best-effort by construction, in two ways. It can only run on a *deliberate* disconnect, so a
    /// channel that dies with the network leaves the option set (tetmux sets it again on the next
    /// attach, so the visible effect is limited to attaching with something else in the meantime). And
    /// the write races teardown: locally the client reads it first, but over ssh the bytes may still be
    /// in flight when the transport is terminated. `tmux set-option -u -t <session> window-size` is the
    /// remedy either way.
    private func restoreWindowSizePolicy(hostId: String, connection: Connection) {
        guard connection.sizesWindowsIndividually, connection.handshakeComplete else { return }
        let target = TmuxCommand.quote(reconnectTarget[hostId] ?? connection.sessionTarget)
        send("set-option -u -t \(target) window-size", kind: .ignore, hostId: hostId, connection: connection)
    }

    /// Claims the right to size a tmux window. Called by a view when its macOS window takes focus.
    public func claimWindowSize(hostId: String, windowId: String, owner: UUID) {
        guard let connection = connections[hostId] else { return }
        guard connection.windowSizeOwners[windowId] != owner else { return }
        connection.windowSizeOwners[windowId] = owner
        // The new owner's size may differ from the old one's, so let it through even though the
        // window's size is unchanged from tmux's point of view.
        connection.lastSentWindowSizes.removeValue(forKey: windowId)
    }

    public func releaseWindowSize(hostId: String, windowId: String, owner: UUID) {
        guard let connection = connections[hostId],
              connection.windowSizeOwners[windowId] == owner else { return }
        connection.windowSizeOwners.removeValue(forKey: windowId)
    }

    /// Asks tmux to size one window, from the view that owns it.
    ///
    /// Ignored when a different view owns that window: two macOS windows showing the same tmux window
    /// at different sizes would otherwise resize it back and forth without ever settling.
    public func requestWindowSize(hostId: String, windowId: String, cols: Int, rows: Int, owner: UUID) {
        guard cols > 1, rows > 1, let connection = connections[hostId] else { return }

        if let currentOwner = connection.windowSizeOwners[windowId] {
            guard currentOwner == owner else { return }
        } else {
            connection.windowSizeOwners[windowId] = owner
        }

        // Recorded even when per-window sizing is not enabled yet. The policy is decided a round trip
        // after the handshake — the version probe has to answer first — and a view has usually finished
        // measuring itself by then. Dropping these instead left a window unsized until the user
        // happened to resize or refocus it; `applyWindowSizePolicy` flushes whatever accumulated.
        connection.desiredWindowSizes[windowId] = (cols, rows)
        guard connection.windowResizeTask == nil else { return }
        connection.windowResizeTask = Task { [weak self, debounce = resizeDebounce] in
            try? await Task.sleep(for: debounce)
            await self?.flushWindowResizes(hostId: hostId)
        }
    }

    private func flushWindowResizes(hostId: String) {
        guard let connection = connections[hostId] else { return }
        connection.windowResizeTask = nil
        guard connection.handshakeComplete, connection.sizesWindowsIndividually else { return }

        for (windowId, size) in connection.desiredWindowSizes {
            if let sent = connection.lastSentWindowSizes[windowId], sent == size { continue }
            connection.lastSentWindowSizes[windowId] = size
            send(
                "resize-window -t \(windowId) -x \(size.cols) -y \(size.rows)",
                kind: .ignore, hostId: hostId, connection: connection
            )
        }
    }

    /// Forgets a window that no longer exists, so its size and owner do not accumulate for the life of
    /// the channel.
    private func forgetWindowGeometry(hostId: String, windowId: String) {
        guard let connection = connections[hostId] else { return }
        connection.desiredWindowSizes.removeValue(forKey: windowId)
        connection.lastSentWindowSizes.removeValue(forKey: windowId)
        connection.windowSizeOwners.removeValue(forKey: windowId)
    }

    // MARK: - Round-trip measurement (F4.29)

    private func startRoundTripTimer(hostId: String, connection: Connection) {
        connection.rttTask?.cancel()
        connection.rttTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await self?.measureRoundTrip(hostId: hostId)
            }
        }
    }

    private func measureRoundTrip(hostId: String) {
        guard let connection = connections[hostId], connection.handshakeComplete else { return }
        send("display-message -p ''", kind: .roundTrip(sentAt: .now), hostId: hostId, connection: connection)
    }

    // MARK: - Session and window operations

    public func newWindow(hostId: String, sessionId: String? = nil) {
        let target = sessionId.map { " -t \(TmuxCommand.quote($0))" } ?? ""
        send("new-window\(target)", hostId: hostId)
    }

    public func splitPane(hostId: String, paneId: String, leftRight: Bool) {
        send("split-window \(leftRight ? "-h" : "-v") -t \(paneId)", hostId: hostId)
    }

    public func killPane(hostId: String, paneId: String) {
        send("kill-pane -t \(paneId)", hostId: hostId)
    }

    public func selectPane(hostId: String, paneId: String) {
        send("select-pane -t \(paneId)", hostId: hostId)
    }

    public func selectWindow(hostId: String, windowId: String) {
        send("select-window -t \(windowId)", hostId: hostId)
    }

    /// tmux turns `automatic-rename` off for a window that is renamed explicitly, so the name the
    /// user chose survives the next command change rather than being overwritten by it.
    public func renameWindow(hostId: String, windowId: String, newName: String) {
        let name = TmuxCommand.singleLine(newName)
        guard !name.isEmpty else { return }
        send("rename-window -t \(windowId) \(TmuxCommand.quote(name))", hostId: hostId)
    }

    /// F4.9 — closing a tab unlinks the window from the session; it never kills what is running.
    public func unlinkWindow(hostId: String, windowId: String) {
        send("unlink-window -t \(windowId)", hostId: hostId)
    }

    public func killWindow(hostId: String, windowId: String) {
        send("kill-window -t \(windowId)", hostId: hostId)
    }

    /// The `%session-renamed` this produces is what moves `reconnectTarget` onto the new name.
    public func renameSession(hostId: String, sessionId: String, newName: String) {
        let name = TmuxCommand.singleLine(newName)
        guard !name.isEmpty else { return }
        send("rename-session -t \(TmuxCommand.quote(sessionId)) \(TmuxCommand.quote(name))", hostId: hostId)
    }

    public func killSession(hostId: String, sessionId: String) {
        send("kill-session -t \(TmuxCommand.quote(sessionId))", hostId: hostId)
    }

    /// Creates a session on an already-connected host, without opening a second channel.
    public func newSession(hostId: String, name: String, startDirectory: String? = nil) {
        let name = TmuxCommand.singleLine(name)
        guard !name.isEmpty else { return }
        var command = "new-session -d -s \(TmuxCommand.quote(name))"
        if let startDirectory, !startDirectory.isEmpty {
            command += " -c \(TmuxCommand.quote(startDirectory))"
        }
        send(command, hostId: hostId)
    }

    /// F4.11 — detaches every other client from the session we are attached to. Also the remedy
    /// for an orphaned client clamping window size (F4.17) when `window-size latest` is not enough.
    public func detachOtherClients(hostId: String) {
        guard let connection = connections[hostId] else { return }
        send("detach-client -a -s \(TmuxCommand.quote(connection.sessionTarget))", kind: .ignore, hostId: hostId, connection: connection)
    }

    public func resizePane(hostId: String, paneId: String, cols: Int?, rows: Int?) {
        var command = "resize-pane -t \(paneId)"
        if let cols { command += " -x \(cols)" }
        if let rows { command += " -y \(rows)" }
        send(command, hostId: hostId)
    }

    // MARK: - Disconnection and recovery

    private func channelClosed(hostId: String, epoch: UUID, error: Error?) {
        guard let connection = connections[hostId], connection.epoch == epoch else { return }

        // If the channel died before tmux ever spoke, whatever ssh printed is the real diagnosis:
        // a host-key warning, "Permission denied (publickey)", or a missing remote tmux.
        var reason = error.map(describe) ?? "Connection closed"
        if !connection.handshakeComplete {
            let transcript = String(decoding: connection.preHandshakeLog, as: UTF8.self)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty {
                reason = transcript
            }
        }

        let userInitiated = connection.userInitiatedDisconnect
        teardown(hostId: hostId, connection: connection)
        guard !userInitiated else { return }

        log("[\(hostId)] channel closed: \(reason)")

        // F4.14: authentication failures are not retried — retrying just locks the account out.
        if isAuthenticationFailure(reason) {
            withHost(hostId) { $0.connectionState = .failed(reason: reason) }
            broadcastState()
            return
        }

        let attempt = (reconnectAttempts[hostId] ?? 0) + 1
        reconnectAttempts[hostId] = attempt
        guard attempt <= 8 else {
            withHost(hostId) { host in
                host.connectionState = .failed(reason: "\(reason) — stopped after 8 attempts; retry manually")
            }
            broadcastState()
            return
        }

        // Exponential backoff, 1 s → 60 s, ±20% jitter.
        let delay = min(pow(2.0, Double(attempt - 1)), 60.0) * Double.random(in: 0.8...1.2)
        withHost(hostId) { host in
            host.connectionState = .reconnecting(attempt: attempt, nextRetryInSeconds: delay)
        }
        broadcastState()

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            try? await self?.connectHost(hostId: hostId)
        }
    }

    private func isAuthenticationFailure(_ reason: String) -> Bool {
        let lowered = reason.lowercased()
        return lowered.contains("permission denied")
            || lowered.contains("authentication failed")
            || lowered.contains("host key verification failed")
            || lowered.contains("no supported authentication")
    }

    private func teardown(hostId: String, connection: Connection) {
        connection.cancelTimers()
        connection.readTask?.cancel()
        connection.transport.terminate()
        // A prompt belongs to the channel that asked; there is nothing left to answer.
        withHost(hostId) { $0.authenticationPrompt = nil }
        if connections[hostId]?.epoch == connection.epoch {
            connections.removeValue(forKey: hostId)
        }
        // Pane subscriptions deliberately outlive the channel. They are a registry of what is on
        // screen, not a property of the connection: a view subscribes exactly once, when its
        // `NSView` is made, and pane ids survive on the server across a drop — so the view is never
        // rebuilt and never subscribes again. Finishing the streams here left every pane dead for
        // the rest of the app's life after the first network blip, silently: keystrokes still
        // reached tmux, but nothing came back. `completeHandshakeIfNeeded` repaints them on the
        // next attach instead; `finishSubscribers` is for a host that is actually going away.
    }

    /// Ends every pane stream for a host. Only correct when the host itself is going away — an
    /// ordinary disconnect keeps its subscriptions so a later attach can repaint into the same
    /// views.
    private func finishSubscribers(hostId: String) {
        guard let panes = outputSubscribers.removeValue(forKey: hostId) else { return }
        for continuations in panes.values {
            for continuation in continuations.values { continuation.finish() }
        }
    }

    /// An explicit "reconnect now" from the user.
    ///
    /// Clears the circuit breaker (F4.14) as well as any pending backoff, because the automatic
    /// attempts and a deliberate click mean different things: the breaker exists to stop us
    /// hammering a host nobody asked about, and a click is someone saying the host is reachable
    /// again. Without the reset, a host that had already spent its eight attempts would refuse to
    /// come back for the rest of the session.
    public func reconnectNow(hostId: String) async {
        reconnectAttempts[hostId] = 0
        try? await connectHost(hostId: hostId)
    }

    /// Called on wake and on network path changes (F4.18). Probes rather than waiting for a
    /// timeout, so a reconnect after closing the lid is immediate.
    public func probeAllConnections() async {
        for hostId in hostOrder {
            guard let host = hosts[hostId] else { continue }
            switch host.connectionState {
            case .connected, .degraded:
                // Cheap liveness check: if the channel is dead the write fails and the read side
                // will already be tearing down.
                send("display-message -p ''", kind: .roundTrip(sentAt: .now), hostId: hostId)
            case .reconnecting, .failed:
                reconnectAttempts[hostId] = 0
                try? await connectHost(hostId: hostId)
            case .disconnected, .connecting:
                break
            }
        }
    }
}
