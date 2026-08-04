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
    public let store = HostConfigStore()

    public var hosts: [HostState] = []
    public var theme = TerminalTheme.default
    public var keymap = KeymapPolicy.default

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

    public init() {}

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
        attachIfNeeded(state)
    }

    /// Moves the tmux client to whatever the newly focused window is showing.
    ///
    /// Only the attached session receives `%output`, and there is one channel per host, so a window
    /// showing any other session of that host is a still frame. Clicking into a window is already the
    /// user saying "I want to work here"; making them then notice a banner and press a button to make
    /// it live is asking twice.
    ///
    /// The cost is real and unavoidable: attaching here detaches there, so windows on another session
    /// of the same host go to snapshots. That is what the banner is left to say.
    private func attachIfNeeded(_ state: WindowState) {
        guard let hostId = state.selectedHostId,
              let sessionId = state.selectedSessionId,
              let host = hosts.first(where: { $0.id == hostId }),
              host.connectionState.isActive,
              host.activeSessionId != sessionId else { return }
        Task { await service.switchSession(hostId: hostId, sessionId: sessionId) }
    }

    /// Called by each window as it appears and disappears.
    public func registerWindow(_ state: WindowState) {
        windowsById[state.id] = WeakWindow(state)
        guard !windowOrder.contains(state.id) else { return }
        windowOrder.append(state.id)
        focusOrder.append(state.id)
    }

    public func unregisterWindow(_ id: UUID) {
        windowOrder.removeAll { $0 == id }
        focusOrder.removeAll { $0 == id }
        windowsById.removeValue(forKey: id)
        if activeWindowState?.id == id { activeWindowState = nil }
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

        stateTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in await self.service.stateStream() {
                self.apply(snapshot)
            }
        }

        for stored in await store.loadHosts() {
            await service.addHost(stored.asConfig)
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
        let isNewSession = sessionId != nil && sessionId != hosts.first { $0.id == hostId }?.activeSessionId
        state.selectedHostId = hostId
        state.selectedSessionId = sessionId
        state.selectedWindowId = windowId
        state.focusedPaneId = nil
        activeScope = state.scope(in: hosts)

        Task {
            // Moving the client comes first: tmux only streams output for the attached session.
            if isNewSession, let sessionId {
                await service.switchSession(hostId: hostId, sessionId: sessionId)
            }
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
    public func requestCloseWindow(in state: WindowState) {
        let scope = activeScope
        guard let hostId = scope.hostId, let window = window(in: scope) else { return }
        state.pendingClose = closeWindow(hostId: hostId, window: window)
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

    public func killWindow(hostId: String, windowId: String) {
        Task { await service.killWindow(hostId: hostId, windowId: windowId) }
    }

    public func killSession(hostId: String, sessionId: String) {
        Task { await service.killSession(hostId: hostId, sessionId: sessionId) }
    }

    /// Item 3 — raises the confirmation for killing a session.
    ///
    /// Unlike closing a tab (F4.9) there is no non-destructive reading of this: tmux has no "unlink
    /// session", so every window in it and everything running in those windows ends. The confirmation
    /// names what is about to be lost, and there is no way to turn it off.
    public func requestKillSession(in state: WindowState, hostId: String, sessionId: String) {
        guard let host = hosts.first(where: { $0.id == hostId }),
              let session = host.sessions.first(where: { $0.id == sessionId }) else { return }
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
        if state != nil || preferNewWindow {
            pendingReveals.append(RevealRequest(
                state: preferNewWindow ? nil : state, opensNewWindow: preferNewWindow,
                hostId: hostId, sessionName: trimmed, sessionId: nil,
                knownWindowIds: [], madeAt: .now
            ))
        }
        Task {
            if hosts.first(where: { $0.id == hostId })?.connectionState.isActive == true {
                await service.newSession(hostId: hostId, name: trimmed)
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

    /// Asks for a new window showing `seed`. The request is picked up by whichever window is on screen.
    public func openWindow(_ seed: WindowSeed) {
        pendingSeed = seed
        requestedWindow = seed
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
