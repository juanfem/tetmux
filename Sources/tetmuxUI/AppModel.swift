import AppKit
import Observation
import SwiftUI
import tetmuxCore

/// The single `@MainActor` view model. Everything below it is plain Swift with no AppKit
/// dependency; this is the only place where the two worlds meet.
@MainActor
@Observable
public final class AppModel {
    public let service = SessionService()
    public let store: HostConfigStore
    public let workspace: WorkspaceStore
    public let settings: SettingsStore

    public var hosts: [HostState] = []
    /// Written by the settings pane and by ⌘+/⌘−, and persisted on every change.
    ///
    /// `didSet` rather than an explicit save at each call site: there are several writers now and one
    /// that forgot would look exactly like a setting that does not stick.
    public var theme = TerminalTheme.load() {
        didSet {
            guard theme != oldValue else { return }
            theme.save()
        }
    }
    /// F4.19/F4.22 — the one policy every surface consults, now loaded from `settings.json` rather
    /// than fixed at compile time.
    ///
    /// Written through `rebind` and `resetKeymap`, which persist. Assigning the whole map from
    /// outside is deliberately not a thing anyone does: the conflict check belongs with the write.
    public private(set) var keymap = KeymapPolicy.default

    /// F4.21 — ⌥⌘V has been pressed and the next chord belongs to the pane, not to the application.
    ///
    /// Observable because it has to be *visible*: a mode that changes what the next keystroke does
    /// and says nothing is indistinguishable from the application having hung. The status bar shows
    /// it, and it clears itself on the next key whatever that key turns out to be.
    public var literalEscapeArmed = false

    /// The one event monitor in the app. See `KeyEventMonitor` for why the escape cannot be a view.
    @ObservationIgnored private var keyMonitor: KeyEventMonitor?

    /// Arms the escape from the menu item, which is the discoverable half of the chord.
    public func armLiteralEscape() {
        literalEscapeArmed = true
    }

    /// Why a rebind was refused, for the settings pane to say so in place of failing silently.
    public enum RebindResult: Equatable {
        case applied
        /// The chord is already taken, by this command.
        case conflict(ApplicationShortcut)
        /// No ⌘ in it. See `KeymapPolicy.isBindable`.
        case notInCommandSpace
    }

    /// F4.19 — changes one binding and writes the difference from the defaults to `settings.json`.
    ///
    /// A conflict is refused rather than resolved. `KeymapPolicy.shortcut(for:)` breaks a tie by the
    /// enum case's spelling, which decides *something* but nothing anybody meant, so two commands on
    /// one chord means one of them quietly stops working.
    @discardableResult
    public func rebind(_ shortcut: ApplicationShortcut, to binding: KeyBinding?) -> RebindResult {
        if let binding {
            guard KeymapPolicy.isBindable(binding) else { return .notInCommandSpace }
            if let owner = keymap.shortcut(boundTo: binding, excluding: shortcut) {
                return .conflict(owner)
            }
        }
        keymap.rebind(shortcut, to: binding)
        persistKeymap()
        return .applied
    }

    /// Puts every binding back to the documented default, and empties the file's keymap entry.
    public func resetKeymap() {
        keymap = .default
        persistKeymap()
    }

    private func persistKeymap() {
        let overrides = keymap.overrides
        Task { [settings] in await settings.saveKeymapOverrides(overrides) }
    }

    /// An ssh prompt waiting on the user, when it could not be answered from the Keychain.
    ///
    /// Still application-wide, unlike the other sheets: a prompt belongs to a *host*, arrives
    /// unprompted from the channel, and no window asked for it. Exactly one window presents it —
    /// see `presentsHostLevelSheets` — because a prompt shown twice is a password typed twice.
    public var pendingAuthentication: PendingAuthentication?

    /// Open windows, in the order they registered.
    ///
    /// The head of this list is the window that presents host-level sheets. Order rather than a
    /// single flag so that closing that window promotes the next one instead of leaving nothing able
    /// to show a prompt.
    public private(set) var windowOrder: [UUID] = []

    /// The registered windows themselves, weakly.
    ///
    /// Weak because the model outlives every window: a closed window that is still in this map would
    /// go on being offered as somewhere to show a session. Entries are pruned on `unregisterWindow`,
    /// and any that a missed `onDisappear` leaves behind are skipped as they drain to nil.
    ///
    /// This exists because "which window is showing session `$3`?" has no other answer, and three
    /// separate features need it: bringing the right window forward from the menu bar (item 9),
    /// deciding whether a double-clicked session needs a new window at all (item 5), and warning a
    /// window that the session it displays is not the attached one.
    @ObservationIgnored private var windowsById: [UUID: WeakWindow] = [:]

    /// Least-recently-focused first, so the tail is the window to fall back to when nothing better
    /// presents itself. Separate from `windowOrder`, which is registration order and must not move.
    @ObservationIgnored private var focusOrder: [UUID] = []

    private final class WeakWindow {
        weak var state: WindowState?
        init(_ state: WindowState) { self.state = state }
    }

    @ObservationIgnored private var networkMonitor: NetworkStateMonitor?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    /// Prompts already acted on, by prompt id. A prompt stays published until it is answered, so
    /// without this every state broadcast in between would launch another Keychain lookup.
    @ObservationIgnored private var handledPrompts: Set<UUID> = []

    public struct PendingClose: Identifiable, Equatable {
        public var id: String { "\(hostId)/\(windowId)" }
        public let hostId: String
        public let windowId: String
        public let windowName: String
        public let paneCount: Int
        public let runningCommands: [String]
    }

    /// A session the user asked to kill, pending confirmation.
    ///
    /// Always asks, with no "don't ask again": killing a session ends every process in every window it
    /// has, and unlike closing a tab (F4.9) there is no unlink to fall back on.
    public struct PendingKillSession: Identifiable, Equatable {
        public var id: String { "\(hostId)/\(sessionId)" }
        public let hostId: String
        public let sessionId: String
        public let sessionName: String
        public let windowCount: Int
        public let runningCommands: [String]
    }

    /// F4.11 — rename applies to either level of the tree, and both go through the same sheet.
    public struct PendingRename: Identifiable, Equatable {
        public enum Subject: Equatable {
            /// `$id`
            case session(String)
            /// `@id`
            case window(String)
        }

        public var id: String {
            switch subject {
            case .session(let sessionId): return "\(hostId)/session/\(sessionId)"
            case .window(let windowId): return "\(hostId)/window/\(windowId)"
            }
        }

        public let hostId: String
        public let subject: Subject
        public let currentName: String

        public var title: String {
            switch subject {
            case .session: return "Rename Session"
            case .window: return "Rename Window"
            }
        }
    }

    /// A host being added or edited. Carries the persistable form plus the one field that is never
    /// persisted — the password itself, which only ever travels to the Keychain or to ssh.
    public struct HostDraft: Identifiable, Equatable {
        public var id: String { isNew ? "new-host" : host.id }
        public var isNew: Bool
        public var host: StoredHost
    }

    /// An ssh prompt the user has to answer.
    public struct PendingAuthentication: Identifiable, Equatable {
        public var id: UUID { prompt.id }
        public let hostId: String
        public let hostName: String
        public let prompt: AuthenticationPrompt

        /// A key's passphrase belongs to the key, not to this host, so it is never offered for
        /// per-host storage — it would be stored under the wrong identity and reused for the wrong
        /// key the moment either changed.
        public var canOfferKeychain: Bool { prompt.kind == .password }
    }

    /// What a window is showing: enough to act on it without knowing which window asked.
    public struct Scope: Equatable, Sendable {
        public var hostId: String?
        public var sessionId: String?
        public var windowId: String?
        public var paneId: String?

        public init(hostId: String? = nil, sessionId: String? = nil, windowId: String? = nil, paneId: String? = nil) {
            self.hostId = hostId
            self.sessionId = sessionId
            self.windowId = windowId
            self.paneId = paneId
        }
    }

    /// `directory` is Application Support unless something says otherwise.
    ///
    /// Injectable because the model writes three files as a side effect of ordinary operations —
    /// rebinding a chord persists, selecting a session schedules a workspace save — and a test that
    /// exercised either used to write the *user's* `settings.json` and `workspace.json`. That was
    /// found by running the app after the suite and finding somebody else's keymap in it.
    public init(directory: URL? = nil) {
        store = HostConfigStore(directory: directory)
        workspace = WorkspaceStore(directory: directory)
        settings = SettingsStore(directory: directory)
    }

    // MARK: - Windows and scope

    /// What the frontmost window is showing, and therefore what every menu command acts on.
    ///
    /// Menus are application-wide, so ⌘T with any window in front has to open a tab in *that*
    /// window's session. Every window publishes here when it becomes key — including the main one,
    /// which used to be an implicit default that the others had to override by setting a
    /// `frontmostScope` and clearing it again. With several main windows that special case stops
    /// making sense: there is no "the" main window to fall back to.
    ///
    /// Never cleared. A menu can be used while no window is key (the menu bar itself takes focus),
    /// and the last window to have focus is a far better answer there than nothing.
    public var activeScope = Scope()

    /// The window a menu command that opens a *sheet* should open it in.
    ///
    /// `activeScope` says what to act on; this says where to ask. Weak, because the model outlives
    /// every window and a closed window must not be kept alive by having once been key. Untracked
    /// because nothing observes it — it is read at the moment a menu item fires.
    @ObservationIgnored public weak var activeWindowState: WindowState?

    /// Called by a window as it becomes key.
    public func focus(_ state: WindowState) {
        activeWindowState = state
        activeScope = state.scope(in: hosts)
        focusOrder.removeAll { $0 == state.id }
        focusOrder.append(state.id)
        syncDisplayedSessions()
    }

    /// Tells the service which sessions are on screen, so it can keep a tmux client attached to each.
    ///
    /// This replaced moving one client around as the user changed windows. A tmux client is attached
    /// to exactly one session and `%output` arrives only for that session, so with a single client
    /// every window on a different session of the same host was a still frame — and making one live
    /// necessarily froze another. What is on screen is a property of all the windows together, not of
    /// whichever is key, so this is recomputed from `openWindows` whenever any of it can have changed:
    /// focus, selection, a window opening or closing, and each topology snapshot (a session only
    /// becomes attachable once tmux has named it).
    public func syncDisplayedSessions() {
        let displayed = displayedSessions
        guard displayed != lastDisplayedSessions else { return }
        lastDisplayedSessions = displayed
        Task { await service.setDisplayedSessions(displayed) }
    }

    /// What every open window is showing, collapsed to a set of sessions per host.
    ///
    /// A set, so two windows on one session ask for one client rather than two: a second client on
    /// the same session would stream the same panes a second time for no benefit. Non-private
    /// because it is the whole decision, and it needs no windows on screen to be asserted.
    var displayedSessions: [String: Set<String>] {
        var displayed: [String: Set<String>] = [:]
        for window in openWindows {
            guard let hostId = window.selectedHostId, let sessionId = window.selectedSessionId else { continue }
            displayed[hostId, default: []].insert(sessionId)
        }
        return displayed
    }

    /// What was last sent, so a redundant call does not cost an actor hop on every keystroke that
    /// happens to run through `focus`.
    @ObservationIgnored private var lastDisplayedSessions: [String: Set<String>] = [:]

    /// Called by each window as it appears and disappears.
    public func registerWindow(_ state: WindowState) {
        windowsById[state.id] = WeakWindow(state)
        guard !windowOrder.contains(state.id) else { return }
        windowOrder.append(state.id)
        focusOrder.append(state.id)
        syncDisplayedSessions()
        // The next window of a restored workspace, if there is one left to open.
        openNextRestoredWindow()
        scheduleWorkspaceSave()
    }

    public func unregisterWindow(_ id: UUID) {
        // Before the window leaves the registry, while it can still be asked what it was showing.
        // Closing one window of several is a deliberate change to the workspace and the file has to
        // hear about it; the guard in `workspaceEntries` covers the case where it was the last one.
        let remaining = openWindows.filter { $0.id != id }.map { $0.workspaceEntry(in: hosts) }
        windowOrder.removeAll { $0 == id }
        focusOrder.removeAll { $0 == id }
        windowsById.removeValue(forKey: id)
        if activeWindowState?.id == id { activeWindowState = nil }
        // The session that window was showing may now be on no screen at all, and its client is one
        // nobody needs.
        syncDisplayedSessions()
        if !remaining.isEmpty {
            workspaceSaveTask?.cancel()
            Task { [workspace] in await workspace.save(remaining) }
        }
    }

    /// Every registered window that is still alive, in registration order.
    public var openWindows: [WindowState] {
        windowOrder.compactMap { windowsById[$0]?.state }
    }

    /// The window already showing a session, if one is.
    ///
    /// Most recently focused first, so with two windows on the same session the answer is the one the
    /// user was last in rather than whichever registered first.
    public func window(showing sessionId: String, on hostId: String) -> WindowState? {
        for id in focusOrder.reversed() {
            guard let state = windowsById[id]?.state else { continue }
            if state.selectedHostId == hostId && state.selectedSessionId == sessionId { return state }
        }
        return nil
    }

    /// The window to use when no particular one is called for: the most recently focused that is
    /// still open.
    public var lastUsedWindow: WindowState? {
        for id in focusOrder.reversed() {
            if let state = windowsById[id]?.state { return state }
        }
        return nil
    }

    /// Whether this window is the one that shows sheets nobody asked for — currently ssh prompts.
    ///
    /// The first registered window, so the choice is stable while windows come and go rather than
    /// following focus, which would move a sheet mid-typing.
    public func presentsHostLevelSheets(_ id: UUID) -> Bool {
        windowOrder.first == id
    }

    private func window(in scope: Scope) -> TmuxWindow? {
        guard let hostId = scope.hostId, let host = hosts.first(where: { $0.id == hostId }) else { return nil }
        guard let windowId = scope.windowId else {
            return host.sessions.first { $0.id == scope.sessionId }?.activeWindow
        }
        return host.window(windowId)
    }

    // MARK: - Lifecycle

    public func bootstrap() async {
        guard stateTask == nil else { return }

        // Before the monitor, which asks the keymap what the escape chord is.
        keymap = KeymapPolicy.applying(overrides: await settings.keymapOverrides())
        keyMonitor = KeyEventMonitor(model: self)

        // Read before the hosts, so the first window — which is already on screen by the time this
        // runs — can take its entry on the next snapshot rather than after the second one.
        restoreQueue = await workspace.load()
        // The window that ran `bootstrap` appeared before the file had been read, so its `onAppear`
        // found an empty queue and claimed nothing. Give it the first entry here and start the chain
        // that opens the rest. If it somehow has not registered yet, this does nothing and its own
        // `onAppear` takes the entry by the ordinary route — the chain starts either way.
        if let state = openWindows.first, state.pendingRestore == nil, let first = restoreQueue.first {
            restoreQueue.removeFirst()
            state.beginRestore(first)
            state.reconcile(with: hosts)
            openNextRestoredWindow()
        }

        stateTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in await self.service.stateStream() {
                self.apply(snapshot)
            }
        }

        for stored in await store.loadHosts() {
            await service.addHost(stored.asConfig)
            // The local server is always reachable, needs no credentials and cannot prompt for
            // anything, so leaving it behind a click is a step with no decision in it. Remote hosts
            // still wait to be asked: connecting one can raise a password sheet, and raising several
            // unbidden at launch is worse than a click.
            if stored.isLocal { connect(stored.id) }
        }

        // F4.18 — wake and network-path changes drive reconnection directly rather than waiting
        // for a timeout to notice.
        networkMonitor = NetworkStateMonitor { [service] in
            Task { await service.probeAllConnections() }
        }
    }

    /// Selection reconciliation lives on `WindowState` now, one copy per window; each window runs it
    /// itself when `hosts` changes.
    private func apply(_ snapshot: [HostState]) {
        hosts = snapshot
        respondToAuthenticationPrompts(in: snapshot)
        resolveReveals()
        // Restoration is resolved here rather than only in each window's `onChange`, because a
        // window's session becoming attachable and the window learning about it have to happen in
        // that order: `syncDisplayedSessions` below reads the selections, and a SwiftUI `onChange` is
        // not guaranteed to have run by then. Without this a restored session got no tmux client
        // until something unrelated changed the topology again — panes on screen and frozen.
        for window in openWindows where window.pendingRestore != nil {
            window.resolveRestore(with: snapshot)
        }
        // A window can be pointed at a session before tmux has told us it exists — creating one, or
        // reconnecting — and a session can only be attached to by id once it does. Every snapshot is
        // therefore a chance for a displayed session to become attachable.
        syncDisplayedSessions()
        scheduleWorkspaceSave()
    }

    // MARK: - Workspace (§4.3 — view state, never session contents)

    /// Saved windows not yet handed to a window, in the order they were written.
    @ObservationIgnored private var restoreQueue: [WorkspaceWindow] = []
    @ObservationIgnored private var workspaceSaveTask: Task<Void, Never>?

    /// Taken by each window as it appears, oldest first.
    public func consumeRestore() -> WorkspaceWindow? {
        restoreQueue.isEmpty ? nil : restoreQueue.removeFirst()
    }

    /// Asks for one more window while the queue is not empty.
    ///
    /// One at a time rather than all at once: `requestedWindow` holds a single request and every open
    /// window observes it, so N requests in a row would be claimed by whichever window reacted first
    /// and the rest would be lost. Each restored window asks for the next as it registers, which
    /// terminates when the queue drains.
    private func openNextRestoredWindow() {
        guard !restoreQueue.isEmpty else { return }
        openWindow(WindowSeed())
    }

    /// Records the workspace shortly after it changes.
    ///
    /// Debounced because the things that move it — focus, selection, a topology snapshot — arrive in
    /// bursts, and each one would otherwise be a file write. The delay is short enough that a crash
    /// loses at most the last selection, which is the same thing a crash loses anyway.
    public func scheduleWorkspaceSave() {
        workspaceSaveTask?.cancel()
        workspaceSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let entries = self.workspaceEntries()
            await self.workspace.save(entries)
        }
    }

    /// Every open window's place in the tree, in registration order.
    ///
    /// Empty is never written: the app deliberately outlives its last window
    /// (`applicationShouldTerminateAfterLastWindowClosed` is false), so closing them all and quitting
    /// from the menu bar would otherwise erase a workspace the user never meant to discard.
    func workspaceEntries() -> [WorkspaceWindow] {
        openWindows.map { $0.workspaceEntry(in: hosts) }
    }

    /// The synchronous save for ⌘Q. See `WorkspaceStore.saveNow`.
    public func saveWorkspaceNow() {
        let entries = workspaceEntries()
        guard !entries.isEmpty else { return }
        WorkspaceStore.saveNow(entries)
    }

    // MARK: - Authentication

    /// Answers ssh prompts from the Keychain where possible, and puts the rest in front of the user.
    ///
    /// ssh asks on a pty nobody is looking at, so an unanswered prompt is indistinguishable from a
    /// host that hangs while connecting. Every prompt is therefore either filled or shown.
    private func respondToAuthenticationPrompts(in snapshot: [HostState]) {
        // Forget prompts that are gone, so a host prompting again later is not ignored as handled.
        let live = Set(snapshot.compactMap { $0.authenticationPrompt?.id })
        handledPrompts.formIntersection(live)

        for host in snapshot {
            guard let prompt = host.authenticationPrompt, !handledPrompts.contains(prompt.id) else { continue }
            handledPrompts.insert(prompt.id)

            // A stored password can only answer a password prompt, and only when the user asked us to
            // keep one for this host.
            guard prompt.kind == .password, host.config.storesPasswordInKeychain else {
                pendingAuthentication = PendingAuthentication(
                    hostId: host.id, hostName: host.config.name, prompt: prompt
                )
                continue
            }

            Task { [service, config = host.config, hostId = host.id] in
                if let stored = await KeychainStore.password(for: config) {
                    await service.answerAuthenticationPrompt(hostId: hostId, secret: stored)
                } else {
                    // The flag said there was one and there is not — the user deleted it in Keychain
                    // Access, or this is a fresh machine. Ask rather than silently stalling.
                    self.pendingAuthentication = PendingAuthentication(
                        hostId: hostId, hostName: config.name, prompt: prompt
                    )
                }
            }
        }
    }

    /// Sends the secret the user typed, and stores it only if they asked.
    public func submitAuthentication(secret: String, saveInKeychain: Bool) {
        guard let pending = pendingAuthentication else { return }
        pendingAuthentication = nil
        guard !secret.isEmpty else {
            Task { await service.cancelAuthenticationPrompt(hostId: pending.hostId) }
            return
        }

        Task { [service] in
            await service.answerAuthenticationPrompt(hostId: pending.hostId, secret: secret)

            guard saveInKeychain, pending.canOfferKeychain,
                  let host = hosts.first(where: { $0.id == pending.hostId }) else { return }
            await KeychainStore.save(secret, for: host.config)
            // Record the *intent* to use the Keychain, never the secret (§2.5).
            var stored = host.config.asStoredHost
            stored.usesPassword = true
            stored.storesPasswordInKeychain = true
            await persist(stored)
        }
    }

    public func cancelAuthentication() {
        guard let pending = pendingAuthentication else { return }
        pendingAuthentication = nil
        Task { await service.cancelAuthenticationPrompt(hostId: pending.hostId) }
    }

    // MARK: - Actions

    public func connect(_ hostId: String) {
        Task { try? await service.connectHost(hostId: hostId) }
    }

    /// An explicit reconnect. Distinct from `connect` in that it clears the circuit breaker: a host
    /// that has already spent its automatic attempts must still come back on a click.
    public func reconnect(_ hostId: String) {
        Task { await service.reconnectNow(hostId: hostId) }
    }

    public func disconnect(_ hostId: String) {
        Task { await service.disconnectHost(hostId: hostId) }
    }

    /// F4.11 — let go of this client without ending the session or the host.
    public func detachThisClient(_ hostId: String) {
        Task { await service.detachThisClient(hostId: hostId) }
    }

    /// §7 — the user has read the refusal.
    public func dismissCommandFailure(_ hostId: String) {
        Task { await service.dismissCommandFailure(hostId: hostId) }
    }

    /// Points one window at a host/session/window, and moves the tmux client if it has to.
    ///
    /// Scoped to a window rather than the model: this is the other half of item 15 — a click in one
    /// window's sidebar used to change what *every* window was showing, because there was only one
    /// selection to change.
    ///
    /// `switchSession` is still application-wide, and unavoidably so: one channel per host attaches to
    /// one session, so two windows on two sessions of the same host cannot both be live. The window
    /// that asked wins, and the other says it is showing a snapshot.
    public func select(
        in state: WindowState,
        host hostId: String,
        session sessionId: String?,
        window windowId: String?
    ) {
        state.selectedHostId = hostId
        state.selectedSessionId = sessionId
        state.selectedWindowId = windowId
        state.focusedPaneId = nil
        // The user has said where this window belongs, which outranks where it was last time. A
        // restore left pending would otherwise move the window again the moment its host connected.
        state.pendingRestore = nil
        activeScope = state.scope(in: hosts)
        scheduleWorkspaceSave()
        // What this window shows has changed, so the set of sessions needing a client has too. It no
        // longer moves the one client to the newly selected session — that is what made every other
        // window a still frame, and it is why picking a session used to show the not-attached banner
        // for the moment between the click and tmux answering `switch-client`.
        syncDisplayedSessions()

        Task {
            if let windowId {
                await service.selectWindow(hostId: hostId, windowId: windowId)
            }
        }
    }

    // MARK: - Hosts

    /// The editor opens in the window that asked for it, and only there — the whole of item 13.
    public func presentNewHost(in state: WindowState) {
        state.hostDraft = HostDraft(isNew: true, host: StoredHost(id: "", name: ""))
    }

    public func presentEditHost(_ hostId: String, in state: WindowState) {
        guard let host = hosts.first(where: { $0.id == hostId }) else { return }
        state.hostDraft = HostDraft(isNew: false, host: host.config.asStoredHost)
    }

    /// Saves a host from the editor.
    ///
    /// `password` is non-nil only when the user typed one just now. An empty password with
    /// `savePassword` still set means "keep what is already in the Keychain", which is what an edit of
    /// some *other* field looks like.
    public func saveHost(_ draft: HostDraft, password: String?, savePassword: Bool, in state: WindowState) {
        var host = draft.host
        host.name = host.name.trimmingCharacters(in: .whitespaces)
        guard !host.name.isEmpty else { return }
        // A host added in-app gets a stable id derived from its name, so re-adding the same host edits
        // it instead of accumulating duplicates. Discovered `ssh-` ids and `local` keep theirs.
        if host.id.isEmpty {
            host.id = "custom-\(host.name)"
        }
        host.forwards = host.forwards.filter(\.isValid)

        let typed = password.flatMap { $0.isEmpty ? nil : $0 }
        host.storesPasswordInKeychain = savePassword && (typed != nil || draft.host.storesPasswordInKeychain)
        if host.storesPasswordInKeychain {
            host.usesPassword = true
        }

        state.hostDraft = nil
        Task { [service] in
            if let typed, savePassword {
                await KeychainStore.save(typed, for: host.asConfig)
            } else if !savePassword, draft.host.storesPasswordInKeychain {
                // Turning storage off deletes the secret rather than merely forgetting the flag.
                await KeychainStore.delete(for: draft.host.asConfig)
            }
            await persist(host)
            await service.addHost(host.asConfig)
        }
    }

    /// Writes one host into `hosts.json`, replacing any entry with the same id.
    private func persist(_ host: StoredHost) async {
        var stored = await store.loadHosts()
        stored.removeAll { $0.id == host.id }
        stored.append(host)
        try? await store.saveHosts(stored)
    }

    public func removeHost(_ hostId: String) {
        let config = hosts.first { $0.id == hostId }?.config
        Task {
            await service.removeHost(hostId: hostId)
            var stored = await store.loadHosts()
            stored.removeAll { $0.id == hostId }
            try? await store.saveHosts(stored)
            // Removing a host removes its secret. Leaving an orphaned Keychain item behind would be a
            // credential the user believes they deleted.
            if let config, config.storesPasswordInKeychain {
                await KeychainStore.delete(for: config)
            }
        }
    }

    // MARK: - Window and pane commands
    //
    // All of these act on `activeScope`, which is the frontmost window's subject — the sidebar
    // selection when that is the main window, and the torn-off window's own when it is not.

    public func newWindow() {
        let scope = activeScope
        guard let hostId = scope.hostId, let sessionId = scope.sessionId else { return }
        newWindow(hostId: hostId, sessionId: sessionId)
    }

    /// A window in a named session rather than in the frontmost one — what the sidebar's `+` means,
    /// where the row under the pointer says which session is intended (item 3).
    public func newWindow(hostId: String, sessionId: String, revealIn state: WindowState? = nil) {
        if let target = state ?? activeWindowState {
            let existing = hosts.first { $0.id == hostId }?
                .sessions.first { $0.id == sessionId }?
                .windows.map(\.id) ?? []
            pendingReveals.append(RevealRequest(
                state: target, opensNewWindow: false, hostId: hostId, sessionName: nil,
                sessionId: sessionId, knownWindowIds: Set(existing), madeAt: .now
            ))
        }
        Task { await service.newWindow(hostId: hostId, sessionId: sessionId) }
    }

    public func split(leftRight: Bool) {
        let scope = activeScope
        guard let hostId = scope.hostId,
              let paneId = scope.paneId ?? window(in: scope)?.preferredPaneId else { return }
        Task { await service.splitPane(hostId: hostId, paneId: paneId, leftRight: leftRight) }
    }

    /// F4.10 — the confirmation names the window, its pane count, and what is running in it.
    private func closeRequest(hostId: String, window: TmuxWindow) -> PendingClose {
        PendingClose(
            hostId: hostId,
            windowId: window.id,
            windowName: window.name,
            paneCount: window.paneCount,
            runningCommands: window.panes.map(\.command).filter { !$0.isEmpty }
        )
    }

    // Menu entry points. A menu is application-wide and has no window of its own, so these target the
    // window that is key — `activeScope` for what to act on, `activeWindowState` for where to ask.

    public func requestCloseWindowFromMenu() {
        guard let state = activeWindowState else { return }
        requestCloseWindow(in: state)
    }

    public func requestRenameWindowFromMenu() {
        guard let state = activeWindowState else { return }
        requestRenameWindow(in: state)
    }

    public func requestRenameSessionFromMenu() {
        guard let state = activeWindowState else { return }
        requestRenameSession(in: state)
    }

    public func toggleLauncherFromMenu() {
        guard let state = activeWindowState else { return }
        state.isLauncherPresented.toggle()
    }

    /// F4.30 — a session picked from the menu bar extra, which belongs to no window at all.
    ///
    /// Shows it in the window that was last key. That is deliberately not the same as "any window
    /// already showing this session": routing to *that* window is item 9 on the list and needs the
    /// registry to know what each window is displaying, which it does not yet.
    public func selectFromMenuBar(host hostId: String, session sessionId: String?, window windowId: String?) {
        guard let state = activeWindowState else { return }
        select(in: state, host: hostId, session: sessionId, window: windowId)
    }

    /// Closes the frontmost window's tmux window, raising the confirmation in `state` if one is needed.
    ///
    /// `skippingConfirmation` is ⌥ held at the moment of the click. The confirmation exists because
    /// closing the last link of a window kills what is running in it and the user cannot be assumed
    /// to know that (F4.10); holding ⌥ *is* saying so, which is what the modifier means on a
    /// destructive control everywhere else in macOS. It suppresses the question and nothing else —
    /// the F4.9 unlink path below never asked in the first place, and there is still no persistent
    /// "don't ask again", so the assertion has to be made again for every window.
    public func requestCloseWindow(in state: WindowState, skippingConfirmation: Bool = false) {
        let scope = activeScope
        guard let hostId = scope.hostId, let window = window(in: scope) else { return }
        guard let pending = closeWindow(hostId: hostId, window: window) else { return }
        if skippingConfirmation {
            killWindow(hostId: pending.hostId, windowId: pending.windowId)
        } else {
            state.pendingClose = pending
        }
    }

    /// F4.9 — closing a tab unlinks the window. It never ends what is running in it.
    ///
    /// A window linked to more than one session simply leaves this one and carries on in the others,
    /// which is what closing a tab ought to mean and exactly what `unlink-window` does. tmux has no
    /// equivalent for a window in a single session: removing it there *is* destroying it, and
    /// `unlink-window` refuses outright ("window only linked to one session"). So that case stops and
    /// asks (F4.10) instead of quietly killing a shell the user only meant to put away — the close
    /// action itself still never kills, and the kill only happens on an informed confirmation.
    ///
    /// Returns the confirmation to present, or `nil` when the window was simply unlinked and there is
    /// nothing to ask. The caller owns the sheet: a detached window keeps its own, because a sheet
    /// bound to shared state presents itself in every open window at once.
    public func closeWindow(hostId: String, window: TmuxWindow) -> PendingClose? {
        guard linkedSessionCount(hostId: hostId, windowId: window.id) > 1 else {
            return closeRequest(hostId: hostId, window: window)
        }
        Task { await service.unlinkWindow(hostId: hostId, windowId: window.id) }
        return nil
    }

    /// How many of the host's sessions this window is linked to. `list-windows -a` reports a linked
    /// window once per session, so the model already carries it in each one.
    private func linkedSessionCount(hostId: String, windowId: String) -> Int {
        guard let host = hosts.first(where: { $0.id == hostId }) else { return 0 }
        return host.sessions.count { session in session.windows.contains { $0.id == windowId } }
    }

    /// Only ever reached from the confirmation above, which is the single place a window is killed.
    public func confirmCloseWindow(in state: WindowState) {
        guard let pending = state.pendingClose else { return }
        state.pendingClose = nil
        Task { await service.killWindow(hostId: pending.hostId, windowId: pending.windowId) }
    }

    // MARK: - Renaming (F4.11)

    /// Builds a rename request for a specific window, or for the frontmost one when not given.
    public func renameRequest(hostId: String, window: TmuxWindow) -> PendingRename {
        PendingRename(hostId: hostId, subject: .window(window.id), currentName: window.name)
    }

    public func renameRequest(hostId: String, session: TmuxSession) -> PendingRename {
        PendingRename(hostId: hostId, subject: .session(session.id), currentName: session.name)
    }

    public func requestRenameWindow(in state: WindowState, hostId: String? = nil, windowId: String? = nil) {
        let scope = activeScope
        guard let hostId = hostId ?? scope.hostId else { return }
        guard let window = windowId.flatMap({ id in hosts.first { $0.id == hostId }?.window(id) })
            ?? self.window(in: scope) else { return }
        state.pendingRename = renameRequest(hostId: hostId, window: window)
    }

    public func requestRenameSession(in state: WindowState, hostId: String? = nil, sessionId: String? = nil) {
        let scope = activeScope
        guard let hostId = hostId ?? scope.hostId, let host = hosts.first(where: { $0.id == hostId }) else { return }
        guard let session = (sessionId ?? scope.sessionId).flatMap({ id in host.sessions.first { $0.id == id } })
            ?? host.activeSession else { return }
        state.pendingRename = renameRequest(hostId: hostId, session: session)
    }

    /// Sends the rename. The name in the tree updates when tmux answers with
    /// `%session-renamed`/`%window-renamed`, not here — tmux is authoritative for its own model.
    ///
    /// Takes the pending value rather than reading it back, so the window that presented the sheet is
    /// the one that clears it.
    public func commit(_ pending: PendingRename, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != pending.currentName else { return }

        Task { [service] in
            switch pending.subject {
            case .session(let sessionId):
                await service.renameSession(hostId: pending.hostId, sessionId: sessionId, newName: trimmed)
            case .window(let windowId):
                await service.renameWindow(hostId: pending.hostId, windowId: windowId, newName: trimmed)
            }
        }
    }

    public func closePane() {
        let scope = activeScope
        guard let hostId = scope.hostId, let paneId = scope.paneId else { return }
        Task { await service.killPane(hostId: hostId, paneId: paneId) }
    }

    // MARK: - Appearance

    /// ⌘+ / ⌘−. Every pane reflows, because the cell size comes from the font and the grid comes from
    /// the cell size — the views measure again and ask tmux for a new one (§3.3).
    public func adjustFontSize(by delta: CGFloat) {
        theme.fontSize = TerminalTheme.clampedFontSize(theme.fontSize + delta)
    }

    public func resetFontSize() {
        theme.fontSize = TerminalTheme.default.fontSize
    }

    /// Opens SwiftTerm's find bar on the focused pane.
    ///
    /// It is driven through AppKit's text-finder responder chain — `showFindBar` is private in
    /// SwiftTerm and reachable only this way — so the message goes to the first responder, which is
    /// the focused `TerminalView`. The tag is `NSTextFinder.Action.showFindInterface`, which is what
    /// the standard Find menu item carries.
    public func showFindBar() {
        let item = NSMenuItem(title: ApplicationShortcut.find.title, action: nil, keyEquivalent: "")
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
    }

    /// `prefix z`, as a menu command. tmux answers with the new visible layout and the model takes
    /// the zoom from that, so nothing is tracked here.
    public func toggleZoom() {
        let scope = activeScope
        guard let hostId = scope.hostId, let paneId = scope.paneId else { return }
        Task { await service.toggleZoom(hostId: hostId, paneId: paneId) }
    }

    /// Moves the focused pane within the current window, in layout order and wrapping.
    ///
    /// Layout order rather than geometry: it is what tmux's own `select-pane -t :.+` does, it matches
    /// the order the sidebar lists panes in, and it cannot get stuck the way a directional walk can
    /// in an uneven split.
    public func focusAdjacentPane(offset: Int) {
        let scope = activeScope
        guard let state = activeWindowState,
              let window = hosts.first(where: { $0.id == scope.hostId })?
                  .sessions.first(where: { $0.id == scope.sessionId })?
                  .windows.first(where: { $0.id == scope.windowId })
        else { return }

        // The rendered tree, so that while a pane is zoomed the cycle is over what is on screen.
        let ids = window.renderTree?.paneIds ?? window.panes.map(\.id)
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex(of: scope.paneId ?? "") ?? 0
        let next = ids[(current + offset % ids.count + ids.count) % ids.count]
        state.focusedPaneId = next
        activeScope.paneId = next
        // tmux tracks its own active pane, and a rename or a new split resolves against it.
        if let hostId = scope.hostId {
            Task { await service.selectPane(hostId: hostId, paneId: next) }
        }
    }

    /// Moves to the next or previous tmux window of the current session, wrapping.
    public func selectAdjacentWindow(offset: Int) {
        let scope = activeScope
        guard let state = activeWindowState,
              let session = hosts.first(where: { $0.id == scope.hostId })?
                  .sessions.first(where: { $0.id == scope.sessionId })
        else { return }

        let ids = session.windows.map(\.id)
        guard !ids.isEmpty, let hostId = scope.hostId else { return }
        let current = ids.firstIndex(of: scope.windowId ?? "") ?? 0
        let next = ids[(current + offset % ids.count + ids.count) % ids.count]
        select(in: state, host: hostId, session: scope.sessionId, window: next)
    }

    public func killWindow(hostId: String, windowId: String) {
        Task { await service.killWindow(hostId: hostId, windowId: windowId) }
    }

    // MARK: - Window ordering

    /// A tab dropped onto another tab, in the form `SessionService.moveWindow` takes.
    ///
    /// The rule is the one every tab bar has: the dragged tab takes the position of the tab it was
    /// dropped on, and everything between them shifts up by one. Which side of the target that lands
    /// on therefore depends on the direction of travel — dragging rightwards means *after* the
    /// target, leftwards means *before* it — and getting that wrong makes a rightward drag by one
    /// position do nothing at all, which reads as the whole feature being broken.
    ///
    /// Returns the window to insert in front of, `nil` for the end of the strip, and `.none` for a
    /// drop that is not a move. Static and pure because the arithmetic is the whole of it: the tmux
    /// side is one command, and this is the part that can be wrong without anything saying so.
    static func dropDestination(order: [String], dragged: String, onto target: String) -> String?? {
        guard dragged != target,
              let from = order.firstIndex(of: dragged),
              let onto = order.firstIndex(of: target) else { return .none }

        var remaining = order
        remaining.remove(at: from)
        guard let targetIndex = remaining.firstIndex(of: target) else { return .none }
        // Rightwards: land after the target, which is the window currently following it — or the end
        // of the strip when the target is last. Leftwards: land on the target itself.
        let insertAt = from < onto ? targetIndex + 1 : targetIndex
        return .some(insertAt < remaining.count ? remaining[insertAt] : nil)
    }

    /// Reorders a tab that was dragged onto another one.
    public func moveWindow(hostId: String, sessionId: String, dragged: String, onto target: String) {
        guard let session = hosts.first(where: { $0.id == hostId })?
            .sessions.first(where: { $0.id == sessionId }) else { return }
        guard let before = Self.dropDestination(
            order: session.windows.map(\.id), dragged: dragged, onto: target
        ) else { return }
        Task {
            await service.moveWindow(
                hostId: hostId, sessionId: sessionId, windowId: dragged, before: before
            )
        }
    }

    /// Moves a window out of this session and into another one on the same host.
    ///
    /// Not a close and not a kill: the window and everything running in it carries on, one level of
    /// the tree over. It is the only way to undo having created a window in the wrong session, which
    /// until now meant killing it and starting again.
    public func moveWindowToSession(hostId: String, windowId: String, from: String, to: String) {
        Task { await service.moveWindow(hostId: hostId, windowId: windowId, fromSession: from, toSession: to) }
    }

    /// Links a window into a second session, leaving it in this one.
    ///
    /// The inverse of the unlink behind ⇧⌘W (F4.9), and what makes that path reachable: a window
    /// linked to one session cannot be closed without being killed, so a window that matters in two
    /// places should be in both rather than copied by hand.
    public func linkWindowToSession(hostId: String, windowId: String, to sessionId: String) {
        Task { await service.linkWindow(hostId: hostId, windowId: windowId, toSession: sessionId) }
    }

    /// The other sessions of a host, for the two submenus above. Empty when there is nowhere to go,
    /// which is what the menus check rather than offering a submenu with nothing in it.
    public func otherSessions(hostId: String, excluding sessionId: String) -> [TmuxSession] {
        hosts.first { $0.id == hostId }?.sessions.filter { $0.id != sessionId } ?? []
    }

    public func killSession(hostId: String, sessionId: String) {
        Task { await service.killSession(hostId: hostId, sessionId: sessionId) }
    }

    /// Item 3 — raises the confirmation for killing a session.
    ///
    /// Unlike closing a tab (F4.9) there is no non-destructive reading of this: tmux has no "unlink
    /// session", so every window in it and everything running in those windows ends. The confirmation
    /// names what is about to be lost, and there is no way to turn it off.
    /// `skippingConfirmation` is ⌥ at the moment of the click — see `requestCloseWindow`.
    public func requestKillSession(
        in state: WindowState,
        hostId: String,
        sessionId: String,
        skippingConfirmation: Bool = false
    ) {
        guard let host = hosts.first(where: { $0.id == hostId }),
              let session = host.sessions.first(where: { $0.id == sessionId }) else { return }
        guard !skippingConfirmation else {
            killSession(hostId: hostId, sessionId: sessionId)
            return
        }
        state.pendingKillSession = PendingKillSession(
            hostId: hostId,
            sessionId: sessionId,
            sessionName: session.name,
            windowCount: session.windows.count,
            runningCommands: session.windows
                .flatMap { $0.panes.map(\.command) }
                .filter { !$0.isEmpty }
        )
    }

    public func confirmKillSession(in state: WindowState) {
        guard let pending = state.pendingKillSession else { return }
        state.pendingKillSession = nil
        killSession(hostId: pending.hostId, sessionId: pending.sessionId)
    }

    // MARK: - Showing what was just created
    //
    // Creating is asynchronous and answers with nothing useful: control mode's `new-session` and
    // `new-window` return no id, and the thing created only becomes selectable when the topology
    // refresh brings it back a round trip later. So the intent is recorded here and satisfied on the
    // next snapshot — which is what makes "create" mean "create and show me" rather than "create, and
    // find it yourself".

    private struct RevealRequest {
        /// The window that asked. Weak: if it has closed there is nobody to show anything to.
        weak var state: WindowState?
        /// ⌥ from the menu bar — the session belongs in a window of its own, which cannot be opened
        /// at the moment of asking because the seed needs ids tmux has not allocated yet.
        let opensNewWindow: Bool
        let hostId: String
        /// A session we created, by name. tmux allocates the `$id`, so the name is all we know.
        let sessionName: String?
        /// A session we created a *window* in.
        let sessionId: String?
        /// The windows that existed when we asked, so the new one can be told from its siblings.
        let knownWindowIds: Set<String>
        let madeAt: Date
    }

    @ObservationIgnored private var pendingReveals: [RevealRequest] = []

    /// Sessions the tree should open, by `hostId|sessionId`.
    ///
    /// A session or window made by a click is already in front of the user; listing it collapsed asks
    /// them to expand something they just created.
    public private(set) var sessionsToExpand: Set<String> = []

    /// Consumed, so a session the user deliberately collapses afterwards does not spring open again.
    public func takeSessionExpansion(hostId: String, sessionId: String) -> Bool {
        sessionsToExpand.remove("\(hostId)|\(sessionId)") != nil
    }

    /// The resolution step, reachable without a channel. Reveals are resolved from a topology snapshot
    /// and nothing else, which is exactly the part worth asserting.
    func resolveRevealsForTesting() { resolveReveals() }

    private func resolveReveals() {
        guard !pendingReveals.isEmpty else { return }
        var unresolved: [RevealRequest] = []

        for request in pendingReveals {
            guard request.opensNewWindow || request.state != nil else { continue }
            guard let host = hosts.first(where: { $0.id == request.hostId }) else {
                unresolved.append(request)
                continue
            }

            let session: TmuxSession?
            let window: TmuxWindow?
            if let name = request.sessionName {
                session = host.sessions.first { $0.name == name }
                window = session?.activeWindow ?? session?.windows.first
            } else if let sessionId = request.sessionId {
                session = host.sessions.first { $0.id == sessionId }
                // The one that was not there before, rather than whichever tmux made active — a
                // window opened elsewhere in the meantime must not steal this selection.
                window = session?.windows.first { !request.knownWindowIds.contains($0.id) }
            } else {
                continue
            }

            guard let session, let window else {
                unresolved.append(request)
                continue
            }
            if request.opensNewWindow {
                openWindow(WindowSeed(
                    hostId: host.id, sessionId: session.id, windowId: window.id, collapseSidebar: true
                ))
            } else if let state = request.state {
                select(in: state, host: host.id, session: session.id, window: window.id)
            }
            sessionsToExpand.insert("\(host.id)|\(session.id)")
        }

        // Give up on anything the server never confirmed. A request kept indefinitely would eventually
        // match some unrelated session of the same name and move the user's window without warning.
        pendingReveals = unresolved.filter { Date().timeIntervalSince($0.madeAt) < 15 }
    }

    /// `preferNewWindow` is the menu bar's ⌥: the session gets a macOS window of its own instead of
    /// retargeting `state`. It cannot simply call `openWindow` here — control mode's `new-session`
    /// answers with no id, so there is nothing to seed a window with until the topology comes back.
    /// The request carries the intent instead, and `resolveReveals` opens the window once it can say
    /// what the window should show.
    public func createSession(
        hostId: String,
        name: String,
        revealIn state: WindowState? = nil,
        preferNewWindow: Bool = false
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Nothing to reveal *in* means the reveal has to bring its own window. That is the menu bar's
        // ordinary New Session once the last window has been closed: without this the session is
        // created on the server and nobody is ever shown it.
        let opensNewWindow = preferNewWindow || (state == nil && openWindows.isEmpty)
        if state != nil || opensNewWindow {
            pendingReveals.append(RevealRequest(
                state: opensNewWindow ? nil : state, opensNewWindow: opensNewWindow,
                hostId: hostId, sessionName: trimmed, sessionId: nil,
                knownWindowIds: [], madeAt: .now
            ))
        }
        let host = hosts.first { $0.id == hostId }
        // The host's start directory, if it has one. Only on the `new-session` path: the other branch
        // connects the channel, and the session it attaches or creates is tmux's own `new-session -A`
        // inside the ssh command, which has nowhere to put a `-c` and no reason to — a host that is
        // not yet connected is being reached for the first time, not given a working directory.
        let startDirectory = host?.config.startDirectory
        Task {
            if host?.connectionState.isActive == true {
                await service.newSession(hostId: hostId, name: trimmed, startDirectory: startDirectory)
            } else {
                try? await service.connectHost(hostId: hostId, targetSession: trimmed)
            }
        }
    }

    /// Creates a session without asking for a name first.
    ///
    /// Naming a session is a decision almost nobody wants to make at the moment they want a shell, and
    /// a modal in the way of one is worse than a name that can be changed later — renaming is one
    /// double-click away in the sidebar. The index is the lowest that is free rather than a count, so
    /// closing `tetmux_2` and making another gives `tetmux_2` back instead of climbing forever.
    public func createSessionWithDefaultName(
        hostId: String,
        revealIn state: WindowState? = nil,
        preferNewWindow: Bool = false
    ) {
        createSession(
            hostId: hostId,
            name: defaultSessionName(hostId: hostId),
            // A window of its own means no window to fall back on: `activeWindowState` here would
            // retarget the frontmost window as well as opening the new one.
            revealIn: preferNewWindow ? nil : (state ?? activeWindowState),
            preferNewWindow: preferNewWindow
        )
    }

    /// `tetmux_1`, `tetmux_2`, … skipping any that the host already has.
    ///
    /// Non-private so the naming rule can be asserted without a channel: an off-by-one here collides
    /// with a live session, and tmux answers that with a refusal the user did not ask for.
    public func defaultSessionName(hostId: String) -> String {
        let taken = Set(hosts.first { $0.id == hostId }?.sessions.map(\.name) ?? [])
        var index = 1
        while taken.contains("\(Self.defaultSessionPrefix)\(index)") { index += 1 }
        return "\(Self.defaultSessionPrefix)\(index)"
    }

    static let defaultSessionPrefix = "tetmux_"

    public func pasteIntoFocusedPane() {
        let scope = activeScope
        guard let hostId = scope.hostId,
              let paneId = scope.paneId ?? window(in: scope)?.preferredPaneId,
              let text = NSPasteboard.general.string(forType: .string) else { return }
        Task { await service.paste(hostId: hostId, paneId: paneId, text: text) }
    }

    // MARK: - Opening windows

    /// A window the model has asked for but cannot itself open.
    ///
    /// `openWindow` is an `@Environment` action and neither `AppModel` nor `Commands` has an
    /// environment to read one from, so the request is recorded here and an open window performs it.
    public var requestedWindow: WindowSeed?

    /// Where the next window to appear should start. Consumed once, by the first window that asks.
    ///
    /// Handed over rather than passed as a scene value because `WindowGroup(id:for:)` keys its windows
    /// on that value: opening the same one twice brings the first forward instead of making a second,
    /// which is right for "show me this session" and wrong for ⌘N.
    @ObservationIgnored private var pendingSeed: WindowSeed?

    /// How to open a window when there is no window open to do it.
    ///
    /// `requestedWindow` is only ever observed from inside a window, so with every window closed
    /// nobody claims the request and it sits set for good — which is the whole of the menu bar
    /// extra's failure mode once the last window has gone: the session is switched to, or created,
    /// and nothing appears. `openWindow` is an `@Environment` action and so can only be read by a
    /// view; this is one captured from a view that has one. It outlives that view because it
    /// resolves against the scene graph rather than the window it was read in.
    @ObservationIgnored public var openAppWindow: (() -> Void)?

    /// A new window to navigate from, for callers outside SwiftUI — the Dock menu is built by AppKit
    /// and has no environment of its own to read `openWindow` from.
    ///
    /// Seeded to *show* the tree rather than left at `.automatic`. Reached from the Dock, which is
    /// where someone goes when they have no window in front of them, so the window that appears has
    /// to be one they can find their way around from — and `.automatic` is AppKit deciding, which is
    /// not the same as asking. The selection is deliberately left to `reconcile`: the first host and
    /// what it has active, which is the state the app starts in.
    public func openNewAppWindow() {
        openWindow(WindowSeed(sidebar: .shown))
    }

    /// Asks for a new window showing `seed`. The request is picked up by whichever window is on screen.
    public func openWindow(_ seed: WindowSeed) {
        pendingSeed = seed
        requestedWindow = seed
        // With nothing on screen to claim it, the request has to be performed here or not at all.
        // `claimWindowRequest` still runs, so the window that appears takes the seed by the ordinary
        // route and no later ⌘N inherits a request that was never picked up.
        if openWindows.isEmpty, let openAppWindow, claimWindowRequest() {
            openAppWindow()
        }
    }

    /// Claims the outstanding window request, if there is one. Returns whether the caller should open.
    ///
    /// Every open window observes `requestedWindow`, so every one of them reacts to a single request —
    /// with three windows open, "Open in New Window" would open three. Reading the *current* value here
    /// rather than the one the observation handed over is what makes the first claim win: the others
    /// find it already taken. Correct because the model is `@MainActor`, so these run one after another
    /// and never interleave.
    public func claimWindowRequest() -> Bool {
        guard requestedWindow != nil else { return false }
        requestedWindow = nil
        return true
    }

    /// Taken by a window as it appears, and gone afterwards so the next one starts clean.
    public func consumeSeed() -> WindowSeed? {
        defer { pendingSeed = nil }
        return pendingSeed
    }

    /// Shows a session somewhere sensible.
    ///
    /// The rule items 5, 9 and 10 share, in order:
    ///
    /// 1. A window already showing this session comes forward. Retargeting some *other* window to a
    ///    session that is already on screen would both surprise the user and throw away whatever that
    ///    window was showing.
    /// 2. `preferNewWindow` — Option-click from the menu bar, or an explicit "Open in New Window" —
    ///    opens one regardless.
    /// 3. Otherwise `fallback` is retargeted, if one was offered: the clicked window for item 5, the
    ///    last-used one for item 9.
    /// 4. Failing all that, a new window. Reached when every window has been closed and only the menu
    ///    bar extra is left, which is exactly when there is nothing to reuse.
    @discardableResult
    public func showSession(
        hostId: String,
        sessionId: String,
        windowId: String? = nil,
        collapseSidebar: Bool = false,
        preferNewWindow: Bool = false,
        fallback: WindowState? = nil
    ) -> WindowState? {
        if !preferNewWindow, let existing = window(showing: sessionId, on: hostId) {
            select(in: existing, host: hostId, session: sessionId, window: windowId ?? existing.selectedWindowId)
            existing.bringToFront()
            return existing
        }

        let target = preferNewWindow ? nil : (fallback ?? lastUsedWindow)
        if let target {
            select(in: target, host: hostId, session: sessionId, window: windowId ?? firstWindowId(hostId, sessionId))
            if collapseSidebar { target.sidebarVisibility = .detailOnly }
            target.bringToFront()
            return target
        }

        openWindow(WindowSeed(
            hostId: hostId,
            sessionId: sessionId,
            windowId: windowId ?? firstWindowId(hostId, sessionId),
            collapseSidebar: collapseSidebar
        ))
        return nil
    }

    private func firstWindowId(_ hostId: String, _ sessionId: String) -> String? {
        hosts.first { $0.id == hostId }?
            .sessions.first { $0.id == sessionId }?
            .windows.first?.id
    }

    /// F4.12 — opens the frontmost window's tmux window in a macOS window of its own.
    ///
    /// Item 12: an ordinary window with the tree collapsed, not the separate kind it used to be. That
    /// window had its own view, its own reduced feature set, and a button to turn itself into a real
    /// one — three things to maintain for a result the user wanted to be a normal window all along.
    public func detachActiveWindow() {
        let scope = activeScope
        guard let hostId = scope.hostId,
              let sessionId = scope.sessionId,
              let windowId = scope.windowId ?? window(in: scope)?.id else { return }
        openWindow(WindowSeed(
            hostId: hostId, sessionId: sessionId, windowId: windowId, collapseSidebar: true
        ))
    }


    /// F4.25 — one ranked list over hosts, sessions, and windows.
    ///
    /// Takes the window that opened the launcher, so picking a result navigates *that* window rather
    /// than every open one.
    public func launcherItems(for state: WindowState) -> [LauncherItem] {
        var items: [LauncherItem] = []
        for host in hosts {
            let reachable = host.connectionState.isActive
            items.append(LauncherItem(
                title: host.config.name,
                subtitle: host.config.isLocal ? "Local tmux" : "SSH host",
                iconName: host.config.isLocal ? "laptopcomputer" : "server.rack",
                isAvailable: true
            ) { [weak self, weak state] in
                guard let self, let state else { return }
                state.selectedHostId = host.id
                self.connect(host.id)
            })

            for session in host.sessions {
                for window in session.windows {
                    items.append(LauncherItem(
                        title: "\(window.name)",
                        subtitle: "\(host.config.name) › \(session.name)\(reachable ? "" : " (will connect)")",
                        iconName: "square.split.2x1",
                        isAvailable: reachable
                    ) { [weak self, weak state] in
                        guard let self, let state else { return }
                        self.select(in: state, host: host.id, session: session.id, window: window.id)
                    })
                }
            }
        }
        return items
    }
}
