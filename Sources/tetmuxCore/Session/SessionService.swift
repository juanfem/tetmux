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
    /// The primary channel of each host: the one that carries the connection itself.
    private var connections: [String: Connection] = [:]

    /// One extra channel per session that is on screen and is not the primary's, keyed
    /// `hostId` → `sessionId`.
    ///
    /// This is the whole of "a client per displayed session". A tmux client is attached to exactly
    /// one session and `%output` arrives only for that one, so a second session in front of the user
    /// is a second client or it is a still frame. They are created and retired by
    /// `setDisplayedSessions`, which is the only thing that knows what is on screen.
    private var followerChannels: [String: [String: Connection]] = [:]

    /// Which sessions the UI is currently showing, per host. The input to `reconcileChannels`.
    private var displayedSessions: [String: Set<String>] = [:]

    /// Which channel is painting each pane, by epoch, keyed `hostId` → `paneId`.
    ///
    /// A window can be linked into two sessions at once (F4.9's whole subject), and if both are on
    /// screen then two clients stream identical `%output` for its panes. Delivering both would
    /// double every byte the pane produces. The first channel to speak for a pane keeps it; the rest
    /// are dropped until it goes away, and the pane is repainted when ownership moves so the new
    /// owner's stream starts from a screen it agrees with.
    private var paneOwners: [String: [String: UUID]] = [:]
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

    // Backpressure (P6.5). A pane can produce output faster than an emulator can paint it — `yes` is
    // the one-word reproducer — and the queue between the two is the only place that can absorb the
    // difference. Bounding it is what stops a runaway pane from turning into unbounded memory.
    /// Undelivered bytes at which a pane is paused.
    private let paneHighWaterBytes = 1 << 20
    /// …and the level it has to drain to before it is resumed. The gap is deliberate: pausing and
    /// resuming around a single threshold would do both on alternate chunks, and each resume costs a
    /// full `capture-pane` repaint.
    private let paneLowWaterBytes = 1 << 18
    /// Hard ceiling on what one viewer may have queued. Past this, output is dropped and the pane
    /// owes a repaint.
    ///
    /// Four times the high-water mark, so it is reached only when pausing did not work: while a pause
    /// is still in flight, or below tmux 3.2 where there is nothing to pause with and this bound is
    /// the whole mechanism. A drop is always repaired by a repaint, never handed to the emulator as a
    /// hole in the byte stream.
    private let paneMaxBufferedBytes = 4 << 20
    /// Element bound on the same buffer, as a backstop to the byte bound above. Deliberately far
    /// larger than any chunk count those bytes imply, so it binds only if the accounting is wrong.
    private let paneBufferChunks = 65536
    /// How far behind this client may fall before tmux pauses a pane on its own.
    private let pauseAfterSeconds = 3
    /// Commands that may wait for the attach handshake before the oldest are dropped.
    private static let maxOutboxCommands = 256
    /// How long a channel may take to get from spawned to handshaken before it is given up on.
    ///
    /// Generous, because it covers a real ssh login: a `ProxyCommand`, a slow DNS lookup, a large
    /// MOTD. What it rules out is the state that had no bound at all — a login shell blocked on
    /// "press any key", a wedged remote tmux — where the UI sat on "Connecting…" for the life of the
    /// process with no error, no retry, and nothing to distinguish it from a slow link.
    private static let handshakeTimeout = Duration.seconds(45)

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

        /// What this channel is for.
        ///
        /// Control mode streams `%output` only for the session its client is attached to, and a
        /// client has exactly one session — so a second session on screen needs a second client.
        /// The two kinds are not symmetrical and must not be treated as such: the primary channel
        /// *is* the host as far as the rest of the app is concerned (its connection state, its
        /// authentication prompt, its reconnect policy, and every command anyone issues), while a
        /// follower exists for one reason only, which is to make one more session's panes move.
        enum Role: Equatable {
            case primary
            /// Attached to this session id, and torn down when nothing displays it any more.
            case follower(sessionId: String)
        }
        let role: Role

        var isPrimary: Bool { role == .primary }

        /// The session this channel is actually attached to, from `%session-changed`.
        var attachedSessionId: String?
        /// A session this channel has been told to move to but has not landed on yet.
        ///
        /// Counted as live, which is the difference between a banner and no banner. `switch-client`
        /// is a round trip, and for its duration the client is attached to the old session while the
        /// window in front of the user shows the new one — so the honest answer is "not live", and
        /// the useful one is "give it a moment". The banner it saves is one that appears for a tenth
        /// of a second and withdraws, which reads as a glitch rather than as information.
        var pendingSessionId: String?

        /// Commands we have written and are awaiting a `%begin` block for, in the order tmux will
        /// answer them. tmux command numbers are server-wide and start at an arbitrary value, so
        /// they cannot be predicted — but responses are strictly ordered, which is enough.
        var pending: [PendingCommand] = []
        var current: PendingCommand?

        /// The number the open block's `%begin` carried, and the last one seen on this channel.
        ///
        /// Ordering is what correlates a response to its command, so nothing here is *needed* to
        /// match them — but a FIFO with no integrity check fails silently and permanently when it
        /// slips, and the slip is invisible for the life of the channel: repaints land in the wrong
        /// pane, `list-panes` output reaches `applyWindows`, and an internal command's refusal is
        /// reported to the user as some unrelated thing they asked for. The numbers arrive on every
        /// block already. They are server-wide, so they are not consecutive for *us* — another
        /// client's commands consume them too — but they are strictly increasing, and a response
        /// with nothing pending is a desync however it happened.
        var currentNumber: Int?
        var lastCommandNumber: Int?

        /// tmux emits one `%begin`/`%end` block of its own on attach, before we can write anything.
        /// Writing before it lands would misalign `pending` by one for the life of the channel, so
        /// commands wait here until the handshake completes.
        var handshakeComplete = false
        /// Fails the channel if the handshake never arrives. Cancelled the moment it does.
        var handshakeWatchdog: Task<Void, Never>?
        var outbox: [PendingCommand] = []
        /// Raw bytes seen before the protocol started — an ssh banner, a password prompt, a
        /// host-key warning. Surfaced verbatim if the channel dies without ever speaking tmux.
        var preHandshakeLog: [UInt8] = []

        var readTask: Task<Void, Never>?
        var rttTask: Task<Void, Never>?
        var keyFlushTask: Task<Void, Never>?
        var resizeTask: Task<Void, Never>?
        var topologyRefreshTask: Task<Void, Never>?
        /// What the pending refresh will actually ask for. One debounce task is deliberate — a burst
        /// of notifications should cost one round trip — but the two schedulers run *different*
        /// commands, and sharing only the task meant whichever got there first silently decided for
        /// both. A `%window-add` arriving just after a `%window-renamed` was dropped: only
        /// `list-panes` ran, so a window created by another client kept the placeholder name and its
        /// wrong session until something unrelated happened to refresh. Automatic renames fire
        /// constantly, so that was often. Scope only ever widens, and the full refresh is a superset.
        var pendingRefreshIsFullTopology = false

        /// Whether a secret has already been written on this channel. One attempt per channel: a
        /// rejected password answered again is how accounts get locked out, and the retry the user
        /// really wants is a fresh connection with a fresh prompt.
        var answeredPrompt = false
        /// The prompt we have already told the UI about, so the same bytes arriving in a later read
        /// do not raise it twice.
        var reportedPrompt: AuthenticationPrompt.Kind?

        var pendingKeys: [String: [UInt8]] = [:]
        var repaintedPanes: Set<String> = []

        /// Whether this server can pause a pane at all (`refresh-client -A`, tmux 3.2).
        var supportsFlowControl = false
        /// Panes tmux is currently not sending output for, and who asked. Flow control is a property
        /// of the channel, not of the pane registry: a new channel starts with nothing paused, and a
        /// pause that outlived its connection would silence a pane no command could revive.
        var pausedPanes: [String: PauseOrigin] = [:]
        /// Panes that lost bytes to a full buffer and owe the emulator a repaint.
        var lossyPanes: Set<String> = []

        enum PauseOrigin: Equatable {
            /// We asked, because a view fell behind. Ours to undo once it catches up.
            case viewer
            /// tmux's own `pause-after`: this client is behind on the wire. Resuming is still ours to
            /// do — nothing else will — but not *immediately*, which is what `since` is for.
            ///
            /// The evidence for a server pause is inside tmux: a backlog on the socket that the local
            /// `outstanding` counter cannot see. So the viewer's own low-water mark is not a reason to
            /// undo one — with a drained viewer it is satisfied at once, and the resume was going out
            /// in the same breath as the pause arrived. tmux then falls behind again, pauses again,
            /// and each cycle costs a full `capture-pane -S -2000` repaint. `yes` over a slow link
            /// turned backpressure into a repaint storm. A pane held for a moment is what backpressure
            /// is supposed to feel like.
            case server(since: ContinuousClock.Instant)
        }
        /// How long a server-origin pause is left alone before the viewer's watermark may lift it.
        static let serverPauseHoldDown = Duration.seconds(2)
        var desiredSize: (cols: Int, rows: Int)?
        var lastSentSize: (cols: Int, rows: Int)?
        var userInitiatedDisconnect = false

        /// Whether this channel was a recovery attach to the remembered session name, so a death
        /// before the handshake can be read as "that session is gone" rather than "the host is down".
        var attachedByRememberedName = false

        /// Whether tmux said `%exit` before the channel closed.
        ///
        /// This is the whole difference between "the session ended" and "the link died", and there is
        /// no other way to tell them apart from outside: a dropped ssh connection produces EOF and
        /// nothing else, while tmux ending a client always announces it first. Verified on 3.7b —
        /// both `kill-session` on the attached session and the last pane exiting emit
        /// `%sessions-changed` then a bare `%exit`.
        var serverEnded = false

        /// Whether this channel ever actually landed in a session (`%session-changed`).
        ///
        /// Attaching to a server that is gone is not a connection failure: tmux completes the
        /// handshake, answers `no sessions` as a command error, and exits. Without this the retry
        /// after an orderly exit would see another `%exit` and try again forever.
        var attachedToSession = false

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

        /// Callers waiting for tmux to answer a command they sent, by command id.
        ///
        /// Only for the handful of commands whose *effect* has to have landed before we do something
        /// irreversible — putting `window-size` back before hanging the channel up is the whole list.
        /// Everything else is fire-and-forget by design.
        var acknowledgements: [UUID: CheckedContinuation<Void, Never>] = [:]

        init(transport: PtyTransport, sessionTarget: String, role: Role = .primary) {
            self.transport = transport
            self.sessionTarget = sessionTarget
            self.role = role
        }

        func cancelTimers() {
            rttTask?.cancel()
            keyFlushTask?.cancel()
            resizeTask?.cancel()
            windowResizeTask?.cancel()
            topologyRefreshTask?.cancel()
            handshakeWatchdog?.cancel()
        }
    }

    private struct PendingCommand {
        let text: String
        let kind: Kind
        var lines: [Data] = []

        enum Kind {
            /// A block we did not originate (the attach handshake) or whose result we ignore.
            case ignore
            /// Something the user asked for, labelled with what it was. The label exists so a
            /// refusal can be reported as a sentence — tmux says "duplicate session: work", and
            /// only we know that was a rename (§7).
            ///
            /// Deliberately not the default: an internal `resize-window` that an old server refuses
            /// is ours to cope with, not a message to put in front of somebody.
            case userCommand(String)
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
            /// Like `.ignore`, but somebody is waiting to hear that tmux ran it. A refusal counts:
            /// the point is that the command has been *dealt with*, not that it succeeded.
            case acknowledged(UUID)
        }
    }

    private var reconnectAttempts: [String: Int] = [:]
    /// Pending backoff retries, so an explicit decision by the user can cancel one.
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    /// Hosts whose remembered session name failed to resolve on a recovery attach, so the next
    /// attempt takes whatever the server still has instead. Cleared by a successful handshake and by
    /// any explicit connect, both of which mean the name question has been settled.
    private var recoveryLostItsSession: Set<String> = []

    /// One view's claim on a pane's output, and how far behind that view is.
    ///
    /// `outstanding` is bytes handed to the stream that the view has not yet reported feeding to its
    /// emulator — the depth of the queue between the two. Nothing else can measure it: the producer
    /// side of an `AsyncStream` never learns whether anyone is keeping up, so a view that falls behind
    /// is indistinguishable from one that is idle until memory says otherwise.
    private final class PaneSubscriber {
        let continuation: AsyncStream<Data>.Continuation
        var outstanding = 0

        init(continuation: AsyncStream<Data>.Continuation) {
            self.continuation = continuation
        }
    }

    private var outputSubscribers: [String: [String: [UUID: PaneSubscriber]]] = [:]

    /// A view's handle on a pane. The id is what `acknowledge` reports progress against — without it
    /// the service could hand out bytes but never learn whether anyone was keeping up.
    public struct PaneSubscription: Sendable {
        public let id: UUID
        public let stream: AsyncStream<Data>
    }
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

    public func removeHost(hostId: String) async {
        await disconnectHost(hostId: hostId)
        finishSubscribers(hostId: hostId)
        displayedSessions.removeValue(forKey: hostId)
        followerChannels.removeValue(forKey: hostId)
        paneOwners.removeValue(forKey: hostId)
        reconnectTarget.removeValue(forKey: hostId)
        reconnectAttempts.removeValue(forKey: hostId)
        cancelScheduledReconnect(hostId: hostId)
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

    /// Clears a reported command failure once the user has read it (§7).
    public func dismissCommandFailure(hostId: String) {
        guard hosts[hostId]?.lastCommandFailure != nil else { return }
        withHost(hostId) { $0.lastCommandFailure = nil }
        broadcastState()
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
    /// - Parameter isRecovery: whether this is the link coming back rather than the user asking for
    ///   the host. It decides whether a session may be *created*, which is F4.15: a reconnect must
    ///   never manufacture one. `new-session -A -s <name>` cannot tell "the session is still there"
    ///   from "the server restarted while you were away" — it simply makes an empty session under the
    ///   remembered name and hands it over as though it were the user's work. An explicit connect is
    ///   the opposite case: a host with no sessions is exactly when the user wants one made.
    public func connectHost(
        hostId: String,
        targetSession: String? = nil,
        mode: TmuxCommand.AttachMode? = nil,
        isRecovery: Bool = false
    ) async throws {
        guard var host = hosts[hostId] else { return }
        if let existing = connections[hostId] {
            if host.connectionState.isActive { return }
            teardown(hostId: hostId, connection: existing)
        }

        let sessionTarget = targetSession ?? reconnectTarget[hostId] ?? defaultSessionName(for: host.config)
        // `attachAny` deliberately does not adopt a target: it is used precisely when the remembered
        // name refers to a session that no longer exists, and writing it back here would put it in
        // front of the next connect to be recreated.
        let attachMode: TmuxCommand.AttachMode
        if let mode {
            attachMode = mode
        } else if isRecovery {
            // Attach by name; and if that name has already failed to resolve once, take whatever the
            // server still has. Both can only ever land on something that already exists.
            attachMode = recoveryLostItsSession.contains(hostId)
                ? .attachAny
                : .attach(sessionName: sessionTarget)
        } else {
            attachMode = .createOrAttach(sessionName: sessionTarget)
            recoveryLostItsSession.remove(hostId)
        }
        if mode == nil, attachMode != .attachAny {
            reconnectTarget[hostId] = sessionTarget
        }
        // A refusal belongs to the channel it happened on. Carrying it into a new one would put a
        // banner about a command from ten minutes ago above a session that just came back.
        host.lastCommandFailure = nil
        host.connectionState = .connecting
        hosts[hostId] = host
        broadcastState()

        do {
            let connection = try spawnChannel(
                host: host.config, sessionTarget: sessionTarget, mode: attachMode, role: .primary
            )
            connection.attachedByRememberedName = isRecovery && attachMode != .attachAny
            connections[hostId] = connection
        } catch {
            host.connectionState = .failed(reason: describe(error))
            hosts[hostId] = host
            broadcastState()
            throw error
        }
    }

    /// Spawns one control-mode channel and starts reading it. The one place a channel is made,
    /// whatever it is for — a follower differs from the primary only in what it attaches to and in
    /// what the rest of the service does with its events.
    private func spawnChannel(
        host config: HostConfig,
        sessionTarget: String,
        mode: TmuxCommand.AttachMode,
        role: Connection.Role
    ) throws -> Connection {
        let hostId = config.id
        let transport = PtyTransport()
        let connection = Connection(transport: transport, sessionTarget: sessionTarget, role: role)

        let (executable, arguments) = try invocation(for: config, mode: mode)
        log("[\(hostId)] spawn \(executable) \(arguments.map { "\"\($0)\"" }.joined(separator: " "))")

        let stream = try transport.spawn(
            executable: executable,
            arguments: arguments,
            environment: childEnvironment(),
            initialSize: (cols: 200, rows: 50)
        )

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
        connection.handshakeWatchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.handshakeTimeout)
            guard !Task.isCancelled else { return }
            await self?.handshakeTimedOut(hostId: hostId, epoch: epoch)
        }
        return connection
    }

    /// Gives up on a channel that spawned but never spoke tmux.
    ///
    /// Nothing bounded this before. `connectHost` set `.connecting` and returned as soon as the
    /// process existed, and the only timeout anywhere in the service was `sendAndAwait`'s two
    /// seconds — which is never reached, because the command that would use it is queued in the
    /// outbox behind the handshake. A login shell blocked on "press any key", a `ProxyCommand` that
    /// hangs, or a wedged remote tmux therefore left the host on "Connecting…" for the life of the
    /// process, with no error and nothing to retry. Failing the channel puts it on the ordinary
    /// recovery path, which is the same one a dropped link takes.
    private func handshakeTimedOut(hostId: String, epoch: UUID) {
        guard let connection = channel(of: hostId, epoch: epoch), !connection.handshakeComplete else { return }
        // Whatever ssh printed is the real diagnosis, exactly as it is for a channel that dies —
        // `channelClosed` builds that message from `preHandshakeLog`, so this only has to say why.
        log("[\(hostId)] no tmux handshake within \(Self.handshakeTimeout); giving up on the channel")
        channelClosed(
            hostId: hostId, epoch: epoch,
            error: PtyError.handshakeTimedOut(seconds: Int(Self.handshakeTimeout.components.seconds))
        )
    }

    // MARK: - A client per displayed session

    /// Tells the service which sessions are on screen, per host. Everything about follower channels
    /// follows from this one call.
    ///
    /// Sharing is by *session*, not by macOS window: two windows showing the same session are two
    /// views of one client, because a second client would stream the same panes twice for nothing.
    /// A window showing nothing, or a host that is not connected, contributes nothing.
    public func setDisplayedSessions(_ sessions: [String: Set<String>]) {
        guard displayedSessions != sessions else { return }
        displayedSessions = sessions
        for hostId in Set(sessions.keys).union(followerChannels.keys).union(connections.keys) {
            reconcileChannels(hostId: hostId)
        }
        // `liveSessionIds` just changed and nothing else is going to say so. Without this the view
        // that is deciding whether to draw the not-attached banner would not hear about the client
        // it asked for until some unrelated notification arrived — which is the flash again, only
        // slower and less predictable.
        broadcastState()
    }

    /// Brings a host's channels in line with what it is displaying: one client per session on
    /// screen, and none for a session nobody is looking at.
    ///
    /// The primary is moved rather than duplicated when its own session falls off screen. It has to
    /// be attached to *something* — it carries the connection — and leaving it on a session nobody
    /// can see would keep a client, and a `window-size manual`, on a session for no reason. Moving
    /// it is free: `switch-client` only strands panes when somebody is watching them, which is
    /// exactly the case this checks for.
    private func reconcileChannels(hostId: String) {
        guard let host = hosts[hostId], let primary = connections[hostId] else {
            // Nothing to attach with. Any followers left over belong to a channel set that is gone.
            for (_, follower) in followerChannels[hostId] ?? [:] {
                teardown(hostId: hostId, connection: follower)
            }
            followerChannels[hostId] = nil
            updateLiveSessions(hostId: hostId)
            return
        }
        let wanted = displayedSessions[hostId] ?? []
        let known = Set(host.sessions.map(\.id))

        // A session tmux has never mentioned cannot be attached to by id, and asking would fail a
        // command for something the user did not do. The next topology snapshot brings it back here.
        let attachable = wanted.intersection(known)

        if let attached = primary.attachedSessionId,
           !attachable.contains(attached),
           let adopt = attachable.subtracting(followerSessionIds(hostId)).sorted().first {
            primary.pendingSessionId = adopt
            switchSession(hostId: hostId, sessionId: adopt)
        }

        for sessionId in attachable where sessionId != primary.attachedSessionId {
            guard followerChannels[hostId]?[sessionId] == nil else { continue }
            startFollower(hostId: hostId, sessionId: sessionId, config: host.config)
        }

        let stale = (followerChannels[hostId] ?? [:])
            .filter { !attachable.contains($0.key) || $0.key == primary.attachedSessionId }
            .map { (sessionId: $0.key, epoch: $0.value.epoch) }
        for entry in stale {
            log("[\(hostId)] retiring the client for \(entry.sessionId)")
            // Detached because retiring waits for tmux to acknowledge the `window-size` restore, and
            // reconciling must not block on a round trip per session that left the screen.
            Task { [weak self] in
                await self?.retireFollower(
                    hostId: hostId, sessionId: entry.sessionId, epoch: entry.epoch
                )
            }
        }

        updateLiveSessions(hostId: hostId)
    }

    private func followerSessionIds(_ hostId: String) -> Set<String> {
        Set(followerChannels[hostId]?.keys.map { $0 } ?? [])
    }

    private func startFollower(hostId: String, sessionId: String, config: HostConfig) {
        do {
            // By id, never by name: a session renamed between the snapshot and the attach would
            // otherwise be created fresh under the old name by `new-session -A`.
            let connection = try spawnChannel(
                host: config, sessionTarget: sessionId,
                mode: .attach(sessionName: sessionId), role: .follower(sessionId: sessionId)
            )
            followerChannels[hostId, default: [:]][sessionId] = connection
            log("[\(hostId)] opened a second client for \(sessionId)")
        } catch {
            // Not a host failure: the primary is still up and the session is still listed. The panes
            // in it simply stay a snapshot, which is what the banner is for.
            log("[\(hostId)] could not open a client for \(sessionId): \(describe(error))")
        }
        updateLiveSessions(hostId: hostId)
    }

    /// Ends a follower, putting `window-size` back first — the same courtesy a deliberate disconnect
    /// owes, for the same reason: the option is a change to the user's session and it persists.
    private func retireFollower(hostId: String, sessionId: String, epoch: UUID) async {
        guard let follower = followerChannels[hostId]?[sessionId], follower.epoch == epoch else { return }
        follower.userInitiatedDisconnect = true
        await restoreWindowSizePolicy(hostId: hostId, connection: follower)
        guard followerChannels[hostId]?[sessionId]?.epoch == epoch else { return }

        // The decision to retire was made before that await, and the await is a round trip that can
        // take up to `sendAndAwait`'s two seconds. Tab away from a session and back inside that window
        // and `reconcileChannels` sees this entry still in place, so it declines to start a
        // replacement — and then the teardown below lands on the client the user is now looking at,
        // leaving every pane a frozen still frame with nothing scheduled to fix it. Re-reading the
        // condition here is the difference between "was stale when we started" and "is stale now".
        if displayedSessions[hostId]?.contains(sessionId) == true,
           connections[hostId]?.attachedSessionId != sessionId {
            log("[\(hostId)] \(sessionId) came back before its client was retired; keeping it")
            follower.userInitiatedDisconnect = false
            // Put back the option the restore above removed, or this session's windows would stop
            // being sized individually for the rest of the channel's life.
            applyWindowSizePolicy(hostId: hostId, connection: follower)
            updateLiveSessions(hostId: hostId)
            broadcastState()
            return
        }
        followerChannels[hostId]?.removeValue(forKey: sessionId)
        teardown(hostId: hostId, connection: follower)
        updateLiveSessions(hostId: hostId)
        broadcastState()
    }

    /// Publishes which sessions actually have a client, which is what tells a view whether it is
    /// looking at something live or at a photograph.
    private func updateLiveSessions(hostId: String) {
        var live: Set<String> = []
        for channel in channels(of: hostId) {
            // A channel that is still connecting counts. It is a moment old, it is going to be live,
            // and a banner that appears for that moment and then withdraws is worse than no banner.
            switch channel.role {
            case .primary:
                if let attached = channel.attachedSessionId { live.insert(attached) }
                if let pending = channel.pendingSessionId { live.insert(pending) }
            case .follower(let sessionId): live.insert(sessionId)
            }
        }
        withHost(hostId) { $0.liveSessionIds = live }
    }

    public func disconnectHost(hostId: String) async {
        // First, and outside the guard below: a host that is *only* waiting to retry has no
        // connection to find, and that is exactly the state a pending backoff has to be cancelled in.
        cancelScheduledReconnect(hostId: hostId)
        guard let connection = connections[hostId] else {
            reconnectAttempts[hostId] = 0
            withHost(hostId) { $0.connectionState = .disconnected }
            return
        }
        connection.userInitiatedDisconnect = true
        // The followers go first and by the same route, each putting its own session's `window-size`
        // back: they are clients of this host too, and leaving them attached would keep the host
        // "disconnected" with a fistful of live tmux clients behind it.
        for (sessionId, follower) in followerChannels[hostId] ?? [:] {
            follower.userInitiatedDisconnect = true
            await retireFollower(hostId: hostId, sessionId: sessionId, epoch: follower.epoch)
        }
        await restoreWindowSizePolicy(hostId: hostId, connection: connection)
        // The channel can end while we wait — the link drops, or tmux exits — and whichever path
        // noticed has already torn it down and set the state. Tearing down a *replacement* channel,
        // or marking a freshly reconnected host disconnected, is the failure this avoids.
        guard connections[hostId]?.epoch == connection.epoch else { return }
        teardown(hostId: hostId, connection: connection)
        reconnectAttempts[hostId] = 0
        withHost(hostId) { $0.connectionState = .disconnected }
    }

    /// Disconnects every host, putting each session's `window-size` back before the channel goes.
    ///
    /// Quitting is the ordinary way people close a Mac application, and until this existed it was the
    /// one exit that skipped `restoreWindowSizePolicy` entirely — so ⌘Q left `manual` set on the
    /// user's sessions for the next plain `tmux attach` to find windows that no longer follow the
    /// terminal. `disconnectHost` already does the work and already waits for tmux's own `%end`
    /// rather than merely writing the line; all that was missing was somebody to call it on the way
    /// out.
    ///
    /// Hosts go concurrently. They are independent channels and a slow or wedged one must not decide
    /// how long the others take — the caller is holding a quit open while this runs.
    public func shutdown() async {
        await withTaskGroup(of: Void.self) { group in
            for hostId in Set(connections.keys).union(followerChannels.keys) {
                group.addTask { await self.disconnectHost(hostId: hostId) }
            }
        }
    }

    private func defaultSessionName(for config: HostConfig) -> String {
        "tetmux-main"
    }

    private func invocation(
        for config: HostConfig,
        mode: TmuxCommand.AttachMode
    ) throws -> (executable: String, arguments: [String]) {
        if config.isLocal {
            guard let tmux = PtyTransport.resolveExecutable("tmux", path: searchPath()) else {
                throw PtyError.executableNotFound("tmux")
            }
            return (tmux, TmuxCommand.localArguments(mode: mode))
        }

        let remoteCommand = TmuxCommand.remoteCommand(mode: mode)

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
            expectsPasswordPrompt: config.usesPassword,
            extraArguments: TmuxCommand.splitArguments(config.extraSshArguments),
            forwardsX11: config.forwardsX11
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

    /// Every live channel of a host, primary first.
    private func channels(of hostId: String) -> [Connection] {
        let followers = followerChannels[hostId]?.values.map { $0 } ?? []
        return (connections[hostId].map { [$0] } ?? []) + followers
    }

    /// The channel an epoch belongs to, whichever kind it is. Reads from the channel are tagged with
    /// their epoch precisely so a message from a channel that has since been replaced is ignored.
    private func channel(of hostId: String, epoch: UUID) -> Connection? {
        channels(of: hostId).first { $0.epoch == epoch }
    }

    private func ingest(hostId: String, epoch: UUID, data: Data) {
        guard let connection = channel(of: hostId, epoch: epoch) else { return }

        if !connection.handshakeComplete {
            connection.preHandshakeLog.append(contentsOf: data)
            if connection.preHandshakeLog.count > 8192 {
                connection.preHandshakeLog.removeFirst(connection.preHandshakeLog.count - 8192)
            }
            // A follower reaches the same host through the same credentials the primary already
            // used, so a prompt on one is the primary's story to tell — and a sheet raised by a
            // channel the user did not ask for would be unexplainable.
            if connection.isPrimary {
                detectAuthenticationPrompt(hostId: hostId, connection: connection)
            }
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
            if let last = connection.lastCommandNumber, number <= last {
                // Server-wide numbers only ever go up. A repeat means we are reading something that
                // is not the frame we think it is.
                log("[\(hostId)] protocol desync: %begin \(number) after \(last)")
            }
            connection.lastCommandNumber = number
            connection.currentNumber = number
            if connection.pending.isEmpty {
                // Expected exactly once — tmux's own block on attach, before the handshake completes.
                // Any later occurrence means the FIFO has slipped and every subsequent response will
                // be attributed to the wrong command, so it is worth a line in the log even though
                // there is nothing to do about it here.
                if connection.handshakeComplete {
                    log("[\(hostId)] protocol desync: %begin \(number) with no command pending")
                }
                connection.current = PendingCommand(text: "", kind: .ignore)
            } else {
                connection.current = connection.pending.removeFirst()
            }

        case .commandResultLine(_, _, let bytes):
            connection.current?.lines.append(bytes)

        case .end(_, let number, _):
            if let open = connection.currentNumber, open != number {
                log("[\(hostId)] protocol desync: %end \(number) closing block \(open)")
            }
            let completed = connection.current
            connection.current = nil
            connection.currentNumber = nil
            if let completed {
                complete(completed, hostId: hostId, connection: connection)
            }
            completeHandshakeIfNeeded(hostId: hostId, connection: connection)

        case .error(_, let number, _):
            if let open = connection.currentNumber, open != number {
                log("[\(hostId)] protocol desync: %error \(number) closing block \(open)")
            }
            let failed = connection.current
            connection.current = nil
            connection.currentNumber = nil
            let message = (failed?.lines ?? []).map { String(decoding: $0, as: UTF8.self) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            log("[\(hostId)] %error \(number): \(message)")

            // A `switch-client` that tmux refused — the session was killed between the snapshot and
            // the command — leaves `pendingSessionId` set, and only `%session-changed` clears it.
            // `liveSessionIds` counts a pending switch as live on purpose, so nothing would ever
            // withdraw the claim: the window stays a frozen still frame with no banner saying so.
            if failed?.text.hasPrefix("switch-client") == true, connection.pendingSessionId != nil {
                connection.pendingSessionId = nil
                updateLiveSessions(hostId: hostId)
            }

            switch failed?.kind {
            case .capturePane(let paneId, _):
                // The pane vanished between subscribe and capture; let a later attempt retry.
                connection.repaintedPanes.remove(paneId)
            case .userCommand(let action):
                // §7 — the user asked for this and it did not happen. Saying so, in tmux's own words,
                // is the difference between a command that failed and one that silently did nothing.
                withHost(hostId) { host in
                    host.lastCommandFailure = CommandFailure(
                        action: action,
                        message: message.isEmpty ? "tmux rejected the command" : message
                    )
                }
            case .acknowledged(let id):
                // A refusal is an answer. The waiter is holding a channel open until tmux has dealt
                // with the command, and it has.
                resumeAcknowledgement(id, connection: connection)
            case nil:
                // No command matched this block, so nothing above knows what failed — and tmux only
                // ever sends `%error` because something did. Dropping the text left the one case
                // where a failure is certain as the one case that said nothing at all.
                withHost(hostId) { host in
                    host.lastCommandFailure = CommandFailure(
                        action: "tmux reported an error",
                        message: message.isEmpty ? "tmux rejected a command" : message
                    )
                }
            default:
                break
            }
            completeHandshakeIfNeeded(hostId: hostId, connection: connection)

        case .output(let paneId, let data), .extendedOutput(let paneId, _, let data):
            guard claimsPane(hostId: hostId, paneId: paneId, epoch: connection.epoch) else { break }
            deliver(data, hostId: hostId, paneId: paneId, from: connection)

        case .layoutChange(let windowId, let layout, let visibleLayout, let flags):
            withHost(hostId) { host in
                Self.mutateWindow(&host, windowId: windowId) {
                    $0.apply(layoutString: layout, visibleLayout: visibleLayout, flags: flags)
                }
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
            // The notification says a window closed, not which sessions it left, and `unlink-window`
            // (F4.9) produces the same one for a window that is still very much alive in another
            // session. Dropping it everywhere is right for a kill and wrong for an unlink, so let
            // tmux settle the difference rather than guessing from the notification.
            scheduleTopologyRefresh(hostId: hostId)

        case .windowRenamed(let windowId, let name), .unlinkedWindowRenamed(let windowId, let name):
            withHost(hostId) { host in
                Self.mutateWindow(&host, windowId: windowId) { $0.name = name }
            }
            // An automatic rename *is* tmux telling us the foreground command changed. Nothing
            // announces `pane_current_command`, so this is the closest notification there is, and the
            // sidebar labels every pane by its command — without this they stayed as they were until
            // some unrelated structural change happened to refresh them.
            schedulePaneRefresh(hostId: hostId)

        case .windowPaneChanged(let windowId, let paneId):
            withHost(hostId) { host in
                Self.mutateWindow(&host, windowId: windowId) { window in
                    window.activePaneId = paneId
                    for index in window.panes.indices {
                        window.panes[index].isActive = window.panes[index].id == paneId
                    }
                }
            }
            // Moving between panes is the other moment a label can go stale: a command started in a
            // pane that was not current renames no window, so nothing else would report it.
            schedulePaneRefresh(hostId: hostId)

        case .sessionChanged(let sessionId, let name):
            connection.attachedToSession = true
            let previous = connection.attachedSessionId
            connection.attachedSessionId = sessionId
            if connection.pendingSessionId == sessionId { connection.pendingSessionId = nil }
            withHost(hostId) { host in
                if let index = host.sessions.firstIndex(where: { $0.id == sessionId }) {
                    host.sessions[index].name = name
                    host.sessions[index].isAttached = true
                } else {
                    host.sessions.append(TmuxSession(id: sessionId, name: name, isAttached: true))
                }
            }
            // `window-size` is a session option, so the session we just moved to needs it too. Every
            // channel does this for its own session; a follower is a client like any other.
            applyWindowSizePolicy(hostId: hostId, connection: connection)
            updateLiveSessions(hostId: hostId)

            if connection.isPrimary {
                withHost(hostId) { $0.activeSessionId = sessionId }
                // Where a reconnect has to land. `switch-client` arrives here too, so this tracks the
                // session the client is really on rather than the one it originally attached to.
                reconnectTarget[hostId] = name
                scheduleTopologyRefresh(hostId: hostId)
            }
            // This client just moved. Panes it was painting belong to the session it left and will
            // go silent, and panes in the new one have sent nothing yet, so what it owns has to be
            // repainted from tmux's scrollback — and released first, since another client may now be
            // the one that can see them.
            if previous != nil, previous != sessionId {
                releasePanes(hostId: hostId, ownedBy: connection.epoch)
            }
            repaintSubscribedPanes(hostId: hostId)

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
            // tmux's own `pause-after`: this client is more than `pauseAfterSeconds` behind on the
            // wire. Recorded so the pane is not left paused — tmux never resumes it by itself, and
            // `applyFlowControl` is the only thing that will, once the viewer has drained.
            log("[\(hostId)] tmux paused \(paneId): this client is behind")
            if connection.pausedPanes[paneId] == nil {
                connection.pausedPanes[paneId] = .server(since: .now)
                // Deliberately no `applyFlowControl` here. It would find a drained viewer and resume
                // at once, which is the cycle the hold-down exists to break; the next acknowledgement
                // or chunk calls it anyway, by which time the hold-down can actually be judged.
                break
            }
            applyFlowControl(hostId: hostId, paneId: paneId)

        case .continuePane(let paneId):
            log("[\(hostId)] flow control resumed for \(paneId)")
            connection.pausedPanes.removeValue(forKey: paneId)
            // Whatever was dropped while paused has to come from the pane itself.
            connection.lossyPanes.remove(paneId)
            requestRepaintAfterLoss(hostId: hostId, paneId: paneId)

        case .paneModeChanged(let paneId):
            // A mode is a per-client screen overlay and control mode is not streamed one, so the
            // bytes for what is now on that pane never arrive: entering copy mode from another client
            // (or from a `prefix [` that reached tmux) leaves the pane showing the screen from before
            // and no notification ever corrects it. A repaint is the only way to see the mode at all,
            // and leaving it is the pane looking frozen with nothing wrong.
            log("[\(hostId)] pane mode changed on \(paneId); repainting")
            requestRepaintAfterLoss(hostId: hostId, paneId: paneId)

        case .configError(let text):
            // Reported here and nowhere else. Not `.ignore`-worthy: the user is looking at a tmux
            // whose configuration did not fully load, and every symptom of that is baffling.
            log("[\(hostId)] tmux config error: \(text)")
            withHost(hostId) { host in
                host.lastCommandFailure = CommandFailure(
                    action: "tmux configuration",
                    message: text.isEmpty ? "tmux reported an error in its configuration" : text
                )
            }

        case .message(let text):
            log("[\(hostId)] tmux message: \(text)")

        case .clientDetached, .clientSessionChanged:
            break

        case .exit(let reason):
            log("[\(hostId)] %exit \(reason ?? "")")
            // Orderly: tmux is ending this client on purpose. `channelClosed` needs to know, because
            // the recovery for this is nothing like the recovery for a dropped link.
            connection.serverEnded = true
            // Only the primary speaks for the host. A follower exiting means its session ended or
            // was killed — one session's panes stop, which the topology refresh will explain — and
            // saying "the tmux server exited" because of it would be false while the primary is
            // sitting right there, connected.
            if connection.isPrimary {
                withHost(hostId) { host in
                    host.connectionState = .degraded(reason: reason ?? "tmux server exited")
                }
            } else {
                scheduleTopologyRefresh(hostId: hostId)
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
        // Deliberately not logging which outcome carried what: this is the one write whose payload
        // is a secret, and the count of bytes that reached the tty is the length of the password.
        let outcome = connection.transport.write(bytes)
        log("[\(hostId)] answered ssh prompt (\(outcome == .complete ? "written" : "write failed"))")
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
        connection.handshakeWatchdog?.cancel()
        connection.handshakeWatchdog = nil
        connection.preHandshakeLog.removeAll()

        // A follower is one session's output, nothing more. It does not decide that the host is
        // connected (the primary already did), it does not clear a prompt it never raised, and it
        // does not reset the reconnect counter, which belongs to the connection this rides on. What
        // it does need is the version — the sizing and flow-control policies it applies to its own
        // session are chosen from it — and a repaint of what it is now responsible for.
        if connection.isPrimary {
            // Landed, so the name question is settled either way.
            recoveryLostItsSession.remove(hostId)
            // Whatever ssh asked for, it got: the protocol is speaking.
            withHost(hostId) { $0.authenticationPrompt = nil }
            withHost(hostId) { host in
                host.connectionState = .connected
            }
            reconnectAttempts[hostId] = 0
        }

        // Flush anything the UI queued while we were still connecting.
        let queued = connection.outbox
        connection.outbox.removeAll()

        send("display-message -p '#{version}'", kind: .version, hostId: hostId, connection: connection)
        // The `window-size` policy waits for that version: which of the two sizing models is available
        // depends on it, and choosing wrongly either collapses every pane toward 80x24 or leaves a
        // torn-off window unable to size itself. See `applyWindowSizePolicy`.
        send("list-clients -F \(TmuxCommand.quote(TmuxCommand.clientsFormat))",
             kind: .listClients, hostId: hostId, connection: connection)
        // One channel's worth of topology is the whole server's, so a follower asking again would
        // only duplicate three round trips and one broadcast.
        if connection.isPrimary {
            refreshTopology(hostId: hostId, connection: connection)
        }
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
        case .ignore, .userCommand:
            // Nothing to read on success. The point of the label is the `%error` path.
            break

        case .version:
            // A version that will not parse used to `break` and leave `connection.version` nil for
            // good — and every sizing path guards on it, so `applyWindowSizePolicy` returned at its
            // first line, `sizesWindowsIndividually` stayed false, and `flushWindowResizes` dropped
            // every resize for the life of the channel. Silently, and for a string tmux is entitled
            // to change. Falling back to the control-mode floor is the conservative reading: it uses
            // `window-size latest` and `refresh-client -C`, which every version that can speak to us
            // at all understands.
            let raw = text().first ?? ""
            let version = TmuxVersion(raw) ?? {
                log("[\(hostId)] could not parse tmux version \(raw.isEmpty ? "(no answer)" : "'\(raw)'"); assuming 2.4")
                return TmuxVersion("2.4")!
            }()
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
            applyFlowControlPolicy(hostId: hostId, connection: connection)
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

        case .acknowledged(let id):
            resumeAcknowledgement(id, connection: connection)
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
        // Widen whatever is already pending: a full refresh asks for everything a pane refresh does.
        connection.pendingRefreshIsFullTopology = true
        guard connection.topologyRefreshTask == nil else { return }
        connection.topologyRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            await self?.runScheduledRefresh(hostId: hostId)
        }
    }

    /// Re-reads pane state only.
    ///
    /// Separate from `refreshTopology` because it runs far more often — on every automatic rename and
    /// every pane switch — and the session and window lists have not changed at those moments. Shares
    /// the same debounce task, so a burst of notifications costs one round trip.
    private func schedulePaneRefresh(hostId: String) {
        guard let connection = connections[hostId], connection.handshakeComplete else { return }
        // Never narrows a full refresh that is already pending.
        guard connection.topologyRefreshTask == nil else { return }
        connection.pendingRefreshIsFullTopology = false
        connection.topologyRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            await self?.runScheduledRefresh(hostId: hostId)
        }
    }

    private func runScheduledRefresh(hostId: String) {
        guard let connection = connections[hostId] else { return }
        connection.topologyRefreshTask = nil
        let full = connection.pendingRefreshIsFullTopology
        connection.pendingRefreshIsFullTopology = false
        if full {
            refreshTopology(hostId: hostId, connection: connection)
        } else {
            send("list-panes -a -F \(TmuxCommand.quote(TmuxCommand.panesFormat))",
                 kind: .listPanes, hostId: hostId, connection: connection)
        }
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
        // `session_attached` is now a fact about several clients rather than one, and the primary's
        // is the one `activeSessionId` means: the session commands default to and reconnects return
        // to. Taking whichever attached session sorted first would move it whenever a second client
        // appeared.
        if let attached = connections[hostId]?.attachedSessionId, seen(hostId, attached) {
            withHost(hostId) { $0.activeSessionId = attached }
        }
        // Catches a rename we learned about from `list-sessions` rather than from a notification —
        // another client renaming the session while our channel was down, for instance.
        syncReconnectTarget(hostId: hostId)
        // A session that appeared can now be attached to by id, and one that vanished has a client
        // to retire. This is the only moment either becomes true.
        reconcileChannels(hostId: hostId)
        updateLiveSessions(hostId: hostId)
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
    private func seen(_ hostId: String, _ sessionId: String) -> Bool {
        hosts[hostId]?.sessions.contains { $0.id == sessionId } ?? false
    }

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
                // The name is last and may itself contain `|`, so it takes whatever is left.
                let fields = line.split(separator: "|", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count >= 9 else { continue }
                let sessionId = String(fields[0])
                let windowId = String(fields[1])
                let isActive = fields[2] == "1"
                let hasActivity = fields[3] == "1"
                // `automatic-rename` is 1 while tmux owns the name; 0 once the user has set one.
                let hasExplicitName = fields[4] == "0"
                let layout = String(fields[5])
                let visibleLayout = String(fields[6])
                let flags = String(fields[7])
                let name = String(fields[8])

                seenBySession[sessionId, default: []].insert(windowId)

                guard let sessionIndex = host.sessions.firstIndex(where: { $0.id == sessionId }) else { continue }
                if let windowIndex = host.sessions[sessionIndex].windows.firstIndex(where: { $0.id == windowId }) {
                    host.sessions[sessionIndex].windows[windowIndex].name = name
                    host.sessions[sessionIndex].windows[windowIndex].isActive = isActive
                    host.sessions[sessionIndex].windows[windowIndex].hasActivity = hasActivity
                    host.sessions[sessionIndex].windows[windowIndex].hasExplicitName = hasExplicitName
                    host.sessions[sessionIndex].windows[windowIndex].apply(
                        layoutString: layout, visibleLayout: visibleLayout, flags: flags
                    )
                } else {
                    var window = TmuxWindow(
                        id: windowId, name: name, isActive: isActive, hasActivity: hasActivity,
                        hasExplicitName: hasExplicitName
                    )
                    window.apply(layoutString: layout, visibleLayout: visibleLayout, flags: flags)
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
        // `list-panes -a` is the authoritative pane census, so this is the one moment the service can
        // tell a pane that is gone from one it has simply not heard about yet.
        pruneVanishedPanes(hostId: hostId)
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
            // Bounded, and the *oldest* go first. A surface still has focus while its host reconnects,
            // so everything typed into it queues here — and the whole queue is replayed the moment the
            // handshake lands. Unbounded, a host that took minutes to come back injected minutes of
            // keystrokes into the pane at once, which is both a surprise and a hazard. Keeping the
            // newest is the right end to keep: it is what the user typed most recently.
            connection.outbox.append(command)
            if connection.outbox.count > Self.maxOutboxCommands {
                let dropped = connection.outbox.count - Self.maxOutboxCommands
                connection.outbox.removeFirst(dropped)
                log("[\(hostId)] outbox full; dropped \(dropped) command(s) queued before the handshake")
            }
            return
        }
        guard let data = (text + "\n").data(using: .utf8) else { return }
        // Enqueue before writing: tmux answers in order, and the reply can arrive before this
        // function returns if the actor suspends.
        connection.pending.append(command)
        switch connection.transport.write(data) {
        case .complete:
            break

        case .nothingWritten:
            connection.pending.removeLast()
            log("[\(hostId)] write failed for: \(text)")
            // Nothing will ever answer a command that was never written.
            if case .acknowledged(let id) = kind { resumeAcknowledgement(id, connection: connection) }

        case .partial(let bytesWritten):
            // A fragment with no newline is now in front of tmux's parser, and the next command
            // written will be concatenated onto it — tmux answers one block for two commands and the
            // FIFO is misaligned for good. Unqueueing the command would only decide *which* responses
            // are misattributed, so the channel goes instead and recovery reattaches on a clean one.
            // The reachable cause is a large paste over a congested link, which is exactly when the
            // chunks are big enough for the pty buffer to fill mid-command.
            log("[\(hostId)] partial write (\(bytesWritten)/\(data.count)) for: \(text)")
            channelClosed(
                hostId: hostId,
                epoch: connection.epoch,
                error: PtyError.writeTruncated(bytesWritten: bytesWritten, of: data.count)
            )
        }
    }

    private func send(_ text: String, kind: PendingCommand.Kind = .ignore, hostId: String) {
        guard let connection = connections[hostId] else { return }
        send(text, kind: kind, hostId: hostId, connection: connection)
    }

    /// Sends `text` and returns once tmux has answered it, or once `timeout` has passed.
    ///
    /// The timeout is not a formality: a channel can be alive enough to accept a write and never
    /// answer — a wedged ssh link takes ~45 s to become EOF — and a disconnect that hangs on one is
    /// worse than a session option left set. Every other path that could strand the waiter resumes
    /// it instead: a write that fails, an `%error`, and `teardown`.
    private func sendAndAwait(
        _ text: String,
        hostId: String,
        connection: Connection,
        timeout: Duration = .seconds(2)
    ) async {
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.acknowledgements[id] = continuation
            send(text, kind: .acknowledged(id), hostId: hostId, connection: connection)
            Task { [weak connection] in
                try? await Task.sleep(for: timeout)
                guard let connection else { return }
                // Inherits this actor's isolation, so it lands back here to touch the dictionary.
                self.resumeAcknowledgement(id, connection: connection)
            }
        }
    }

    /// Resumes one waiter, at most once. Every path that can end a command's life calls this, so the
    /// removal is what makes a second call harmless.
    private func resumeAcknowledgement(_ id: UUID, connection: Connection) {
        connection.acknowledgements.removeValue(forKey: id)?.resume()
    }

    // MARK: - Pane output

    /// Whether `epoch` is the channel whose bytes for this pane are the ones to paint.
    ///
    /// Unclaimed panes are claimed on the spot, so in the ordinary case — one client that can see
    /// the pane — this costs a dictionary lookup and answers yes. It matters when a window is linked
    /// into two displayed sessions: both clients then stream the same pane, and painting both would
    /// double every byte.
    private func claimsPane(hostId: String, paneId: String, epoch: UUID) -> Bool {
        if let owner = paneOwners[hostId]?[paneId] { return owner == epoch }
        paneOwners[hostId, default: [:]][paneId] = epoch
        return true
    }

    /// Drops a dead channel's claims and repaints what it was painting.
    ///
    /// The repaint is the point. Another client may have been streaming those panes all along and
    /// having its bytes dropped, so it is mid-stream on a screen it never drew; a capture puts the
    /// pane and the new owner back in agreement in one command.
    private func releasePanes(hostId: String, ownedBy epoch: UUID) {
        let orphaned = (paneOwners[hostId] ?? [:]).filter { $0.value == epoch }.map(\.key)
        guard !orphaned.isEmpty else { return }
        for paneId in orphaned {
            paneOwners[hostId]?.removeValue(forKey: paneId)
            connections[hostId]?.repaintedPanes.remove(paneId)
        }
        guard connections[hostId] != nil else { return }
        for paneId in orphaned where outputSubscribers[hostId]?[paneId]?.isEmpty == false {
            requestRepaint(hostId: hostId, paneId: paneId)
        }
    }

    /// Hands pane bytes to the views showing it. `target` restricts delivery to one subscriber, which
    /// only a repaint ever does.
    private func deliver(
        _ data: Data, hostId: String, paneId: String, target: UUID? = nil, from source: Connection? = nil
    ) {
        guard let subscribers = outputSubscribers[hostId]?[paneId], !subscribers.isEmpty else { return }
        // Loss is a property of the channel that lost it, and so is the pause that answers it.
        let channel = source ?? connections[hostId]

        for (id, subscriber) in subscribers where target == nil || target == id {
            // The byte ceiling is enforced here rather than left to the stream's buffering policy,
            // which can only count elements. `%output` chunk sizes vary by orders of magnitude with
            // what the pane is doing, so an element bound is a byte bound only by accident: at a few
            // hundred bytes a chunk, a buffer deep enough to hold a megabyte of `cat` is also deep
            // enough that a chatty pane fills it long before the high-water mark trips, and the pause
            // that is supposed to be the mechanism never fires at all.
            guard subscriber.outstanding < paneMaxBufferedBytes else {
                channel?.lossyPanes.insert(paneId)
                continue
            }

            switch subscriber.continuation.yield(data) {
            case .enqueued:
                subscriber.outstanding += data.count
            case .dropped(let discarded):
                // The buffer was full, so the *oldest* chunk was discarded to make room. Feeding the
                // rest to the emulator would splice a hole into the byte stream and desynchronise the
                // grid, so the pane is marked for repair instead. The repaint is deferred until the
                // viewer has caught up: one per dropped chunk would be a command flood, and a
                // `capture-pane` queued behind the backlog it is meant to repair arrives stale.
                //
                // The discarded chunk comes back off the books here. It will never reach the viewer
                // and so will never be acknowledged, and counting it would inflate `outstanding` by
                // that much forever — enough overruns and the pane would sit permanently above the
                // high-water mark, paused with nothing left to drain.
                subscriber.outstanding += data.count - discarded.count
                channel?.lossyPanes.insert(paneId)
            case .terminated:
                break
            @unknown default:
                break
            }
        }

        applyFlowControl(hostId: hostId, paneId: paneId)
    }

    /// Reports bytes a view has finished feeding to its emulator, so the pane can be resumed once it
    /// has caught up.
    ///
    /// Batched by the caller: an actor hop per chunk would cost more than the accounting is worth, and
    /// the thresholds are far enough apart that a partial batch never decides anything.
    public func acknowledge(hostId: String, paneId: String, subscriber: UUID, bytes: Int) {
        guard bytes > 0, let entry = outputSubscribers[hostId]?[paneId]?[subscriber] else { return }
        entry.outstanding = max(entry.outstanding - bytes, 0)
        applyFlowControl(hostId: hostId, paneId: paneId)
    }

    /// Pauses a pane whose slowest viewer is too far behind, and resumes it once that viewer has
    /// caught up (P6.5).
    ///
    /// The slowest viewer decides, because output goes to all of them: pausing on the average would
    /// let one struggling window grow without bound, and there is no way to serve a pane to one
    /// viewer and withhold it from another.
    private func applyFlowControl(hostId: String, paneId: String) {
        // `refresh-client -A` is a property of the *client*, so the pause has to be asked of the one
        // that is actually sending this pane. Asking the primary to pause a pane it is not streaming
        // does nothing at all, silently, and the viewer that is drowning stays drowning.
        guard let connection = streamingChannel(hostId: hostId, paneId: paneId) else { return }
        let outstanding = outputSubscribers[hostId]?[paneId]?.values.map(\.outstanding).max() ?? 0
        let isPaused = connection.pausedPanes[paneId] != nil

        if connection.supportsFlowControl {
            if !isPaused, outstanding >= paneHighWaterBytes {
                connection.pausedPanes[paneId] = .viewer
                log("[\(hostId)] pausing \(paneId): \(outstanding) bytes undelivered")
                send(TmuxCommand.flowControl(paneId: paneId, paused: true),
                     kind: .ignore, hostId: hostId, connection: connection)
                return
            }
            // A pane tmux paused on its own is still ours to resume — nothing else will, and a pane
            // left paused never moves again — but not before the hold-down has run, or the pause is
            // undone in the same breath it arrived in.
            if case .server(let since) = connection.pausedPanes[paneId],
               since.duration(to: .now) < Connection.serverPauseHoldDown {
                return
            }
            if isPaused, outstanding <= paneLowWaterBytes {
                connection.pausedPanes.removeValue(forKey: paneId)
                // tmux discards a paused pane's output rather than queueing it, so the emulator now
                // holds a snapshot with a gap after it. The `%continue` this triggers repaints, which
                // covers any buffer overrun too.
                connection.lossyPanes.remove(paneId)
                log("[\(hostId)] resuming \(paneId)")
                send(TmuxCommand.flowControl(paneId: paneId, paused: false),
                     kind: .ignore, hostId: hostId, connection: connection)
                return
            }
        }

        // Either the server is too old to pause a pane, or the pause has not tripped. Repair a buffer
        // overrun once the viewer has caught up — below 3.2 this bound is the whole mechanism.
        guard !isPaused, outstanding <= paneLowWaterBytes,
              connection.lossyPanes.remove(paneId) != nil else { return }
        log("[\(hostId)] \(paneId) overran its buffer; repainting")
        requestRepaintAfterLoss(hostId: hostId, paneId: paneId)
    }

    /// The channel that streams a pane: whoever claimed it, else the primary.
    private func streamingChannel(hostId: String, paneId: String) -> Connection? {
        if let epoch = paneOwners[hostId]?[paneId], let owner = channel(of: hostId, epoch: epoch) {
            return owner
        }
        return connections[hostId]
    }

    /// Repaints a pane after bytes were lost, rather than after it merely appeared on screen.
    ///
    /// Distinct from `requestRepaint`'s first-subscription case in one way that matters: the pane is
    /// already marked as painted, so the ordinary suppression would drop this on the floor.
    private func requestRepaintAfterLoss(hostId: String, paneId: String) {
        connections[hostId]?.repaintedPanes.remove(paneId)
        requestRepaint(hostId: hostId, paneId: paneId)
    }

    /// Streams a pane's output. On first subscription the pane is repainted from tmux's own
    /// scrollback, because control mode sends nothing at all for a pane that is merely sitting
    /// there — attaching to an existing session would otherwise show an empty terminal (F4.16).
    ///
    /// A *second* subscriber to a pane — the same tmux window open in two macOS windows — gets its own
    /// repaint, addressed to it alone. Without that it would sit blank until the pane next produced
    /// output, because `repaintedPanes` remembers that the pane was already captured; broadcasting the
    /// repaint instead would clear the first window's scrollback.
    public func subscribeToPane(hostId: String, paneId: String) -> PaneSubscription {
        let id = UUID()
        // Bounded, so a pane producing faster than its viewer paints cannot grow without limit. The
        // oldest chunk is the one dropped: the newest is the one the screen is closest to, and the
        // repaint that follows makes the distinction moot anyway.
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self, bufferingPolicy: .bufferingNewest(paneBufferChunks)
        )
        let isAdditionalViewer = outputSubscribers[hostId]?[paneId]?.isEmpty == false
        outputSubscribers[hostId, default: [:]][paneId, default: [:]][id] = PaneSubscriber(continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(hostId: hostId, paneId: paneId, id: id) }
        }
        requestRepaint(hostId: hostId, paneId: paneId, target: isAdditionalViewer ? id : nil)
        return PaneSubscription(id: id, stream: stream)
    }

    private func unsubscribe(hostId: String, paneId: String, id: UUID) {
        outputSubscribers[hostId]?[paneId]?.removeValue(forKey: id)
        if outputSubscribers[hostId]?[paneId]?.isEmpty == true {
            outputSubscribers[hostId]?.removeValue(forKey: paneId)
            // Next time this pane is displayed it needs a fresh repaint.
            connections[hostId]?.repaintedPanes.remove(paneId)
        }
        // The viewer that was behind is gone, so whatever it was holding back no longer justifies a
        // paused pane — and with no subscriber left there is nobody to acknowledge it back to life.
        applyFlowControl(hostId: hostId, paneId: paneId)
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
        send("switch-client -t \(TmuxCommand.quote(sessionId))",
             kind: .userCommand("Switch session"), hostId: hostId)
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
        send("paste-buffer -d -p -b \(buffer) -t \(paneId)",
             kind: .userCommand("Paste"), hostId: hostId, connection: connection)
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

    /// Turns on tmux's half of backpressure, once the server version is known (P6.5).
    ///
    /// `pause-after` bounds what tmux will queue for this client before it stops sending a pane —
    /// the only thing that can, since a backlog inside the server is invisible from our side of the
    /// pty until it arrives. Below 3.2 there is no such mechanism, and the bounded per-pane buffer is
    /// left to carry it alone.
    ///
    /// A client flag rather than a session option, so unlike `window-size` it dies with the channel
    /// and leaves nothing to restore. It also switches the server to `%extended-output`, which
    /// `ControlCodec` already handles.
    private func applyFlowControlPolicy(hostId: String, connection: Connection) {
        guard let version = connection.version, version.supportsFlowControl else {
            connection.supportsFlowControl = false
            return
        }
        connection.supportsFlowControl = true
        send(TmuxCommand.pauseAfterFlag(seconds: pauseAfterSeconds),
             kind: .ignore, hostId: hostId, connection: connection)
    }

    /// Puts `window-size` back to whatever the session inherited, on the way out.
    ///
    /// `window-size manual` is a change to the user's own session, and a manual size persists — a later
    /// plain `tmux attach` would find windows that no longer follow the terminal.
    ///
    /// **Waited for**, which is the only reason it works. `teardown` hangs the channel up with
    /// `SIGHUP`, and the tmux client has to have *read* the line out of the pty before that lands —
    /// writing it and immediately terminating is a race the local client usually wins and a loaded
    /// machine loses outright, leaving `window-size manual` on the user's session for the next plain
    /// `tmux attach` to find. Over ssh there is a whole network in the gap. So this waits for tmux's
    /// own `%end`, which says the server ran it, and only then may the caller tear anything down.
    ///
    /// Still best-effort in one direction: it can only run on a *deliberate* disconnect, so a channel
    /// that dies with the network leaves the option set. tetmux sets it again on the next attach, so
    /// the visible effect is limited to attaching with something else in the meantime.
    private func restoreWindowSizePolicy(hostId: String, connection: Connection) async {
        guard connection.sizesWindowsIndividually, connection.handshakeComplete else { return }
        let target = TmuxCommand.quote(reconnectTarget[hostId] ?? connection.sessionTarget)
        await sendAndAwait("set-option -u -t \(target) window-size", hostId: hostId, connection: connection)
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
    /// Drops per-pane bookkeeping for panes the host no longer has.
    ///
    /// `paneOwners`, `repaintedPanes`, `pausedPanes` and `lossyPanes` gain an entry for every pane
    /// that ever produced output, and the only removals were by channel epoch or on `removeHost` —
    /// there was a `forgetWindowGeometry` for windows and no pane-level equivalent, so killing panes
    /// on a long-lived connection grew all four without bound. tmux never reuses a pane id, so it was
    /// monotonic.
    ///
    /// Driven from the model rather than from `%window-close`, which cannot distinguish a window that
    /// was killed from one that was merely unlinked (F4.9) and is still alive in another session.
    /// Anything still in the topology is left alone, so an unlink prunes nothing.
    private func pruneVanishedPanes(hostId: String) {
        guard let host = hosts[hostId] else { return }
        // Never prune from an empty topology: at handshake, and for the moment after a reattach
        // before `list-panes` answers, "no panes" means "not yet known", not "all gone".
        let live = Set(host.sessions.flatMap { $0.windows.flatMap { window in
            window.panes.map(\.id) + (window.layoutTree?.paneIds ?? [])
        } })
        guard !live.isEmpty else { return }

        for paneId in (paneOwners[hostId] ?? [:]).keys where !live.contains(paneId) {
            paneOwners[hostId]?.removeValue(forKey: paneId)
        }
        for channel in channels(of: hostId) {
            channel.repaintedPanes.formIntersection(live)
            channel.lossyPanes.formIntersection(live)
            for paneId in channel.pausedPanes.keys where !live.contains(paneId) {
                channel.pausedPanes.removeValue(forKey: paneId)
            }
        }
    }

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
        send("new-window\(target)", kind: .userCommand("New window"), hostId: hostId)
    }

    public func splitPane(hostId: String, paneId: String, leftRight: Bool) {
        send("split-window \(leftRight ? "-h" : "-v") -t \(paneId)",
             kind: .userCommand("Split pane"), hostId: hostId)
    }

    public func killPane(hostId: String, paneId: String) {
        send("kill-pane -t \(paneId)", kind: .userCommand("Close pane"), hostId: hostId)
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
        send("rename-window -t \(windowId) \(TmuxCommand.quote(name))",
             kind: .userCommand("Rename window"), hostId: hostId)
    }

    /// F4.9 — closing a tab unlinks the window from the session; it never kills what is running.
    public func unlinkWindow(hostId: String, windowId: String) {
        send("unlink-window -t \(windowId)", kind: .userCommand("Close window"), hostId: hostId)
    }

    public func killWindow(hostId: String, windowId: String) {
        send("kill-window -t \(windowId)", kind: .userCommand("Kill window"), hostId: hostId)
    }

    /// The `%session-renamed` this produces is what moves `reconnectTarget` onto the new name.
    public func renameSession(hostId: String, sessionId: String, newName: String) {
        let name = TmuxCommand.singleLine(newName)
        guard !name.isEmpty else { return }
        send("rename-session -t \(TmuxCommand.quote(sessionId)) \(TmuxCommand.quote(name))",
             kind: .userCommand("Rename session"), hostId: hostId)
    }

    public func killSession(hostId: String, sessionId: String) {
        send("kill-session -t \(TmuxCommand.quote(sessionId))",
             kind: .userCommand("Kill session"), hostId: hostId)
    }

    /// Creates a session on an already-connected host, without opening a second channel.
    public func newSession(hostId: String, name: String, startDirectory: String? = nil) {
        let name = TmuxCommand.singleLine(name)
        guard !name.isEmpty else { return }
        var command = "new-session -d -s \(TmuxCommand.quote(name))"
        if let startDirectory, !startDirectory.isEmpty {
            command += " -c \(TmuxCommand.quote(startDirectory))"
        }
        send(command, kind: .userCommand("New session"), hostId: hostId)
    }

    /// F4.11 — detaches every other client from the session we are attached to. Also the remedy
    /// for an orphaned client clamping window size (F4.17) when `window-size latest` is not enough.
    public func detachOtherClients(hostId: String) {
        guard let connection = connections[hostId] else { return }
        send("detach-client -a -s \(TmuxCommand.quote(connection.sessionTarget))", kind: .ignore, hostId: hostId, connection: connection)
    }

    /// Toggles zoom on a pane (`resize-pane -Z`), the app's equivalent of `prefix-z`.
    ///
    /// Nothing needs to be tracked here: tmux answers with a `%layout-change` carrying the new
    /// visible layout and flags, and the model takes the zoom from those. That is also why a zoom
    /// toggled from another client or from a plain `tmux` prefix key arrives the same way.
    public func toggleZoom(hostId: String, paneId: String) {
        send("resize-pane -Z -t \(paneId)", kind: .userCommand("Zoom pane"), hostId: hostId)
    }

    public func resizePane(hostId: String, paneId: String, cols: Int?, rows: Int?) {
        var command = "resize-pane -t \(paneId)"
        if let cols { command += " -x \(cols)" }
        if let rows { command += " -y \(rows)" }
        send(command, hostId: hostId)
    }

    // MARK: - Disconnection and recovery

    private func channelClosed(hostId: String, epoch: UUID, error: Error?) {
        if let follower = channel(of: hostId, epoch: epoch), case .follower(let sessionId) = follower.role {
            followerChannelClosed(hostId: hostId, sessionId: sessionId, connection: follower, error: error)
            return
        }
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
        let serverEnded = connection.serverEnded
        let attachedToSession = connection.attachedToSession
        // A recovery attach that died before tmux ever spoke is the remembered session failing to
        // resolve — `attach-session -t <name>` exits when there is no such session. The next attempt
        // takes whatever the server still has rather than retrying a name that will never come back.
        // It cannot fall back to creating one: that is precisely what F4.15 forbids.
        if connection.attachedByRememberedName, !connection.handshakeComplete {
            log("[\(hostId)] the remembered session did not resolve; next attempt will take any session")
            recoveryLostItsSession.insert(hostId)
        }
        teardown(hostId: hostId, connection: connection)
        guard !userInitiated else { return }

        log("[\(hostId)] channel closed: \(reason)")

        // The session ended rather than the link dying, so there is nothing to recover *to*. This is
        // the path Ctrl+D on the last pane takes, and `kill-session` on the attached session with it:
        // both end with `%exit`, both used to fall into the backoff below, and the reconnect there
        // runs `new-session -A -s <reconnectTarget>` — which cheerfully recreated the session the
        // user had just closed, with a fresh window in it (F4.9's spirit, violated by the recovery
        // path rather than by any close command).
        if serverEnded {
            // The name is dead. Keeping it would resurrect it on the next explicit connect too.
            reconnectTarget.removeValue(forKey: hostId)

            guard attachedToSession else {
                // We never landed anywhere: the server is gone and there is nothing to attach to.
                // Not a failure — the user closed the last session and this is what that looks like.
                log("[\(hostId)] session ended and the server has nothing left; disconnected")
                withHost(hostId) { host in
                    host.connectionState = .disconnected
                    // The sessions really are gone, unlike a dropped link where they are merely out
                    // of reach. Leaving them listed offers the user rows that do nothing.
                    host.sessions = []
                    host.activeSessionId = nil
                }
                broadcastState()
                return
            }

            // Our session ended, but the server may still hold others. One attempt to land on
            // whatever is left — and `attachAny`, never a name, so nothing is created. If the server
            // is gone that attempt comes straight back here with `attachedToSession` false and stops.
            log("[\(hostId)] session ended; attaching to whatever the server has left")
            reconnectAttempts[hostId] = 0
            Task { [weak self] in
                try? await self?.connectHost(hostId: hostId, mode: .attachAny)
            }
            return
        }

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

        // Held so a deliberate disconnect can cancel it. Fire-and-forget meant a host the user closed
        // on attempt 7 reconnected itself up to a minute later — possibly raising a password sheet for
        // a host they had just shut. `connectHost`'s idempotence guard is no help there, because
        // `.disconnected` is not active and the retry sails straight through it.
        reconnectTasks[hostId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            try? await self?.connectHost(hostId: hostId, isRecovery: true)
        }
    }

    /// Cancels a pending reconnect, if any. Called wherever the user has said what they want the
    /// connection to do, since a backoff still in flight would overrule it a minute later.
    private func cancelScheduledReconnect(hostId: String) {
        reconnectTasks.removeValue(forKey: hostId)?.cancel()
    }

    /// A follower channel ending is a much smaller event than the primary ending.
    ///
    /// It says one session stopped streaming — never that the host is unreachable, because the
    /// primary is the evidence for that and it is still here. So there is no backoff, no circuit
    /// breaker and no connection state to change: the session goes back to being a snapshot, and the
    /// next reconcile makes another client if it is still on screen. Retrying immediately in a loop
    /// is the one thing to avoid, since the usual reason a follower dies is that its session did.
    private func followerChannelClosed(
        hostId: String, sessionId: String, connection: Connection, error: Error?
    ) {
        let deliberate = connection.userInitiatedDisconnect
        if followerChannels[hostId]?[sessionId]?.epoch == connection.epoch {
            followerChannels[hostId]?.removeValue(forKey: sessionId)
        }
        teardown(hostId: hostId, connection: connection)
        updateLiveSessions(hostId: hostId)
        guard !deliberate else { return }

        log("[\(hostId)] the client for \(sessionId) ended: \(error.map(describe) ?? "closed")")
        // Whatever it was painting is now unowned; the primary picks those panes up if it can see
        // them, and a repaint is how it starts from a screen it agrees with.
        broadcastState()
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
        releasePanes(hostId: hostId, ownedBy: connection.epoch)
        // Nothing is going to answer anything now. A waiter left here would sit out its whole
        // timeout for an answer that cannot arrive.
        for (_, continuation) in connection.acknowledgements { continuation.resume() }
        connection.acknowledgements.removeAll()
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
        for subscribers in panes.values {
            for subscriber in subscribers.values { subscriber.continuation.finish() }
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
        // The comment above has always said "as well as any pending backoff", and until the retry was
        // held somewhere it could not actually do it: the scheduled attempt stayed in flight and fired
        // later on top of the connection this call is about to make.
        cancelScheduledReconnect(hostId: hostId)
        reconnectAttempts[hostId] = 0
        // Still a recovery, not a fresh connect: the user is asserting the host is reachable, not
        // asking for a new session to be made if theirs has gone (F4.15).
        try? await connectHost(hostId: hostId, isRecovery: true)
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
                cancelScheduledReconnect(hostId: hostId)
                reconnectAttempts[hostId] = 0
                try? await connectHost(hostId: hostId, isRecovery: true)
            case .disconnected, .connecting:
                break
            }
        }
    }
}
