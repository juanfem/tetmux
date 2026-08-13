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

    /// §4.6 — the passthrough channel of a host, when it has one. Never at the same time as a control
    /// channel: the two are alternatives, and a host that has fallen back has nothing to speak the
    /// protocol on.
    private var passthroughChannels: [String: PassthroughChannel] = [:]

    /// Which channel is painting each pane, by epoch, keyed `hostId` → `paneId`.
    ///
    /// A window can be linked into two sessions at once (F4.9's whole subject), and if both are on
    /// screen then two clients stream identical `%output` for its panes. Delivering both would
    /// double every byte the pane produces. The first channel to speak for a pane keeps it; the rest
    /// are dropped until it goes away, and the pane is repainted when ownership moves so the new
    /// owner's stream starts from a screen it agrees with.
    private var paneOwners: [String: [String: UUID]] = [:]
    private var stateContinuations: [UUID: AsyncStream<[HostState]>.Continuation] = [:]
    /// F4.29's round-trip readings, on a channel of their own. See `broadcastRoundTrips`.
    private var roundTripContinuations: [UUID: AsyncStream<[String: Double]>.Continuation] = [:]
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
    /// …and how long one may wait there before it is dropped whatever the queue depth is.
    ///
    /// The size cap alone bounds the *volume* and says nothing about the age, so a host that came
    /// back after ten minutes of outage still replayed whatever had survived — keystrokes typed at a
    /// shell that has long since moved on, delivered in one burst. Ten seconds is roughly the span
    /// over which what someone typed is still what they meant to type.
    private static let maxOutboxAge = Duration.seconds(10)
    /// How long a channel may take to get from spawned to handshaken before it is given up on.
    ///
    /// Generous, because it covers a real ssh login: a `ProxyCommand`, a slow DNS lookup, a large
    /// MOTD. What it rules out is the state that had no bound at all — a login shell blocked on
    /// "press any key", a wedged remote tmux — where the UI sat on "Connecting…" for the life of the
    /// process with no error, no retry, and nothing to distinguish it from a slow link.
    private static let handshakeTimeout = Duration.seconds(45)
    /// How long the pre-handshake stream must be quiet before an unclassified prompt is believed.
    private static let promptSettleDelay = Duration.milliseconds(700)
    /// Answers to prompts per channel, whatever they were classified as.
    private static let maxPromptAnswers = 3

    /// What "now" means for anything that ages out.
    ///
    /// `ContinuousClock`, never `Date`: this code lives on the sleep/wake boundary, which is the one
    /// place a wall clock jumps — and a queued keystroke whose age went negative or hours positive
    /// because the laptop was closed is exactly the cargo the age limit exists to drop. Injectable
    /// only so a test can advance it: waiting ten real seconds to assert a ten-second rule is a test
    /// nobody runs.
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

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
        var answeredSecret = false
        /// Everything written in answer to a prompt, secret or not. A ceiling on this bounds the
        /// damage when a prompt was classified wrongly — an unrecognised question could be a password
        /// prompt in a language nobody here reads.
        var answersSent = 0
        /// The prompt text we have already told the UI about, so the same bytes arriving in a later
        /// read do not raise it twice — and so a *different* question after it still can.
        var reportedPromptText: String?
        /// Holds an unclassified question until the stream stops moving. A read can land mid-line,
        /// which makes an ordinary banner look exactly like ssh waiting on a prompt.
        var promptSettleTask: Task<Void, Never>?

        var pendingKeys: [String: [UInt8]] = [:]
        /// When the last `send-keys` went out, so the coalescer can tell a keystroke that has
        /// something to wait for from one that does not. `nil` until the first, which is what makes
        /// the very first keystroke of a session take the immediate path like any other isolated one.
        var lastKeyFlush: ContinuousClock.Instant?
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

        /// This channel's own `client_tty`, learned at handshake. F4.17's reconciliation is "every
        /// control-mode client that is not one of ours", and this is the "ours".
        var clientTty: String?

        /// Whether this channel was a recovery attach to the remembered session name, so a death
        /// before the handshake can be read as "that session is gone" rather than "the host is down".
        var attachedByRememberedName = false

        /// Whether this attempt is part of a recovery chain rather than something the user just
        /// asked for. It decides whether *failing* is worth retrying: a link that dropped should come
        /// back on its own, and a host that never connected in the first place should say why and
        /// wait to be told again.
        var isRecoveryAttempt = false

        /// Whether finding nothing to attach to means "make one".
        ///
        /// Set only for a channel the *user* opened, and that is the whole of F4.15's distinction:
        /// automatic recovery must never create, because it cannot tell "the session is still there"
        /// from "the server restarted while you were away" and would hand back an empty session as
        /// though it were the user's work. Somebody clicking a host is not guessing — they are asking
        /// for a shell on it, and a click that lands on an empty server and then does nothing at all
        /// is the bug this exists to fix.
        var createsIfServerIsEmpty = false

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
        /// Debounce for re-reading `list-clients` after tmux says a client came, went, or moved.
        var clientRefreshTask: Task<Void, Never>?

        /// Callers waiting for tmux to answer a command they sent, by command id.
        ///
        /// Only for the handful of commands whose *effect* has to have landed before we do something
        /// irreversible — putting `window-size` back before hanging the channel up is the whole list.
        /// Everything else is fire-and-forget by design.
        var acknowledgements: [UUID: CheckedContinuation<Void, Never>] = [:]
        /// The same, for the commands whose *answer* somebody is waiting on rather than only their
        /// completion. `nil` is delivered for a refusal or a timeout. See `sendAndAwaitResult`.
        var results: [UUID: CheckedContinuation<[Data]?, Never>] = [:]

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
            clientRefreshTask?.cancel()
            handshakeWatchdog?.cancel()
            promptSettleTask?.cancel()
        }
    }

    private struct PendingCommand {
        let text: String
        let kind: Kind
        var lines: [Data] = []
        /// When this was handed to `send`. Only read while it is sitting in the pre-handshake outbox,
        /// where age is a reason to throw it away; a command that has been written is answered
        /// whenever tmux gets to it.
        var queuedAt: ContinuousClock.Instant?

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
            /// `reconcileStale` is F4.17's detach pass, which belongs to an *attach* and to nothing
            /// else. The same answer is now also read for the model — who else is attached, which the
            /// destructive confirmations report — and that runs on every topology refresh. Sharing
            /// one kind would have made every refresh a round of orphan-hunting: two live tetmuxen
            /// against one server already detach each other on attach, and doing it every time a
            /// window is renamed turns a known, bounded blast radius into a fight.
            case listClients(reconcileStale: Bool)
            /// This channel's own `client_tty`, so it can exclude itself from the list above.
            case clientTty
            /// `target` scopes the repaint to a single subscriber. The same pane can be on screen in
            /// two macOS windows, and the payload begins by clearing the screen *and* the scrollback —
            /// broadcasting a late joiner's repaint would wipe the history the other window is holding.
            case capturePane(paneId: String, target: UUID?)
            case roundTrip(sentAt: ContinuousClock.Instant)
            /// Like `.ignore`, but somebody is waiting to hear that tmux ran it. A refusal counts:
            /// the point is that the command has been *dealt with*, not that it succeeded.
            case acknowledged(UUID)
            /// Somebody is waiting for the block's *contents*, and a refusal is not an answer. The
            /// label is a `userCommand`'s, so a failure is still reported as one (§7) — unless there
            /// is none, which is for a question asked on the way to a command the user *did* ask for.
            /// That command reports its own refusal, and two banners for one act, the first of them
            /// naming an internal question, is worse than one.
            case awaitedResult(UUID, action: String?)
        }
    }

    private var reconnectAttempts: [String: Int] = [:]
    /// Pending backoff retries, so an explicit decision by the user can cancel one.
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    /// Hosts already told their tmux is older than 2.9 (R3.8). Once per host, not per channel.
    private var warnedAboutOldServer: Set<String> = []
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
        lastDiscovery.removeValue(forKey: hostId)
        cancelScheduledReconnect(hostId: hostId)
        hosts.removeValue(forKey: hostId)
        hostOrder.removeAll { $0 == hostId }
        broadcastState()
        // The narrow channel is keyed by host and is not derived from the snapshot above, so a
        // removed host's last reading would sit in it until that host's replacement produced one.
        broadcastRoundTrips()
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

    /// Round-trip times, keyed by host, on a channel that is deliberately not the state broadcast.
    ///
    /// F4.29's readout is the only consumer, and it is one line of text in a status bar — but the
    /// value it displays lives on `HostState`, so until this existed every probe answer was a real
    /// difference in the diffed model, and every ten seconds each host broadcast a snapshot that
    /// rebuilt a SwiftUI tree holding every pane on screen. **That was the whole of P6.6's miss.**
    /// Measured on 12 panes, two runs each: mean 0.45% and 0.71% of one core with spikes to 5.4%,
    /// against **0.04% mean and no sample above 0.8%** once the reading moved here.
    ///
    /// The probe is not the cost and was never a candidate: an arm that kept sending
    /// `display-message` every ten seconds and only stopped writing the answer to `HostState` was
    /// flat, with no spike at all. What costs is the broadcast, and after it the rebuild.
    public func roundTripStream() -> AsyncStream<[String: Double]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: [String: Double].self)
        roundTripContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeRoundTripContinuation(id) }
        }
        continuation.yield(currentRoundTrips())
        return stream
    }

    private func removeRoundTripContinuation(_ id: UUID) {
        roundTripContinuations.removeValue(forKey: id)
    }

    private func currentRoundTrips() -> [String: Double] {
        hosts.compactMapValues { $0.rttMilliseconds }
    }

    private func broadcastRoundTrips() {
        guard !roundTripContinuations.isEmpty else { return }
        let snapshot = currentRoundTrips()
        for continuation in roundTripContinuations.values {
            continuation.yield(snapshot)
        }
    }

    /// Whether two states of one host differ in anything but the round-trip reading.
    ///
    /// The reading is normalised onto the earlier value rather than both being cleared, so this stays
    /// one comparison of two whole states: a field added to `HostState` is covered by it from the day
    /// it is added, which an allowlist of compared fields would not be. `HostState`'s arrays are
    /// copy-on-write, so the copy is a retain rather than a walk of every pane.
    /// Internal rather than private so `RoundTripBroadcastTests` can hold it to the rule: the whole
    /// of P6.6's fix is which changes reach `broadcastState`, and a later field that quietly stopped
    /// being compared would cost a topology update rather than a status-bar reading.
    static func differsBeyondRoundTrip(_ before: HostState?, _ after: HostState?) -> Bool {
        guard var normalised = before, let after else { return (before != nil) != (after != nil) }
        normalised.rttMilliseconds = after.rttMilliseconds
        return normalised != after
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
        isRecovery: Bool = false,
        createIfEmpty: Bool = false
    ) async throws {
        guard var host = hosts[hostId] else { return }
        if let existing = connections[hostId] {
            if host.connectionState.isActive { return }
            teardown(hostId: hostId, connection: existing)
        }
        // A host in §4.6's fallback is `.degraded`, which is active — so the guard above would have
        // refused this call, and it must not: an explicit connect is the user asking to try control
        // mode again, which is the only way back from passthrough on a host whose tmux was upgraded.
        // The two channels cannot coexist, so the fallback goes first.
        if passthroughChannels[hostId] != nil { stopPassthrough(hostId: hostId) }
        host.passthrough = nil

        let sessionTarget = targetSession ?? reconnectTarget[hostId] ?? defaultSessionName(for: hostId)
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
            connection.createsIfServerIsEmpty = createIfEmpty
            connection.isRecoveryAttempt = isRecovery
            connections[hostId] = connection
        } catch {
            let reason = describe(error)
            host.connectionState = .failed(reason: reason)
            // R3.8's last row, on the local host: the executable simply is not there, which the
            // resolver says before anything is spawned. A plain shell is offered rather than started
            // — there is nothing to reattach to, so opening one is a decision for the user to make.
            if Self.describesMissingTmux(reason) {
                host.passthrough = PassthroughState(
                    reason: .tmuxUnavailable, phase: .offered, detail: reason
                )
            }
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

    // MARK: - Discovery (F4.4)

    /// When each host was last probed, so a burst of focus changes costs one subprocess.
    private var lastDiscovery: [String: ContinuousClock.Instant] = [:]
    /// Hosts with a probe in flight. A probe is an `await`, and a second one started underneath it
    /// would race to write the same field with an older answer.
    private var discoveryInFlight: Set<String> = []
    /// How long a probe's answer stands before another is worth spawning. F4.4 forbids a polling
    /// loop, so this is not an interval — nothing fires on its own — it is how much staleness a
    /// *deliberate* trigger is allowed to be satisfied by.
    private static let discoveryFreshness = Duration.seconds(30)

    /// Asks a host what sessions it has, without attaching to it (F4.4).
    ///
    /// The point is not the list; it is that the first click on a remote host currently *creates*
    /// one. `connectHost` falls back to `new-session -A -s <a generated name>`, so a host with the user's own
    /// `work` session sitting on it gets a second, empty session made on it before anyone has seen
    /// what was there. Discovery is what lets the choice come first.
    ///
    /// Silent in every failure mode, deliberately. It runs unbidden, so it may not raise a prompt
    /// (`BatchMode=yes`, no tty), may not change `connectionState`, and may not report an error: a
    /// host that cannot be reached simply has nothing to show, which is what it had before.
    public func discoverSessions(hostId: String, force: Bool = false) async {
        guard let host = hosts[hostId] else { return }
        // A live channel is already answering this question by notification, and its answer is
        // strictly better — it knows about windows. F4.4's "there is no polling loop" is exactly
        // this guard: discovery is for hosts nothing is listening to.
        guard connections[hostId] == nil else { return }
        // §4.6 — a passthrough host has a tmux we have already established we cannot drive, and no
        // way to act on what a list would say.
        guard host.passthrough == nil else { return }
        guard !discoveryInFlight.contains(hostId) else { return }
        if !force, let last = lastDiscovery[hostId], ContinuousClock.now - last < Self.discoveryFreshness {
            return
        }

        let invocation: (executable: String, arguments: [String])
        do {
            invocation = try self.invocation(for: host.config, mode: nil, flavour: .discovery)
        } catch {
            // No local tmux to ask with. Nothing to say about it here: the connect path says it
            // properly, with an offer attached (R3.8).
            return
        }

        discoveryInFlight.insert(hostId)
        defer { discoveryInFlight.remove(hostId) }
        log("[\(hostId)] discovery: \(invocation.executable) \(invocation.arguments.joined(separator: " "))")

        let result = await CommandProbe.run(
            executable: invocation.executable,
            arguments: invocation.arguments,
            environment: childEnvironment()
        )
        lastDiscovery[hostId] = .now

        // The host may have connected while ssh was thinking. Its channel's list is the better
        // answer and is already in `sessions`; writing a probe's over it would age backwards.
        guard connections[hostId] == nil, hosts[hostId] != nil else { return }

        guard let sessions = Self.parseDiscovery(result) else {
            log("[\(hostId)] discovery did not get an answer (status \(result.status))")
            return
        }
        log("[\(hostId)] discovery found \(sessions.count) session(s) without attaching")
        withHost(hostId) { $0.discoveredSessions = sessions }
        broadcastState()
    }

    /// A probe's output → the sessions on that host, or `nil` for "we did not find out".
    ///
    /// The distinction is the whole reason this is not a plain array. An empty list is a host that
    /// *answered* and has nothing on it — which is worth recording, because it is what supersedes the
    /// sessions a dropped channel left behind. `nil` is a question that never reached tmux: ssh
    /// refused, the host is unreachable, `BatchMode` declined to prompt. Recording that as "no
    /// sessions" would tell the user their work is gone because their laptop is on a train.
    ///
    /// The framing is what tells them apart. tmux answers inside a `%begin`/`%end` block; an
    /// unreachable host produces ssh's complaint and nothing else. `no server running` is the one
    /// unframed answer that is still an answer, and it is tmux's own words for "there is nothing
    /// here" — the state every host is in before its first session.
    static func parseDiscovery(_ result: CommandProbe.Result) -> [TmuxSession]? {
        var codec = ControlCodec()
        var lines: [String] = []
        var sawBlock = false
        for event in codec.feed(result.output) {
            switch event {
            case .begin: sawBlock = true
            case .commandResultLine(_, let line, _): lines.append(line)
            // A block that ends in `%error` is tmux refusing the command, not a list of nothing.
            case .error: return nil
            default: break
            }
        }

        if !sawBlock {
            let text = String(decoding: result.output, as: UTF8.self).lowercased()
            let noServer = text.contains("no server running")
                || text.contains("error connecting to")
            return noServer ? [] : nil
        }

        return lines
            .compactMap(parseSessionLine)
            .map { TmuxSession(id: $0.id, name: $0.name, isAttached: $0.isAttached) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Passthrough (§4.6, F4.27)

    /// A channel with no protocol on it.
    ///
    /// Everything that makes `Connection` complicated — the pending-command FIFO, the codec, the
    /// handshake, flow control, window sizing — exists because something on the far end is answering
    /// in a language. Here nothing is: the bytes are a terminal's, and the only jobs are to hand them
    /// to whoever is drawing and to write keystrokes back. That is why this is a separate type rather
    /// than a mode on the other one; a `Connection` with all of that switched off would be a class
    /// whose every field needs a "not in passthrough" caveat.
    private final class PassthroughChannel {
        let epoch = UUID()
        let transport: PtyTransport
        var readTask: Task<Void, Never>?
        var subscribers: [UUID: AsyncStream<Data>.Continuation] = [:]
        /// Whether the process is being stopped on purpose, so its ending is not reported as a fault.
        var userInitiatedStop = false
        /// Whether anything has arrived yet, which is what turns `.connecting` into `.running`.
        var hasSpoken = false

        /// Recent output, replayed to a surface that appears after the channel started.
        ///
        /// There is no `capture-pane` here — no protocol to ask it on — so a second window, or a view
        /// rebuilt for any reason, would otherwise be a black rectangle until the user pressed
        /// something. Replaying a mid-stream window of bytes can land inside an escape sequence and
        /// draw one line wrongly; a redraw (`prefix r`, or Ctrl-L in a shell) fixes that, and nothing
        /// fixes a blank surface that will never be sent anything again.
        var replay = Data()
        static let replayBytes = 128 * 1024

        init(transport: PtyTransport) {
            self.transport = transport
        }

        func record(_ data: Data) {
            replay.append(data)
            if replay.count > Self.replayBytes {
                replay.removeFirst(replay.count - Self.replayBytes)
            }
        }
    }

    /// A view's handle on a passthrough channel. Deliberately the same shape as `PaneSubscription`,
    /// since the consumer end is the same job.
    public struct PassthroughSubscription: Sendable {
        public let id: UUID
        public let stream: AsyncStream<Data>
    }

    /// Starts §4.6's fallback for a host: one tmux client, or a login shell where there is no tmux.
    ///
    /// Idempotent, and it takes the host's control channel down first — the two are alternatives, and
    /// leaving a control client attached while a second one draws the same session is two clients
    /// fighting over one terminal's worth of size.
    ///
    /// - Parameter reason: why control mode is not being used, which is also *which* fallback this
    ///   is — tmux without `-CC`, or a shell with no tmux behind it at all. Omitted, the host's
    ///   recorded reason stands, which is what the button on an offer sends: the offer is the thing
    ///   that knew why.
    public func startPassthrough(
        hostId: String,
        reason: PassthroughState.Reason? = nil,
        detail: String? = nil,
        sessionName: String? = nil
    ) {
        guard let host = hosts[hostId] else { return }
        guard passthroughChannels[hostId] == nil else { return }
        let state = PassthroughState(
            reason: reason ?? host.passthrough?.reason ?? .tmuxUnavailable,
            phase: .offered,
            detail: detail ?? host.passthrough?.detail ?? ""
        )

        if let existing = connections[hostId] {
            existing.userInitiatedDisconnect = true
            teardown(hostId: hostId, connection: existing)
        }

        let target = sessionName ?? reconnectTarget[hostId] ?? defaultSessionName(for: hostId)
        let transport = PtyTransport()
        let channel = PassthroughChannel(transport: transport)

        do {
            let (executable, arguments) = try invocation(
                for: host.config,
                // `new-session -A`: attach to the session if it is there and make it if it is not,
                // which is what a person opening a terminal on this host means. F4.15's "a reconnect
                // never creates" is about recovery, and this is not one — nothing here reconnects.
                mode: .createOrAttach(sessionName: target),
                flavour: state.usesTmux ? .passthroughTmux : .plainShell
            )
            log("[\(hostId)] passthrough: spawn \(executable) \(arguments.map { "\"\($0)\"" }.joined(separator: " "))")
            // 80x24 until the surface measures itself and says otherwise. Unlike control mode, where
            // tmux owns geometry (§3.3), the size here is the terminal's own — the view *is* the
            // client, so the pty's window size is the only thing there is to set.
            let stream = try transport.spawn(
                executable: executable,
                arguments: arguments,
                environment: childEnvironment(),
                initialSize: (cols: 80, rows: 24)
            )
            let epoch = channel.epoch
            channel.readTask = Task { [weak self] in
                do {
                    for try await data in stream {
                        await self?.ingestPassthrough(hostId: hostId, epoch: epoch, data: data)
                    }
                    await self?.passthroughClosed(hostId: hostId, epoch: epoch, error: nil)
                } catch {
                    await self?.passthroughClosed(hostId: hostId, epoch: epoch, error: error)
                }
            }
        } catch {
            // The whole state, not just the phase: the fallback path clears `passthrough` on its way
            // here, so a `?.phase =` would write into nothing and the failure would vanish — leaving
            // a host that had said it was falling back and then said nothing at all.
            log("[\(hostId)] passthrough could not start: \(describe(error))")
            withHost(hostId) { host in
                host.passthrough = PassthroughState(
                    reason: state.reason,
                    phase: .ended(reason: self.describe(error)),
                    detail: state.detail
                )
            }
            broadcastState()
            return
        }

        passthroughChannels[hostId] = channel
        withHost(hostId) { host in
            host.passthrough = PassthroughState(
                reason: state.reason, phase: .connecting, detail: state.detail
            )
            // There is no session tree behind a passthrough host and no way to build one, so anything
            // still listed from a control channel that has since been torn down is a row that cannot
            // do what it offers.
            host.sessions = []
            host.activeSessionId = nil
            host.liveSessionIds = []
            host.clients = []
        }
        broadcastState()
    }

    /// Ends the passthrough channel, leaving the mode itself offered.
    public func stopPassthrough(hostId: String) {
        guard let channel = passthroughChannels.removeValue(forKey: hostId) else { return }
        channel.userInitiatedStop = true
        finishPassthroughSubscribers(channel)
        channel.readTask?.cancel()
        channel.transport.terminate()
        withHost(hostId) { host in
            host.passthrough?.phase = .offered
        }
        broadcastState()
    }

    /// Bytes from the passthrough channel, for whoever is drawing it.
    ///
    /// Broadcast rather than owned by one subscriber: there is one client and it paints one screen,
    /// so two windows on the same passthrough host are two views of the same terminal — which is what
    /// they would be if this were tmux drawing to two attached clients of the same size.
    public func subscribeToPassthrough(hostId: String) -> PassthroughSubscription {
        let id = UUID()
        // Element-bounded, and that bound is the whole of the backpressure here. Below the
        // control-mode floor there is nothing to pause a pane *with* — `refresh-client -A` is tmux
        // 3.2 — so a runaway program is absorbed by dropping the oldest chunks and letting the next
        // redraw repair the screen. It is the one place in the app where output is discarded without
        // owing a repaint, because there is nothing that could issue one.
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self, bufferingPolicy: .bufferingNewest(2048)
        )
        guard let channel = passthroughChannels[hostId] else {
            continuation.finish()
            return PassthroughSubscription(id: id, stream: stream)
        }
        channel.subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removePassthroughSubscriber(hostId: hostId, id: id) }
        }
        // What is already on screen over there, so a surface made now is not blank until the user
        // types something.
        if !channel.replay.isEmpty {
            continuation.yield(channel.replay)
        }
        return PassthroughSubscription(id: id, stream: stream)
    }

    private func removePassthroughSubscriber(hostId: String, id: UUID) {
        passthroughChannels[hostId]?.subscribers.removeValue(forKey: id)
    }

    /// Keystrokes, as bytes, straight to the pty.
    ///
    /// Not through `send`: there is no command plane here and no pending-command FIFO to misalign.
    /// This is the same write `answerAuthenticationPrompt` makes, for the same reason — the far end
    /// is not a parser.
    public func sendPassthrough(hostId: String, bytes: [UInt8]) {
        guard let channel = passthroughChannels[hostId], !bytes.isEmpty else { return }
        let outcome = channel.transport.write(Data(bytes))
        // A partial write is survivable here, unlike on the command plane: nothing is framed, so the
        // rest of a keystroke sequence being lost costs a character rather than the channel. Worth
        // logging, since a character that vanished is otherwise a mystery.
        if outcome != .complete {
            log("[\(hostId)] passthrough write did not complete: \(outcome)")
        }
    }

    /// The terminal's size, which in this mode is genuinely the view's to decide.
    ///
    /// The deliberate exception to §3.3. There, tmux owns geometry because tmux is laying panes out
    /// and telling us where they went; here the surface *is* the tmux client's terminal, so its size
    /// is what `TIOCSWINSZ` says and tmux is downstream of it — exactly as it would be in a terminal
    /// emulator. Asking tmux first would be asking it about a number it is waiting for from us.
    public func resizePassthrough(hostId: String, cols: Int, rows: Int) {
        guard let channel = passthroughChannels[hostId], cols > 0, rows > 0 else { return }
        channel.transport.resize(cols: UInt16(clamping: cols), rows: UInt16(clamping: rows))
    }

    private func ingestPassthrough(hostId: String, epoch: UUID, data: Data) {
        guard let channel = passthroughChannels[hostId], channel.epoch == epoch else { return }
        channel.record(data)
        for continuation in channel.subscribers.values {
            continuation.yield(data)
        }
        guard !channel.hasSpoken else { return }
        channel.hasSpoken = true
        withHost(hostId) { host in
            host.passthrough?.phase = .running
        }
        broadcastState()
    }

    private func passthroughClosed(hostId: String, epoch: UUID, error: Error?) {
        guard let channel = passthroughChannels[hostId], channel.epoch == epoch else { return }
        passthroughChannels.removeValue(forKey: hostId)
        finishPassthroughSubscribers(channel)
        guard !channel.userInitiatedStop else { return }

        let reason = error.map(describe) ?? "The session ended."
        log("[\(hostId)] passthrough ended: \(reason)")
        withHost(hostId) { host in
            host.passthrough?.phase = .ended(reason: reason)
        }
        broadcastState()
    }

    private func finishPassthroughSubscribers(_ channel: PassthroughChannel) {
        for continuation in channel.subscribers.values { continuation.finish() }
        channel.subscribers.removeAll()
    }

    /// R3.8's `< 2.4` row: control mode answered, and answered that it is not one we can drive.
    ///
    /// The channel goes rather than continuing in a reduced form. That was the shape of the bug this
    /// replaces — the host was marked `.degraded` and then went straight on to apply the window-size,
    /// flow-control and subscription policies to a server that has none of them — and it is also the
    /// honest reading of the requirement: passthrough is a different way of driving the host, not a
    /// control-mode channel with some features off.
    private func beginPassthroughFallback(
        hostId: String, connection: Connection, version: TmuxVersion
    ) {
        let detail = "tmux \(version.raw) predates control mode as this client speaks it (2.4)."
        log("[\(hostId)] \(detail) falling back to passthrough")
        withHost(hostId) { host in
            host.connectionState = .degraded(reason: detail)
        }
        // Deliberate, so the teardown is not read as a dropped link and put on the backoff.
        connection.userInitiatedDisconnect = true
        teardown(hostId: hostId, connection: connection)
        startPassthrough(
            hostId: hostId,
            reason: .belowControlModeFloor(version: version.raw),
            detail: detail
        )
    }

    /// R3.8's last row — whether what killed the channel was the absence of tmux, which is the one
    /// failure with something better to offer than a retry.
    ///
    /// Matched against the message rather than against an exit code, because the exit code is 127 for
    /// every failed exec and the sentence is ours: `remoteCommand` runs `command -v tmux` precisely so
    /// that this case says what it is instead of arriving as a generic failure.
    static func describesMissingTmux(_ reason: String) -> Bool {
        let lowered = reason.lowercased()
        return lowered.contains("tmux not found")
            || lowered.contains("tmux: command not found")
            || lowered.contains("executable not found on path: tmux")
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
        // §4.6 — a host being driven by passthrough has no `Connection` either, and "disconnect" has
        // to mean the same thing there: stop the process this app started on the far side.
        if passthroughChannels[hostId] != nil {
            stopPassthrough(hostId: hostId)
            withHost(hostId) { $0.passthrough = nil }
        }
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
            for hostId in Set(connections.keys).union(followerChannels.keys)
                .union(passthroughChannels.keys) {
                group.addTask { await self.disconnectHost(hostId: hostId) }
            }
        }
    }

    /// The name for a session this connection is about to make, by the one rule (`SessionNaming`).
    ///
    /// It was `"tetmux-main"`, from a function that took a `HostConfig` and ignored it — a per-host
    /// default that was never per-host. That constant is why the F4.15 placeholder could offer
    /// "Recreate “tetmux-main”" beside a second button that made `tetmux-main` as well.
    ///
    /// Keyed off the sessions this host is known to have, which on a first connect is none — so a
    /// host being reached for the first time gets `tetmux_1`, and a server that already has one
    /// keeps counting. It cannot consult a server it has not spoken to yet, and does not need to:
    /// `new-session -A` attaches to that name if it happens to exist.
    private func defaultSessionName(for hostId: String) -> String {
        SessionNaming.nextName(taken: Set(hosts[hostId]?.sessions.map(\.name) ?? []))
    }

    /// What a channel is being opened to *talk to* — a parser or a person.
    ///
    /// The three differ only in which process is spawned, which is the whole of §2.1's claim about
    /// this layer. Passthrough (§4.6) is not a second transport, a second reader, or a remote branch:
    /// it is `tmux` without `-CC`, and the plain shell is the same sentence with no tmux in it.
    enum SpawnFlavour {
        case controlMode
        /// §4.6 — one tmux client drawing itself, for a server below the control-mode floor.
        case passthroughTmux
        /// R3.8's last row — a login shell, for a host with no tmux at all.
        case plainShell
        /// F4.4 — one question and out. The only flavour that is not a channel at all, and the only
        /// one that never gets a tty.
        case discovery
    }

    /// Non-private so the *assembled* invocation can be asserted, which is the gap that let a real
    /// bug through: `sshArguments(purpose: .discovery)` was tested and correct, and the one line that
    /// passes `.discovery` to it was missing — so every probe ran with a tty, no `BatchMode`, and a
    /// persistent master. Testing the builder in isolation cannot catch an argument nobody passes.
    func invocation(
        for config: HostConfig,
        mode: TmuxCommand.AttachMode?,
        flavour: SpawnFlavour = .controlMode
    ) throws -> (executable: String, arguments: [String]) {
        // Every flavour but discovery is a channel, and a channel is always attaching to something.
        let mode = mode ?? .attachAny

        if config.isLocal {
            if flavour == .plainShell {
                return TmuxCommand.localShellInvocation(
                    shell: ProcessInfo.processInfo.environment["SHELL"]
                )
            }
            guard let tmux = PtyTransport.resolveTmux(path: searchPath()) else {
                throw PtyError.executableNotFound("tmux")
            }
            switch flavour {
            case .controlMode:
                return (tmux, TmuxCommand.localArguments(
                    mode: mode, startDirectory: config.startDirectory
                ))
            case .passthroughTmux:
                return (tmux, TmuxCommand.localPassthroughArguments(
                    mode: mode, startDirectory: config.startDirectory
                ))
            case .discovery: return (tmux, TmuxCommand.discoveryArguments())
            case .plainShell: break  // handled above
            }
        }

        let remoteCommand: String
        switch flavour {
        case .plainShell: remoteCommand = TmuxCommand.remoteShellCommand
        case .discovery: remoteCommand = TmuxCommand.remoteDiscoveryCommand()
        case .controlMode, .passthroughTmux:
            remoteCommand = TmuxCommand.remoteCommand(
                mode: mode, controlMode: flavour == .controlMode,
                // F4.11 — the session this channel may create is a session like any other, and the
                // host's start directory is where the user said its sessions begin. It was left out
                // of this path on the reasoning that a host being reached for the first time is not
                // being given a working directory; what that produced was the *first* session on a
                // host being the one that ignored the setting, and locally starting in `/`.
                startDirectory: config.startDirectory
            )
        }

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
            // A probe forwards nothing. Forwards belong to the connection the user asked for, and
            // with `ControlMaster` they belong to the *master* — so a background probe setting them
            // up would bind the user's ports on a connection they cannot see or close.
            forwards: flavour == .discovery ? [] : config.forwards,
            expectsPasswordPrompt: config.usesPassword,
            extraArguments: TmuxCommand.splitArguments(config.extraSshArguments),
            forwardsX11: flavour == .discovery ? false : config.forwardsX11,
            // The line this was missing. Everything above about a probe not taking a tty and not
            // prompting is decided by this argument, and without it the whole branch was unreachable
            // — the probe ran as a channel would: `-tt`, no `BatchMode`, and a persistent master.
            purpose: flavour == .discovery ? .discovery : .channel
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
        //
        // F4.29's round-trip reading is excluded from that decision and published separately: it
        // changes every ten seconds per host, by definition, and a status-bar readout is not worth a
        // tree rebuild. It is yielded whenever it moves — including alongside a real state change,
        // so the narrow channel is never the stale one (P6.6).
        let after = hosts[hostId]
        if before?.rttMilliseconds != after?.rttMilliseconds {
            broadcastRoundTrips()
        }
        if Self.differsBeyondRoundTrip(before, after) {
            broadcastState()
        }
    }

    private func handle(_ event: ControlEvent, hostId: String, connection: Connection) {
        switch event {
        case .begin(_, let number, let flags):
            log("[\(hostId)] %begin \(number) flags=\(flags) pending=\(connection.pending.count)")
            if let last = connection.lastCommandNumber, number <= last {
                // Server-wide numbers only ever go up. A repeat means we are reading something that
                // is not the frame we think it is.
                log("[\(hostId)] protocol desync: %begin \(number) after \(last)")
            }
            connection.lastCommandNumber = number
            connection.currentNumber = number
            if !ControlCodec.blockAnswersOurCommand(flags: flags) {
                // Not ours to answer: tmux's own block on attach, and every command a keystroke
                // dispatches through a pane's mode table. Framed exactly like a response and matched
                // by *order*, so taking one off the FIFO would hand the next real answer to the wrong
                // command — permanently. Read rather than assumed, because the number cannot say and
                // the flags can. See `ControlCodec.blockAnswersOurCommand`.
                connection.current = PendingCommand(text: "", kind: .ignore)
            } else if connection.pending.isEmpty {
                // A block that says it answers one of ours, when we have nothing outstanding. The
                // FIFO has slipped and every subsequent response will be attributed to the wrong
                // command, so it is worth a line in the log even though there is nothing to do about
                // it here.
                log("[\(hostId)] protocol desync: %begin \(number) with no command pending")
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
            case .awaitedResult(let id, let action):
                // A refusal is *not* an answer here — the caller wanted the contents — so it is both
                // resumed with nothing and reported, because the user asked for this one.
                resumeResult(id, with: nil, connection: connection)
                guard let action else { break }
                withHost(hostId) { host in
                    host.lastCommandFailure = CommandFailure(
                        action: action,
                        message: message.isEmpty ? "tmux rejected the command" : message
                    )
                }
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
            var outcome = TmuxWindow.LayoutApplyResult.unchanged
            withHost(hostId) { host in
                Self.mutateWindow(&host, windowId: windowId) {
                    outcome = $0.apply(layoutString: layout, visibleLayout: visibleLayout, flags: flags)
                }
            }
            // The window is still rendering the layout it had, so nothing on screen went blank — but
            // it is now a grid tmux has moved on from, and no later notification repeats this one.
            if case .rejected(let reason) = outcome {
                log("[\(hostId)] rejected %layout-change for \(windowId): \(reason) — \(layout)")
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
                // F4.15 — landing on a session is what spends the "session gone" offer, and this is
                // the event that means it. Deliberately *not* the handshake: attaching to a server
                // that has nothing left is a **completed** handshake answering `no sessions` and
                // exiting, so clearing it there wiped the name on the one path that needs it — the
                // single `attachAny` the recovery makes after a session ends.
                withHost(hostId) { $0.endedSessionName = nil }
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

        case .subscriptionChanged(let name, _, _, _, let paneId, let value):
            // Ours or nobody's: another control client on the same server can hold subscriptions of
            // its own, and their names are the only thing separating them.
            guard name == TmuxCommand.paneCommandSubscription else { break }
            withHost(hostId) { host in
                Self.mutatePane(&host, paneId: paneId) { $0.command = value }
            }

        case .paneModeChanged(let paneId):
            // A mode is a per-client screen overlay and control mode is not streamed one, so the
            // bytes for what is now on that pane never arrive: entering copy mode from another client
            // (or from a `prefix [` that reached tmux) leaves the pane showing the screen from before
            // and no notification ever corrects it. A repaint is the only way to see the mode at all,
            // and leaving it is the pane looking frozen with nothing wrong.
            log("[\(hostId)] pane mode changed on \(paneId); repainting")
            requestRepaintAfterLoss(hostId: hostId, paneId: paneId)
            // …and the notification says only that *something* changed — not which mode, and not
            // whether it was entered or left (verified on 3.7b: the same bare line for both). So the
            // answer has to be asked for, and `list-panes` is where `#{pane_mode}` lives.
            schedulePaneRefresh(hostId: hostId)

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

        // Somebody else attached, detached, or switched session. Only the client list changed, so
        // this is not a topology refresh — but it is the thing a kill confirmation reports, and
        // nothing else would tell us. Verified on 3.7b: a plain `tmux attach` from another terminal
        // emits `%client-session-changed <tty> $id <name>` and killing it emits `%client-detached
        // <tty>`. `%client-detached` needs tmux ≥ 3.2 (3.0 emits nothing when a client leaves), which
        // is why the topology refresh re-reads the list as well rather than trusting these alone.
        case .clientDetached, .clientSessionChanged:
            scheduleClientRefresh(hostId: hostId)

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
        guard let kind = SshPromptDetector.pendingPrompt(in: connection.preHandshakeLog) else { return }
        // A secret already went down this channel. Never a second one: a rejected password answered
        // again is how accounts get locked out, and the retry the user really wants is a fresh
        // connection with a fresh prompt.
        if kind == .password || kind == .keyPassphrase, connection.answeredSecret { return }
        guard let text = SshPromptDetector.promptText(in: connection.preHandshakeLog) else { return }
        guard connection.reportedPromptText != text else { return }

        // An unclassifiable question is believed only once the stream has stopped moving. The
        // classified shapes are distinctive enough to act on at once; "a line ending in a colon" is
        // not, because a read can land mid-line and make an ordinary banner look like it is waiting.
        if kind == .question {
            scheduleQuestionConfirmation(hostId: hostId, connection: connection)
            return
        }
        publish(prompt: kind, text: text, hostId: hostId, connection: connection)
    }

    /// Waits for the stream to settle before believing an unclassified prompt is one.
    private func scheduleQuestionConfirmation(hostId: String, connection: Connection) {
        connection.promptSettleTask?.cancel()
        let length = connection.preHandshakeLog.count
        let epoch = connection.epoch
        connection.promptSettleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.promptSettleDelay)
            guard !Task.isCancelled else { return }
            await self?.confirmPendingQuestion(hostId: hostId, epoch: epoch, unchangedLength: length)
        }
    }

    private func confirmPendingQuestion(hostId: String, epoch: UUID, unchangedLength: Int) {
        guard let connection = channel(of: hostId, epoch: epoch), !connection.handshakeComplete else { return }
        // Something else arrived; whatever that line was, it was not ssh stopping on it.
        guard connection.preHandshakeLog.count == unchangedLength else { return }
        guard SshPromptDetector.pendingPrompt(in: connection.preHandshakeLog) == .question,
              let text = SshPromptDetector.promptText(in: connection.preHandshakeLog),
              connection.reportedPromptText != text else { return }
        publish(prompt: .question, text: text, hostId: hostId, connection: connection)
    }

    private func publish(
        prompt kind: AuthenticationPrompt.Kind,
        text: String,
        hostId: String,
        connection: Connection
    ) {
        connection.reportedPromptText = text
        log("[\(hostId)] ssh has stopped on a \(kind) prompt")
        // The lines above the question, for the one kind where the question alone means nothing.
        let context = kind == .hostKey
            ? SshPromptDetector.promptContext(in: connection.preHandshakeLog)
            : nil
        withHost(hostId) { host in
            host.authenticationPrompt = AuthenticationPrompt(kind: kind, text: text, context: context)
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
        guard let connection = connections[hostId] else { return }
        let kind = hosts[hostId]?.authenticationPrompt?.kind

        // One secret per channel, and never a second — that rule is what keeps a rejected password
        // from being resubmitted into a lockout. It applies to what was *classified* as a secret; a
        // host-key answer is not one, and a login that needs "yes" and then a password would
        // otherwise be unable to give both.
        if kind == .password || kind == .keyPassphrase {
            guard !connection.answeredSecret else { return }
            connection.answeredSecret = true
        }
        // …and a hard ceiling regardless of classification, because an unclassified question could
        // be a password prompt in a language nobody here reads.
        guard connection.answersSent < Self.maxPromptAnswers else {
            log("[\(hostId)] refusing a further answer: \(Self.maxPromptAnswers) already sent on this channel")
            return
        }
        connection.answersSent += 1
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
            // Control mode is speaking, so whatever fallback this host was offered or was in is no
            // longer the answer to anything. Left set, it would keep the UI drawing a passthrough
            // surface over a host with a live session tree behind it.
            withHost(hostId) { $0.passthrough = nil }
            // F4.4's probe is superseded by the channel about to answer `list-sessions`, and holding
            // it would leave a snapshot from before the connection to resurface the next time the
            // link drops — older than the sessions the channel itself left behind.
            withHost(hostId) { $0.discoveredSessions = nil }
            lastDiscovery.removeValue(forKey: hostId)
            // Whatever ssh asked for, it got: the protocol is speaking.
            withHost(hostId) { $0.authenticationPrompt = nil }
            withHost(hostId) { host in
                host.connectionState = .connected
            }
            reconnectAttempts[hostId] = 0
        }

        // Flush anything the UI queued while we were still connecting — except what has gone stale.
        //
        // The size cap bounds how *much* waits here and says nothing about how long. A host that
        // comes back after an outage replays the survivors in one burst, and the dangerous cargo is
        // keystrokes: they were typed at a shell that has moved on, or at a prompt that is no longer
        // the prompt, and a burst of them is executed rather than read. Age alone disqualifies, so
        // there is nothing to gain by telling the kinds apart.
        let deadline = now() - Self.maxOutboxAge
        let queued = connection.outbox.filter { ($0.queuedAt ?? deadline) >= deadline }
        let stale = connection.outbox.count - queued.count
        if stale > 0 {
            log("[\(hostId)] dropped \(stale) command(s) that waited more than \(Self.maxOutboxAge) for the handshake")
        }
        connection.outbox.removeAll()

        send("display-message -p '#{version}'", kind: .version, hostId: hostId, connection: connection)
        // Before `list-clients`, so this channel knows which of the listed clients is itself by the
        // time the answer arrives — responses come back in order.
        send(TmuxCommand.clientTtyQuery, kind: .clientTty, hostId: hostId, connection: connection)
        // The `window-size` policy waits for that version: which of the two sizing models is available
        // depends on it, and choosing wrongly either collapses every pane toward 80x24 or leaves a
        // torn-off window unable to size itself. See `applyWindowSizePolicy`.
        send("list-clients -F \(TmuxCommand.quote(TmuxCommand.clientsFormat))",
             kind: .listClients(reconcileStale: true), hostId: hostId, connection: connection)
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
            // R3.8 — below the floor there is no point applying any of the policies below: they are
            // all commands this server does not have. §4.6 takes over, and this channel ends here.
            if !version.supportsControlMode {
                beginPassthroughFallback(hostId: hostId, connection: connection, version: version)
                return
            }
            // The size we asked for before knowing the version may have used the wrong syntax.
            connection.lastSentSize = nil
            applyWindowSizePolicy(hostId: hostId, connection: connection)
            applyFlowControlPolicy(hostId: hostId, connection: connection)
            applySubscriptionPolicy(hostId: hostId, connection: connection)
            warnIfServerIsOld(hostId: hostId, version: version)
            flushResize(hostId: hostId)

        case .listSessions:
            applySessions(text(), hostId: hostId)

        case .listWindows:
            applyWindows(text(), hostId: hostId)

        case .listPanes:
            applyPanes(text(), hostId: hostId)

        case .clientTty:
            connection.clientTty = text().first?.trimmingCharacters(in: .whitespaces)

        case .listClients(let reconcileStale):
            let clients = applyClients(text(), hostId: hostId)
            if reconcileStale { reconcileStaleClients(clients, hostId: hostId) }

        case .capturePane(let paneId, let target):
            deliver(Self.repaintPayload(from: command.lines), hostId: hostId, paneId: paneId, target: target)

        case .roundTrip(let sentAt):
            let elapsed = ContinuousClock.now - sentAt
            let milliseconds = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15
            withHost(hostId) { $0.rttMilliseconds = milliseconds }

        case .acknowledged(let id):
            resumeAcknowledgement(id, connection: connection)

        case .awaitedResult(let id, _):
            resumeResult(id, with: command.lines, connection: connection)
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
        guard let connection = connections[hostId], connection.handshakeComplete else {
            log("[\(hostId)] pane refresh skipped: no handshaken channel")
            return
        }
        // Never narrows a full refresh that is already pending.
        guard connection.topologyRefreshTask == nil else {
            log("[\(hostId)] pane refresh skipped: a refresh is already pending")
            return
        }
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
        // Who else is attached, without the detach pass — see `Kind.listClients`. A session gaining
        // or losing a client is not a topology change and produces no notification below tmux 3.2, so
        // without this the list would only ever be as fresh as the last attach.
        send("list-clients -F \(TmuxCommand.quote(TmuxCommand.clientsFormat))",
             kind: .listClients(reconcileStale: false), hostId: hostId, connection: connection)
    }

    /// Re-reads the client list alone.
    ///
    /// Public because a destructive confirmation is the one moment this has to be *current* rather
    /// than merely recent: it is about to tell somebody they are alone in a session. The sheet reads
    /// the model live, so an answer arriving a round trip after it opened corrects what it says.
    public func refreshClients(hostId: String) {
        guard let connection = connections[hostId], connection.handshakeComplete else { return }
        send("list-clients -F \(TmuxCommand.quote(TmuxCommand.clientsFormat))",
             kind: .listClients(reconcileStale: false), hostId: hostId, connection: connection)
    }

    /// Debounced client refresh for `%client-session-changed` and `%client-detached`.
    ///
    /// Its own task slot rather than the topology one, for the reason the pane refresh has its own:
    /// these fire on their own schedule — every client attaching, detaching, or switching session —
    /// and folding them into the topology debounce would let one narrow the other.
    private func scheduleClientRefresh(hostId: String) {
        guard let connection = connections[hostId], connection.handshakeComplete else { return }
        guard connection.clientRefreshTask == nil else { return }
        connection.clientRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            await self?.runScheduledClientRefresh(hostId: hostId)
        }
    }

    private func runScheduledClientRefresh(hostId: String) {
        connections[hostId]?.clientRefreshTask = nil
        refreshClients(hostId: hostId)
    }

    /// One `list-sessions` line, in one place.
    ///
    /// Shared by the channel's parse and F4.4's probe, which read the *same* format string — two
    /// readings of `sessionsFormat` is two chances for one of them to drift from it.
    static func parseSessionLine(_ line: String) -> (id: String, isAttached: Bool, name: String)? {
        let fields = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return nil }
        return (String(fields[0]), fields[1] == "1", String(fields[2]))
    }

    private func applySessions(_ lines: [String], hostId: String) {
        withHost(hostId) { host in
            var seen: Set<String> = []
            for line in lines {
                guard let (id, attached, name) = Self.parseSessionLine(line) else { continue }
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
        var rejected: [(windowId: String, reason: String, layout: String)] = []
        withHost(hostId) { host in
            var seenBySession: [String: Set<String>] = [:]
            /// The order `list-windows` reported, which is tmux's own window order. Kept separately
            /// from `seenBySession` because a set cannot answer the question this exists for.
            var orderBySession: [String: [String]] = [:]
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
                orderBySession[sessionId, default: []].append(windowId)

                guard let sessionIndex = host.sessions.firstIndex(where: { $0.id == sessionId }) else { continue }
                if let windowIndex = host.sessions[sessionIndex].windows.firstIndex(where: { $0.id == windowId }) {
                    host.sessions[sessionIndex].windows[windowIndex].name = name
                    host.sessions[sessionIndex].windows[windowIndex].isActive = isActive
                    host.sessions[sessionIndex].windows[windowIndex].hasActivity = hasActivity
                    host.sessions[sessionIndex].windows[windowIndex].hasExplicitName = hasExplicitName
                    let outcome = host.sessions[sessionIndex].windows[windowIndex].apply(
                        layoutString: layout, visibleLayout: visibleLayout, flags: flags
                    )
                    if case .rejected(let reason) = outcome {
                        rejected.append((windowId, reason, layout))
                    }
                } else {
                    var window = TmuxWindow(
                        id: windowId, name: name, isActive: isActive, hasActivity: hasActivity,
                        hasExplicitName: hasExplicitName
                    )
                    // A window seen for the first time has no previous layout to fall back on, so a
                    // rejection here really does leave it with nothing to render — worth saying.
                    if case .rejected(let reason) = window.apply(
                        layoutString: layout, visibleLayout: visibleLayout, flags: flags
                    ) {
                        rejected.append((windowId, reason, layout))
                    }
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

                // Put them in the order tmux just reported. Windows are updated in place and new
                // ones are appended above, so without this the model kept whatever order it first
                // learned them in — and a window moved by `move-window`, by another client, or by
                // `swap-window` changed nothing visible at all. It is `list-windows`' order, which is
                // window index order, which is the order the tab strip and the tree are supposed to
                // be showing.
                if let order = orderBySession[sessionId] {
                    var position: [String: Int] = [:]
                    for (index, id) in order.enumerated() where position[id] == nil { position[id] = index }
                    host.sessions[sessionIndex].windows.sort {
                        (position[$0.id] ?? .max) < (position[$1.id] ?? .max)
                    }
                }

                if let active = host.sessions[sessionIndex].activeWindowId,
                   !seen.contains(active) {
                    host.sessions[sessionIndex].activeWindowId = host.sessions[sessionIndex].windows.first?.id
                }
                if host.sessions[sessionIndex].activeWindowId == nil {
                    host.sessions[sessionIndex].activeWindowId = host.sessions[sessionIndex].windows.first?.id
                }
            }
        }
        for entry in rejected {
            log("[\(hostId)] rejected list-windows layout for \(entry.windowId): \(entry.reason) — \(entry.layout)")
        }
    }

    private func applyPanes(_ lines: [String], hostId: String) {
        withHost(hostId) { host in
            for line in lines {
                let fields = line.split(separator: "|", maxSplits: 7, omittingEmptySubsequences: false)
                guard fields.count >= 8 else { continue }
                let windowId = String(fields[0])
                let paneId = String(fields[1])
                let isActive = fields[2] == "1"
                let cols = Int(fields[3]) ?? 80
                let rows = Int(fields[4]) ?? 24
                let command = String(fields[5])
                let mode = String(fields[6])
                let path = String(fields[7])

                Self.mutateWindow(&host, windowId: windowId) { window in
                    if let index = window.panes.firstIndex(where: { $0.id == paneId }) {
                        window.panes[index].isActive = isActive
                        window.panes[index].cols = cols
                        window.panes[index].rows = rows
                        window.panes[index].command = command
                        window.panes[index].currentPath = path
                        window.panes[index].mode = mode
                    } else {
                        window.panes.append(TmuxPane(
                            id: paneId, command: command, currentPath: path,
                            isActive: isActive, cols: cols, rows: rows, mode: mode
                        ))
                    }
                    if isActive { window.activePaneId = paneId }
                }
            }
        }
        // `list-panes -a` is the authoritative pane census, so this is the one moment the service can
        // tell a pane that is gone from one it has simply not heard about yet.
        pruneVanishedPanes(hostId: hostId)
        // And the one moment it can tell that a pane still very much there has changed session under
        // the client that was painting it.
        releaseStrandedPanes(hostId: hostId)
    }

    // MARK: - Model helpers

    private func withHost(_ hostId: String, _ body: (inout HostState) -> Void) {
        guard var host = hosts[hostId] else { return }
        body(&host)
        hosts[hostId] = host
    }

    /// Finds a window anywhere in the host, creating it in the active session if it is new.
    /// Applies `body` to a pane wherever it lives, and does nothing if it is not known yet.
    ///
    /// Unlike `mutateWindow` there is no create-if-missing branch: a pane arrives with a layout, and
    /// inventing one from a subscription would put a pane in the model with no place in any tree.
    private static func mutatePane(_ host: inout HostState, paneId: String, _ body: (inout TmuxPane) -> Void) {
        for sessionIndex in host.sessions.indices {
            for windowIndex in host.sessions[sessionIndex].windows.indices {
                if let paneIndex = host.sessions[sessionIndex].windows[windowIndex].panes
                    .firstIndex(where: { $0.id == paneId }) {
                    body(&host.sessions[sessionIndex].windows[windowIndex].panes[paneIndex])
                    return
                }
            }
        }
    }

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
            connection.outbox.append(PendingCommand(text: text, kind: kind, queuedAt: now()))
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
            if case .awaitedResult(let id, _) = kind { resumeResult(id, with: nil, connection: connection) }

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

    /// Sends `text` and returns the block tmux answered with, or `nil` if it refused or never
    /// answered.
    ///
    /// The same shape as `sendAndAwait` and for the same reasons — bounded, and resumed from every
    /// path that could strand it — but it hands back the body rather than only the fact of an answer.
    /// Two callers: `show-buffer`, whose *contents* are the whole point and which no notification
    /// carries, and the pane-directory question a spawn asks before it can name one.
    ///
    /// `nil` for a refusal rather than an empty array, because an empty buffer and a missing one are
    /// different answers and a caller about to write the Mac's pasteboard must not confuse them.
    /// The waiter's id is minted here and put into the kind here, deliberately: they are two halves
    /// of one correlation, and a caller that built the kind itself could hand over one that names a
    /// different waiter — which resolves as a command that never answers.
    ///
    /// A nil `action` is a question of our own rather than something the user asked for; see the kind.
    private func sendAndAwaitResult(
        _ text: String,
        action: String?,
        hostId: String,
        connection: Connection,
        timeout: Duration = .seconds(5)
    ) async -> [Data]? {
        let id = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<[Data]?, Never>) in
            connection.results[id] = continuation
            send(text, kind: .awaitedResult(id, action: action), hostId: hostId, connection: connection)
            Task { [weak connection] in
                try? await Task.sleep(for: timeout)
                guard let connection else { return }
                self.resumeResult(id, with: nil, connection: connection)
            }
        }
    }

    private func resumeResult(_ id: UUID, with lines: [Data]?, connection: Connection) {
        connection.results.removeValue(forKey: id)?.resume(returning: lines)
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
            releasePane(hostId: hostId, paneId: paneId)
        }
    }

    /// One pane's claim, given up. The repaint is the same argument `releasePanes` makes for a whole
    /// channel's worth: whoever streams it next is mid-stream on a screen it never drew.
    private func releasePane(hostId: String, paneId: String) {
        paneOwners[hostId]?.removeValue(forKey: paneId)
        connections[hostId]?.repaintedPanes.remove(paneId)
        guard outputSubscribers[hostId]?[paneId]?.isEmpty == false else { return }
        requestRepaint(hostId: hostId, paneId: paneId)
    }

    /// Gives up a claim held by a channel that can no longer see the pane.
    ///
    /// A pane is painted from exactly one channel's bytes — whichever claimed it first — and every
    /// other copy is dropped, which is what keeps a window linked into two displayed sessions from
    /// being painted twice. A claim was only ever released when its channel died or `switch-client`
    /// moved it, and both are events about the *channel*. A **window** can move instead: "Move to
    /// Session", and the New Session item that makes the destination first, take a window out of the
    /// session its pane's owner is attached to, and `%output` reaches a control client only for the
    /// session it is attached to. The pane was then owned by a client that would never send another
    /// byte for it while the follower on the session it landed in had every byte discarded — a tab
    /// that froze the moment it was moved and stayed frozen for the life of the connection, with
    /// keystrokes still arriving and nothing on screen to say the picture was a photograph.
    ///
    /// Judged from the topology census rather than from `%window-close`, for the reason the prune
    /// beside it is: the notification says a window left *a* session and cannot say which, and a
    /// window that is still in the owner's session after an unlink must keep its claim.
    private func releaseStrandedPanes(hostId: String) {
        guard let host = hosts[hostId], !(paneOwners[hostId] ?? [:]).isEmpty else { return }

        var sessionsShowing: [String: Set<String>] = [:]
        for session in host.sessions {
            for window in session.windows {
                for paneId in window.panes.map(\.id) + (window.layoutTree?.paneIds ?? []) {
                    sessionsShowing[paneId, default: []].insert(session.id)
                }
            }
        }

        for (paneId, epoch) in paneOwners[hostId] ?? [:] {
            // A pane the census does not mention is not stranded, it is unknown — `pruneVanishedPanes`
            // is what decides whether it is gone. A channel still handshaking is attached to nothing
            // yet, and cannot be judged on a session it has not landed on.
            guard let sessions = sessionsShowing[paneId],
                  let owner = channel(of: hostId, epoch: epoch),
                  let attached = owner.attachedSessionId,
                  !sessions.contains(attached) else { continue }
            log("[\(hostId)] \(paneId) left \(attached); releasing it for whichever client can see it")
            releasePane(hostId: hostId, paneId: paneId)
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
    ///
    /// **Coalesced on the trailing edge of the window, written on the leading one**, and the
    /// difference is most of P6.1's budget. This used to start a task that slept `keyFlushInterval`
    /// and *then* wrote, so a keystroke with nothing to coalesce with — which is every keystroke at
    /// typing speed — paid the full 8 ms before anything left the process. Measured against P6.1's
    /// 12 ms: p50 keypress → echo was 9.76 ms, of which 8 was this timer and 1.8 was the work
    /// (`docs/measurements.md`).
    ///
    /// So a keystroke arriving when the window has already elapsed goes out **now**, and the window
    /// starts again from that write; anything typed during it accumulates and leaves as one command
    /// when it closes. Under sustained typing the command rate is unchanged — one per interval,
    /// which is what P6.4 asks for and what keeps a burst from becoming one `%begin`/`%end` round
    /// trip per key. What changes is only the first keystroke after a pause, which is the one a
    /// person is waiting on.
    public func sendKeys(hostId: String, paneId: String, bytes: [UInt8]) {
        guard !bytes.isEmpty, let connection = connections[hostId] else { return }
        connection.pendingKeys[paneId, default: []].append(contentsOf: bytes)

        // A flush is already scheduled: this keystroke is one of the ones being coalesced.
        guard connection.keyFlushTask == nil else { return }

        guard let last = connection.lastKeyFlush else {
            flushKeys(hostId: hostId)
            return
        }
        let elapsed = now() - last
        guard elapsed < keyFlushInterval else {
            flushKeys(hostId: hostId)
            return
        }
        // Part-way into the window, so this waits out the *remainder* rather than a fresh interval.
        // Sleeping the whole interval here would let a steady typist push the flush further away
        // with every key and starve it for as long as they kept typing.
        connection.keyFlushTask = Task { [weak self, remaining = keyFlushInterval - elapsed] in
            try? await Task.sleep(for: remaining)
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
        // Nothing to send is not a write, so it must not start the window: a flush that found an
        // empty queue would otherwise make the next keystroke wait out an interval during which
        // nothing was sent.
        guard batches.contains(where: { !$0.value.isEmpty }) else { return }
        connection.lastKeyFlush = now()

        for (paneId, bytes) in batches where !bytes.isEmpty {
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            send("send-keys -H -t \(paneId) \(hex)", kind: .ignore, hostId: hostId, connection: connection)
            // The one seam a test has on the coalescer: whether a burst became one command or
            // several is invisible in `HostState` by design — the pane receives the same bytes
            // either way — so this is asserted through the diagnostic logger, as flow control is.
            log("[\(hostId)] send-keys flush: \(bytes.count) byte(s) to \(paneId)")
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

    /// R3.8's ≥3.2 row: subscribe to what is running in every pane instead of polling for it.
    ///
    /// Only the primary. A subscription is per client and the values are server-wide, so one channel
    /// asking is the whole answer; every follower subscribing would multiply identical notifications
    /// by the number of sessions on screen.
    private func applySubscriptionPolicy(hostId: String, connection: Connection) {
        guard connection.isPrimary,
              let version = connection.version,
              version.supportsSubscriptions
        else { return }
        send(TmuxCommand.subscribePaneCommand(), kind: .ignore, hostId: hostId, connection: connection)
    }

    /// R3.8's 2.4–2.9 row: say once, per host, that the server is old enough to lose features.
    ///
    /// Once per host and not per channel: a follower opening is not news, and a reconnect every
    /// thirty seconds on a flaky link would otherwise re-raise the same banner forever.
    private func warnIfServerIsOld(hostId: String, version: TmuxVersion) {
        guard version.supportsControlMode, !version.sizesWindowsIndividually else { return }
        guard !warnedAboutOldServer.contains(hostId) else { return }
        warnedAboutOldServer.insert(hostId)
        log("[\(hostId)] tmux \(version.raw) is below 2.9; per-window sizing and flow control are unavailable")
        withHost(hostId) { host in
            host.lastCommandFailure = CommandFailure(
                action: "tmux \(version.raw)",
                message: "This server is older than 2.9. Tabs are sized by the smallest attached "
                    + "client, and panes cannot be paused when output outruns the display."
            )
        }
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

    /// F4.17 — detaches tetmux clients left behind by a dropped connection.
    ///
    /// An ssh link that dies takes our end of the channel with it, but the tmux client on the far
    /// side keeps its pty and stays attached until something tells it otherwise. It then counts as a
    /// live client of the session, and below tmux 2.9 — where `window-size latest` is the only sizing
    /// mechanism there is (F4.17, and see `applyWindowSizePolicy`) — an orphan sized 80×24 drags every
    /// window in the session down to 80×24 with it. The SRD calls this the single most common failure
    /// mode in applications of this class, and until now the probe was sent on every attach and its
    /// answer went to `log()` and nowhere else.
    ///
    /// Two things keep this from detaching something it should not:
    ///
    /// **Control-mode only.** Every tetmux channel is a control-mode client and an ordinary terminal
    /// running `tmux attach` is not, so the user's own terminals are never candidates. This is the
    /// nearest thing to the SRD's "distinctive client name": tmux has no settable client name —
    /// `client_name` *is* the tty and no command changes it — so `client_control_mode` is the only
    /// tag on offer. It is not perfect, and the two cases to know about are another `tmux -CC`
    /// application on the same server (iTerm2's tmux integration is the one that exists) and a second
    /// *live* copy of tetmux — two of those would each read the other's channels as orphans and
    /// detach them in turn. A packaged app cannot normally be launched twice, but `swift run`
    /// alongside an installed build can, which is worth knowing before diagnosing it as a dropped
    /// connection. Both are still a far narrower blast radius than `detachOtherClients`, which the
    /// menu offers and which detaches everything including the user's own terminals.
    ///
    /// **Never while one of our own channels is still handshaking.** A follower that has not yet
    /// answered `#{client_tty}` is indistinguishable from an orphan, and detaching it would kill a
    /// client we opened a moment ago. If any channel of this host has no tty yet, the whole pass is
    /// skipped — the next attach runs it again.
    private func reconcileStaleClients(_ clients: [TmuxClient], hostId: String) {
        guard !channels(of: hostId).contains(where: { $0.clientTty == nil }) else {
            log("[\(hostId)] skipping client reconciliation: a channel has not identified itself yet")
            return
        }

        // `isOurs` is that same tty comparison, made once where the row was parsed. The guard above
        // is still the one that matters: it is what stops an unidentified channel of our own from
        // being read as an orphan and detached a moment after we opened it.
        for client in clients where client.isControlMode && !client.isOurs && !client.tty.isEmpty {
            log("[\(hostId)] detaching orphaned control-mode client \(client.tty)")
            send("detach-client -t \(TmuxCommand.quote(client.tty))", kind: .ignore, hostId: hostId)
        }
    }

    /// Parses `list-clients` into the model: who is attached to this server, and which of them is us.
    ///
    /// Returns the parsed rows as well as storing them, because the F4.17 detach pass reads the same
    /// answer and re-parsing it to decide would be two readings of one fact.
    ///
    /// Tolerant by field count rather than strict: `client_user` does not exist below tmux 3.3, and a
    /// row for a client with no session is not a row worth dropping the whole list over. A client
    /// tetmux cannot describe is still a client that a kill would throw out, and saying "one other
    /// client, and I cannot tell you whose" beats saying nothing.
    @discardableResult
    private func applyClients(_ lines: [String], hostId: String) -> [TmuxClient] {
        let ourTtys = Set(channels(of: hostId).compactMap(\.clientTty))

        let clients: [TmuxClient] = lines.compactMap { line in
            let fields = line.split(separator: "|", maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count >= 3 else { return nil }
            let tty = String(fields[0])
            guard !tty.isEmpty else { return nil }
            let field = { (index: Int) in fields.count > index ? String(fields[index]) : "" }
            // `client_activity` is a unix timestamp from the *server's* clock. A remote host with a
            // clock that disagrees with this one would report an idle time that is wrong by the
            // difference — which is why the UI says "active 5 minutes ago" and never a wall time.
            let activity = Double(field(3)).map { Date(timeIntervalSince1970: $0) }
            return TmuxClient(
                tty: tty,
                sessionId: String(fields[2]),
                user: field(4),
                terminal: field(5),
                isControlMode: fields[1] == "1",
                isOurs: ourTtys.contains(tty),
                lastActivity: activity
            )
        }

        withHost(hostId) { $0.clients = clients }
        return clients
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

    /// A tab, opened where the pane it was opened from is sitting.
    ///
    /// tmux would otherwise start it in the *session's* directory — see
    /// `TmuxCommand.inheritedWorkingDirectoryFormat`, which also says why the directory is asked for
    /// and passed on rather than left to `-c` to expand. `fromPaneId` is the pane the tab is being
    /// opened *from*; without one the session is asked instead and answers for its current pane,
    /// which is what the sidebar's `+` means — it names a session the user is not looking at, whose
    /// panes are not the ones on screen.
    ///
    /// It is placed **after the last tab** rather than left to tmux to index. Left to itself tmux
    /// puts a new window at the *lowest free index*, which is the end of the strip only while the
    /// indices are contiguous: kill window 0 of a two-window session and the next `new-window` drops
    /// back into that hole, in front of the window the user still has — and the one after that,
    /// finding no hole left, lands at the end as expected. That is the reported shape of it: the
    /// second tab jumps to the front and the third behaves. tmux's own status bar numbers its
    /// windows, so there the arithmetic is visible; a tab strip with no numbers on it just puts the
    /// tab that was asked for last in front of everything, and the `+` button that opened it sits at
    /// the other end of the strip.
    public func newWindow(hostId: String, sessionId: String? = nil, fromPaneId: String? = nil) async {
        // The attached session when the caller did not name one — the same session tmux itself would
        // have picked, but named here because the anchor below has to be looked up in it.
        let session = sessionId ?? hosts[hostId]?.activeSessionId
        // Session-qualified, for the reason the `move-window -s` below is: a linked window is
        // reachable by `@id` from every session holding it, and an unqualified target leaves tmux to
        // decide which of them the new window is created in.
        let target: String
        if let session, let last = windowOrder(hostId: hostId, sessionId: session)?.last {
            target = " -a -t \(TmuxCommand.quote("\(session):\(last)"))"
        } else {
            // No topology yet, so there is no last tab to anchor to. tmux's own choice is the only
            // one left, and with nothing on the strip to be in front of it cannot be wrong.
            target = session.map { " -t \(TmuxCommand.quote($0))" } ?? ""
        }
        let directory = await startDirectory(hostId: hostId, target: fromPaneId ?? sessionId)
        send("new-window\(target)\(directory)", kind: .userCommand("New tab"), hostId: hostId)
    }

    /// A split, opened where the pane being split is sitting.
    public func splitPane(hostId: String, paneId: String, leftRight: Bool) async {
        let directory = await startDirectory(hostId: hostId, target: paneId)
        send("split-window \(leftRight ? "-h" : "-v") -t \(paneId)\(directory)",
             kind: .userCommand("Split pane"), hostId: hostId)
    }

    /// `-c <where that pane is>`, or nothing when there is nothing to ask about or tmux did not
    /// answer with a usable directory.
    ///
    /// The round trip is what makes the answer the *target's*: `-c` would expand a format against the
    /// session's current pane instead, which is a different pane whenever a tab was just opened or a
    /// second macOS window is showing another one. It costs one RTT before the pane appears, on top of
    /// the one the spawn already waits for — opening a pane is a deliberate act, and landing it in the
    /// wrong directory is the thing the user notices.
    private func startDirectory(hostId: String, target: String?) async -> String {
        guard let target, let connection = connections[hostId] else { return "" }
        let lines = await sendAndAwaitResult(
            TmuxCommand.paneCurrentPath(target: target),
            action: nil, hostId: hostId, connection: connection
        )
        let path = lines?.first.map { String(decoding: $0, as: UTF8.self) }
        return TmuxCommand.startDirectoryArgument(path)
    }

    public func killPane(hostId: String, paneId: String) {
        send("kill-pane -t \(paneId)", kind: .userCommand("Close pane"), hostId: hostId)
    }

    public func selectPane(hostId: String, paneId: String) {
        send("select-pane -t \(paneId)", hostId: hostId)
    }

    // MARK: - Copy mode

    /// Puts a pane into tmux's copy mode.
    ///
    /// tmux's own scrollback, tmux's own search, and text that scrolled out of what SwiftTerm is
    /// holding locally — none of which the emulator's selection can reach. `%pane-mode-changed`
    /// follows, which is what makes the mode visible; the flag itself comes from the `list-panes`
    /// that notification schedules.
    public func enterCopyMode(hostId: String, paneId: String) {
        send(TmuxCommand.enterCopyMode(paneId: paneId),
             kind: .userCommand("Copy mode"), hostId: hostId)
    }

    /// One of the documented copy-mode actions, if the pane is in a mode to receive it.
    ///
    /// The guard is not defensive tidiness. tmux answers `not in a mode` with an `%error` (verified
    /// on 3.7b), these are user commands, and §7 turns a refused user command into a banner — so an
    /// unguarded action would put an error in front of somebody whose only mistake was that the pane
    /// left copy mode before the menu item was clicked. That is a race anyone can lose: `q` in the
    /// pane, or another client, ends the mode without asking us.
    public func copyModeAction(_ action: TmuxCommand.CopyModeAction, hostId: String, paneId: String) {
        guard isPaneInMode(hostId: hostId, paneId: paneId) else { return }
        send(TmuxCommand.copyModeAction(action, paneId: paneId),
             kind: .userCommand(Self.describe(action)), hostId: hostId)
    }

    /// A copy-mode search, entering copy mode first if the pane is not already in it.
    ///
    /// Searching tmux's history *means* being in copy mode, so this is one action rather than two:
    /// asking the user to enter the mode first would make the search item silently do nothing until
    /// they had. Entering here rather than at the call site also closes a race — the mode flag only
    /// arrives after `%pane-mode-changed` has prompted a `list-panes`, so a caller that entered the
    /// mode and then searched would be refused by the guard on any link slow enough to matter. Both
    /// commands go down one channel in order, so tmux sees them in the order they are written.
    public func copyModeSearch(
        _ action: TmuxCommand.CopyModeAction, hostId: String, paneId: String, needle: String
    ) {
        let needle = TmuxCommand.singleLine(needle)
        guard !needle.isEmpty else { return }
        guard let connection = connections[hostId] else { return }
        if !isPaneInMode(hostId: hostId, paneId: paneId) {
            send(TmuxCommand.enterCopyMode(paneId: paneId),
                 kind: .userCommand("Copy mode"), hostId: hostId, connection: connection)
        }
        send(TmuxCommand.copyModeSearch(action, paneId: paneId, needle: needle),
             kind: .userCommand("Search"), hostId: hostId, connection: connection)
    }

    /// Copies the selection and hands the text back, for whoever can reach a pasteboard.
    ///
    /// This is the half tmux cannot do. `copy-selection-and-cancel` puts the selection in a buffer on
    /// the *server*, which on a remote host is a machine the Mac's pasteboard has never heard of, and
    /// nothing bridges the two: OSC 52 is the pane's own channel and is denied by default (T5.6). So
    /// the buffer is read straight back with `show-buffer` and returned as a string.
    ///
    /// The bytes rather than the parsed lines, joined with `\n`: buffer contents are arbitrary text
    /// and `commandResultLine`'s `line` is lossy by construction. `nil` means tmux refused — an empty
    /// selection yields `no buffers` — and the caller must not confuse that with an empty string,
    /// because one of them should leave the pasteboard alone.
    ///
    /// Returning it rather than setting the pasteboard here is §2.4: `tetmuxCore` has no AppKit.
    public func copySelection(hostId: String, paneId: String) async -> String? {
        guard let connection = connections[hostId] else { return nil }
        guard isPaneInMode(hostId: hostId, paneId: paneId) else { return nil }
        send(TmuxCommand.copyModeAction(.copySelectionAndCancel, paneId: paneId),
             kind: .userCommand("Copy"), hostId: hostId, connection: connection)
        let lines = await sendAndAwaitResult(
            TmuxCommand.showBuffer, action: "Copy", hostId: hostId, connection: connection
        )
        guard let lines else { return nil }
        return lines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
    }

    /// Whether tmux says this pane is showing a mode overlay right now.
    private func isPaneInMode(hostId: String, paneId: String) -> Bool {
        hosts[hostId]?.pane(paneId)?.isInMode ?? false
    }

    /// The label a refusal is reported under (§7), in the words the menu item uses.
    private static func describe(_ action: TmuxCommand.CopyModeAction) -> String {
        switch action {
        case .beginSelection: return "Start selection"
        case .clearSelection: return "Clear selection"
        case .copySelectionAndCancel: return "Copy"
        case .cancel: return "Leave copy mode"
        case .cursorUp, .cursorDown, .cursorLeft, .cursorRight: return "Move cursor"
        case .pageUp, .pageDown: return "Scroll"
        case .historyTop, .historyBottom: return "Jump"
        case .searchBackward, .searchForward, .searchAgain, .searchReverse: return "Search"
        }
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
             kind: .userCommand("Rename tab"), hostId: hostId)
    }

    /// F4.9 — closing a tab unlinks the window from the session; it never kills what is running.
    public func unlinkWindow(hostId: String, windowId: String) {
        send("unlink-window -t \(windowId)", kind: .userCommand("Close tab"), hostId: hostId)
    }

    // MARK: - Window ordering

    /// Reorders a window inside its session, putting it where a dragged tab was dropped.
    ///
    /// `before` is the window the dragged one should land in front of, or `nil` for the end of the
    /// strip — the same "insert before this element, or append" shape `onMove` has, which is what the
    /// tab strip can say without knowing anything about tmux indices.
    ///
    /// Indices are deliberately never mentioned. A session's window indices are arbitrary and often
    /// not contiguous — `base-index`, a killed window, `renumber-windows` off — so computing a target
    /// index from a position in the strip would be right until the first gap. Both branches below
    /// address windows by their `@id`, which says what was dragged onto what regardless of numbering.
    ///
    /// Two branches, because `move-window -a`/`-b` is tmux 3.2 and the SRD's floor is 3.0 (verified
    /// against the R3.6 matrix: 3.0 answers `illegal option -- b`, 3.2a onward accept it). Below 3.2
    /// the same permutation is built out of `swap-window`, which 3.0 does have: moving an element from
    /// one position to another *is* a run of adjacent swaps toward the target, and the elements it
    /// passes shift by one exactly as an insert would move them. That costs one command per position
    /// crossed rather than one command, which is why it is the fallback and not the mechanism.
    public func moveWindow(hostId: String, sessionId: String, windowId: String, before: String?) {
        guard let order = windowOrder(hostId: hostId, sessionId: sessionId),
              let from = order.firstIndex(of: windowId) else { return }

        // Where the window lands once it has been taken out of the strip. Removing it first is what
        // makes "drop before the window after me" a no-op rather than a move by one.
        var remaining = order
        remaining.remove(at: from)
        let to = before.flatMap { remaining.firstIndex(of: $0) } ?? remaining.count
        guard to != from else { return }

        // Both branches end by asking for the topology again, and that is not belt-and-braces: the
        // window *order* lives only in `list-windows`, and neither command has a notification that
        // means "the order changed". `move-window` looked as though it did — it emits `%window-add`
        // then `%window-close` for the same window, because tmux implements it by unlinking and
        // relinking, and those happen to schedule a refresh. `swap-window` emits
        // `%session-window-changed` alone, which only says which window is *active*. So below tmux
        // 3.2 a dragged tab reordered the windows on the server and the strip never moved: the model
        // kept the order it last read, silently, until something unrelated refreshed it. Found by
        // running the suite against 3.0 (`Scripts/test-matrix.sh`); it cannot be seen on a machine
        // with one modern tmux, where the accident holds.
        let connection = connections[hostId]
        // Unknown version is treated as modern, like every other version gate here: an old server
        // answers with an error the user sees, where assuming old on a new one would silently take
        // the slow path forever.
        let supportsRelativeMove = connection?.version.map(\.movesWindowsRelatively) ?? true
        if supportsRelativeMove {
            // `-b <that window>`, or `-a <the last one>` when the drop was past the end.
            let anchor = to < remaining.count ? remaining[to] : remaining[remaining.count - 1]
            let flag = to < remaining.count ? "-b" : "-a"
            // The source is qualified with its session: a window linked into several sessions is
            // reachable by `@id` from any of them, and an unqualified `-s` leaves tmux to pick which
            // session it is being taken out of. Verified on 3.5 — `move-window -s A:@1 -t C:` removes
            // it from A alone and leaves the link in B.
            send(
                "move-window \(flag) -s \(TmuxCommand.quote("\(sessionId):\(windowId)")) -t \(anchor)",
                kind: .userCommand("Reorder tab"), hostId: hostId
            )
            scheduleTopologyRefresh(hostId: hostId)
            return
        }

        // Bubble it, one neighbour at a time. `remaining` is the strip without the dragged window, so
        // the sequence of windows it has to pass is exactly the slice between the two positions.
        // `-d` so the selection does not follow it: the tab that was in front stays in front.
        let passed = to > from ? Array(remaining[from..<to]) : Array(remaining[to..<from]).reversed()
        for neighbour in passed {
            send("swap-window -d -s \(windowId) -t \(neighbour)",
                 kind: .userCommand("Reorder tab"), hostId: hostId)
        }
        scheduleTopologyRefresh(hostId: hostId)
    }

    /// Moves a window out of one session and into another (F4.9's other half — nothing is killed).
    ///
    /// Appended to the destination rather than placed: `-t $id:` with no index is tmux's own "next
    /// free index there", and there is no drop position to honour when the gesture is a menu item.
    public func moveWindow(hostId: String, windowId: String, fromSession: String, toSession: String) {
        guard fromSession != toSession else { return }
        send(
            "move-window -s \(TmuxCommand.quote("\(fromSession):\(windowId)"))"
                + " -t \(TmuxCommand.quote("\(toSession):"))",
            kind: .userCommand("Move tab"), hostId: hostId
        )
    }

    /// The same move, into a session that does not exist yet — three commands, because tmux has no
    /// one command for it.
    ///
    /// `move-window -t <a name nothing answers to>:` is an error on every version (`can't find
    /// session`, verified on 3.0 and 3.5), and `new-session` cannot be handed an existing window. So
    /// the session is made, the window is moved in, and the window `new-session` had to create is
    /// killed — it exists for the length of a round trip and runs a shell nobody sees.
    ///
    /// Three things make the sequence safe to send blind, which is the only way to send it: control
    /// mode answers `new-session` with no id, so waiting to learn one would mean waiting for a
    /// topology refresh with the user's window in limbo. tmux runs the commands **in order** on the
    /// one channel, so the session exists by the time the move names it. The placeholder is killed
    /// **by its own name**, never with `kill-window -a` (kill everything except the target), which
    /// reads as the tidier command and destroys the user's other tabs on the one occasion the move
    /// did not happen. And a failed move leaves the placeholder as the session's only window, so
    /// killing it takes the empty session with it — nothing is left behind and nothing was lost.
    ///
    /// `-A` is deliberately absent from the `new-session`: a name that is somehow taken must be a
    /// refusal rather than an attach, or the kill would land in a session somebody is using.
    public func moveWindowToNewSession(
        hostId: String,
        windowId: String,
        fromSession: String,
        name: String,
        startDirectory: String? = nil
    ) {
        let name = TmuxCommand.singleLine(name)
        guard !name.isEmpty else { return }
        send(
            "new-session -d -s \(TmuxCommand.quote(name))"
                + " -n \(TmuxCommand.quote(Self.placeholderWindowName))"
                + " -c \(TmuxCommand.quote(TmuxCommand.sessionStartDirectory(startDirectory)))",
            kind: .userCommand("Move tab to a new session"), hostId: hostId
        )
        send(
            "move-window -s \(TmuxCommand.quote("\(fromSession):\(windowId)"))"
                + " -t \(TmuxCommand.quote("\(name):"))",
            kind: .userCommand("Move tab to a new session"), hostId: hostId
        )
        send(
            "kill-window -t \(TmuxCommand.quote("\(name):\(Self.placeholderWindowName)"))",
            // Not a `userCommand`: if the move failed the user is already reading why, and a second
            // banner about the window we made to hold it explains nothing they can act on.
            kind: .ignore, hostId: hostId
        )
    }

    /// The window `new-session` insists on creating, named so it can be killed by name.
    ///
    /// Distinctive on purpose — the kill is scoped to the new session, so this only has to be a name
    /// the window being moved in is unlikely to have.
    static let placeholderWindowName = "tetmux-new-session"

    /// Links a window into a second session, leaving it in the first.
    ///
    /// The inverse of `unlinkWindow`, and the thing that makes F4.9's unlink path reachable at all: a
    /// window in one session cannot be closed without being killed, and this is how it comes to be in
    /// two.
    public func linkWindow(hostId: String, windowId: String, toSession: String) {
        send(
            "link-window -s \(windowId) -t \(TmuxCommand.quote("\(toSession):"))",
            kind: .userCommand("Link tab"), hostId: hostId
        )
    }

    /// The session's windows in tmux's own order, which is the order `list-windows` reported them in.
    private func windowOrder(hostId: String, sessionId: String) -> [String]? {
        hosts[hostId]?.sessions.first { $0.id == sessionId }?.windows.map(\.id)
    }

    public func killWindow(hostId: String, windowId: String) {
        send("kill-window -t \(windowId)", kind: .userCommand("Kill tab"), hostId: hostId)
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
    ///
    /// F4.11's three parameters, all of which are the host's rather than a dialog's — see
    /// `HostConfig.startDirectory` and `HostConfig.initialCommand` for why that is the only shape
    /// they can take.
    public func newSession(
        hostId: String,
        name: String,
        startDirectory: String? = nil,
        initialCommand: String? = nil
    ) {
        let name = TmuxCommand.singleLine(name)
        guard !name.isEmpty else { return }
        var command = "new-session -d -s \(TmuxCommand.quote(name))"
        // Always, and never left to tmux: with no `-c` a session created over an attached channel
        // inherits the *attached session's* directory (verified on 3.0 through 3.7b), so every
        // session on a host ends up wherever the first one happened to start — `/` for a locally
        // launched `.app`, and someone's old project directory on a remote host.
        //
        // `sessionStartDirectory` puts the value through `singleLine` for the reason every name gets
        // it: control-mode commands are newline-framed, so a value carrying a line break ends the
        // command before tmux's parser reaches the closing quote and the remainder arrives as a
        // *new* command that tmux runs. Quoting cannot defend against that, and this is a text field
        // that accepts a pasted path.
        command += " -c \(TmuxCommand.quote(TmuxCommand.sessionStartDirectory(startDirectory)))"
        // Last, and after every option: `shell-command` is `new-session`'s trailing positional
        // argument, and tmux stops reading flags at the first word that is not one. It is a single
        // argument that the far-side shell parses, so it is quoted whole rather than split here —
        // `htop -d 10` is one command, not a command and a flag we get to interpret.
        let initial = TmuxCommand.singleLine(initialCommand ?? "")
        if !initial.isEmpty {
            command += " \(TmuxCommand.quote(initial))"
        }
        send(command, kind: .userCommand("New session"), hostId: hostId)
    }

    /// F4.11 — detaches every other client from the session we are attached to. Also the remedy
    /// for an orphaned client clamping window size (F4.17) when `window-size latest` is not enough.
    public func detachOtherClients(hostId: String) {
        guard let connection = connections[hostId] else { return }
        send("detach-client -a -s \(TmuxCommand.quote(connection.sessionTarget))", kind: .ignore, hostId: hostId, connection: connection)
    }

    /// F4.11 — detaches *this* client, leaving the session running.
    ///
    /// The polite half of the pair above, and the one F4.11 asked for and did not have: disconnecting
    /// tears the pty down with `SIGHUP` and lets tmux notice, which works but leaves the server to
    /// clean up after a client that vanished. `detach-client` with no target says so, and the `%exit`
    /// it produces is the ordinary end-of-session path the recovery logic already understands.
    ///
    /// Waited for rather than merely written, for the same reason `restoreWindowSizePolicy` is: the
    /// caller is about to hang the channel up, and a `detach-client` still sitting in the pty when
    /// `SIGHUP` lands did not happen at all.
    public func detachThisClient(hostId: String) async {
        guard let connection = connections[hostId] else { return }
        connection.userInitiatedDisconnect = true
        await sendAndAwait("detach-client", hostId: hostId, connection: connection)
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
        // Read before `teardown`, which lets the connection go.
        let createsIfServerIsEmpty = connection.createsIfServerIsEmpty
        let handshakeComplete = connection.handshakeComplete
        let isRecoveryAttempt = connection.isRecoveryAttempt
        let defaultName = defaultSessionName(for: hostId)
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
            // The name is dead. Keeping it would resurrect it on the next explicit connect too — but
            // it is also the only record of what the user was in, and F4.15's second half is exactly
            // "offer recreation by name on explicit user action". So it moves from the field that
            // *acts* on it to the field that merely *says* it, and the button is what acts.
            //
            // Only when there *is* one: this handler runs a second time when the `attachAny` below
            // comes back empty, and by then the target has already been taken. Writing nil then would
            // erase the name on the exact path that needs it most.
            if let endedName = reconnectTarget.removeValue(forKey: hostId) {
                withHost(hostId) { $0.endedSessionName = endedName }
            }

            guard attachedToSession else {
                // Nothing to attach to. What that *means* depends on who asked: a click on a host is
                // a request for a shell on it, so an empty server is the one case where creating one
                // is right — and doing nothing instead is what made clicking a host look broken.
                // Automatic recovery keeps the old behaviour, which is F4.15.
                if createsIfServerIsEmpty {
                    log("[\(hostId)] nothing to attach to; creating a session because the user asked to open this host")
                    Task { [weak self] in
                        try? await self?.connectHost(
                            hostId: hostId,
                            mode: .createOrAttach(sessionName: defaultName)
                        )
                    }
                    return
                }
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

        // R3.8's last row. Retrying is pointless — a host with no tmux will not grow one on the
        // second attempt — and the message is the whole of what the user needs, so it is stated once
        // and accompanied by the only thing that can be offered instead (§4.6).
        if !connection.handshakeComplete, Self.describesMissingTmux(reason) {
            log("[\(hostId)] there is no tmux on this host; offering a plain shell")
            withHost(hostId) { host in
                host.connectionState = .failed(reason: reason)
                host.passthrough = PassthroughState(
                    reason: .tmuxUnavailable, phase: .offered, detail: reason
                )
            }
            broadcastState()
            return
        }

        // The other shape of "nothing to attach to": no tmux server on that host at all, which never
        // reaches a handshake — tmux says `no server running on /tmp/tmux-1000/default` and exits.
        // Without this the click falls into the backoff and retries an attach that cannot ever
        // succeed, eight times, and ends at `.failed` on a host that is perfectly reachable.
        if createsIfServerIsEmpty, !handshakeComplete, Self.describesEmptyServer(reason) {
            log("[\(hostId)] no tmux server there yet; starting one because the user asked to open this host")
            Task { [weak self] in
                try? await self?.connectHost(
                    hostId: hostId, mode: .createOrAttach(sessionName: defaultName)
                )
            }
            return
        }

        // F4.14: authentication failures are not retried — retrying just locks the account out.
        if isAuthenticationFailure(reason) {
            withHost(hostId) { $0.connectionState = .failed(reason: reason) }
            broadcastState()
            return
        }

        // **The backoff is for a connection that dropped, not for one that never started.** A channel
        // the user asked for and that never reached a handshake has failed at something the user is
        // standing right there to read — a wrong hostname, a refused port, a host that is off — and
        // eight silent attempts over a minute and a half neither fix it nor say so. The reason goes on
        // screen instead, with the Retry button that is already there.
        //
        // A channel that *did* handshake and then died is the case F4.14 exists for: the link went,
        // the session is still on the server, and getting back to it should not need a click. So is a
        // recovery attempt that fails before its handshake — that is the lid closing on a train, where
        // failing to connect is the expected state for the next several attempts.
        if !handshakeComplete, !isRecoveryAttempt {
            log("[\(hostId)] connect failed and nobody has lost anything; leaving it to the user")
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
        for (_, continuation) in connection.results { continuation.resume(returning: nil) }
        connection.results.removeAll()
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

    /// What clicking a host means: **attach to what is there, and make a session only if there is
    /// nothing to attach to.**
    ///
    /// Every user-initiated connect comes through here — the sidebar row, the placeholder's Connect,
    /// the banner's Retry, the launcher, the menu bar. It is `attach-session` with **no target**,
    /// which lands on the server's most recently used session and cannot create; only when that finds
    /// an empty (or absent) server does a second attempt make one.
    ///
    /// It replaces `reconnectNow` at every one of those call sites, and the reason is a bug that made
    /// the app look broken. Those clicks used to run the *recovery* path, which attaches by remembered
    /// name — and with nothing remembered that name is a generated one (`tetmux_1`; it was the
    /// constant `tetmux-main` at the time), which almost no server has.
    /// tmux answers `can't find session`, `%error`, `%exit`; the `%exit` handler reads
    /// "the server has nothing left", sets `.disconnected`, and returns without retrying or saying
    /// anything. So clicking a host with three sessions on it did *nothing at all*, silently, while
    /// clicking one of those sessions in the tree worked — because that path names a session that
    /// exists.
    ///
    /// F4.15 is untouched: it forbids *automatic* reconnection from creating, and its own text carves
    /// out "recreation by name on explicit user action". This is that action.
    ///
    /// It also clears the circuit breaker (F4.14) and any pending backoff, which is the other half of
    /// what the old `reconnectNow` was for: the automatic attempts and a deliberate click mean
    /// different things. The breaker exists to stop us hammering a host nobody asked about, and a
    /// click is someone saying the host is reachable again — without the reset, a host that had spent
    /// its eight attempts would refuse to come back for the rest of the session. The scheduled attempt
    /// has to be cancelled rather than merely outrun, or it fires later on top of the connection this
    /// call is about to make.
    public func openHost(hostId: String) async {
        cancelScheduledReconnect(hostId: hostId)
        reconnectAttempts[hostId] = 0
        // A click is the user asserting the host is worth trying, so the name that failed last time
        // is no longer a reason to skip straight to `attachAny` — and `attachAny` is what this uses
        // in any case.
        recoveryLostItsSession.remove(hostId)
        // The user answered the offer, whichever button they pressed. Leaving the name set would keep
        // "Session 'work' ended" on screen behind a connection that is being made right now.
        withHost(hostId) { $0.endedSessionName = nil }
        try? await connectHost(hostId: hostId, mode: .attachAny, createIfEmpty: true)
    }

    /// F4.15's second half — recreate, by name, the session that ended.
    ///
    /// The one place creating a session from a *remembered* name is right, and it is right because the
    /// name is on screen with a button beside it: the user is reading "Session 'work' ended" and
    /// asking for `work` back. What F4.15 forbids is the automatic path doing this behind their back,
    /// where a server that restarted while the link was down would have an empty session manufactured
    /// under the remembered name and presented as their work.
    public func recreateEndedSession(hostId: String) async {
        guard let name = hosts[hostId]?.endedSessionName else { return }
        cancelScheduledReconnect(hostId: hostId)
        reconnectAttempts[hostId] = 0
        recoveryLostItsSession.remove(hostId)
        withHost(hostId) { $0.endedSessionName = nil }
        try? await connectHost(
            hostId: hostId, targetSession: name, mode: .createOrAttach(sessionName: name)
        )
    }

    /// tmux's own words for "there is nothing here to attach to", as opposed to a host that could not
    /// be reached at all. Both end a channel; only the first is a reason to make a session.
    static func describesEmptyServer(_ reason: String) -> Bool {
        let lowered = reason.lowercased()
        return lowered.contains("no server running")
            || lowered.contains("no sessions")
            || lowered.contains("error connecting to")
            || lowered.contains("can't find session")
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
