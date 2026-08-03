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
    public var selectedHostId: String?
    public var selectedSessionId: String?
    public var selectedWindowId: String?
    public var focusedPaneId: String?
    public var theme = TerminalTheme.default
    public var keymap = KeymapPolicy.default

    public var isLauncherPresented = false
    public var newSessionTarget: String?
    /// The host being added or edited, if the editor is open.
    public var hostDraft: HostDraft?
    /// An ssh prompt waiting on the user, when it could not be answered from the Keychain.
    public var pendingAuthentication: PendingAuthentication?
    /// A window the user asked to close, pending confirmation (F4.10).
    public var pendingClose: PendingClose?
    /// A session or window the user asked to rename, pending the new name.
    public var pendingRename: PendingRename?

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

    // MARK: - Derived selection

    public var selectedHost: HostState? {
        hosts.first { $0.id == selectedHostId }
    }

    public var selectedSession: TmuxSession? {
        guard let host = selectedHost else { return nil }
        return host.sessions.first { $0.id == selectedSessionId } ?? host.activeSession
    }

    public var selectedWindow: TmuxWindow? {
        guard let session = selectedSession else { return nil }
        return session.windows.first { $0.id == selectedWindowId } ?? session.activeWindow
    }

    /// Set by a detached window while it is frontmost, and cleared by the main window when it takes
    /// focus again.
    ///
    /// Menu commands are application-wide, so ⌘T with a torn-off window in front has to open a window
    /// in the session *that* window is showing — not in whatever the sidebar happens to be pointing
    /// at. The main window is the default case and needs no scope of its own: its selection already is
    /// one.
    public var frontmostScope: Scope?

    /// The scope every command acts on.
    public var activeScope: Scope {
        frontmostScope ?? Scope(
            hostId: selectedHostId,
            sessionId: selectedSession?.id,
            windowId: selectedWindow?.id,
            paneId: focusedPaneId ?? selectedWindow?.preferredPaneId
        )
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

        if selectedHostId == nil {
            selectedHostId = hosts.first?.id
        }
    }

    private func apply(_ snapshot: [HostState]) {
        hosts = snapshot
        respondToAuthenticationPrompts(in: snapshot)

        if selectedHostId == nil || !snapshot.contains(where: { $0.id == selectedHostId }) {
            selectedHostId = snapshot.first?.id
        }
        guard let host = selectedHost else { return }

        if selectedSessionId == nil || !host.sessions.contains(where: { $0.id == selectedSessionId }) {
            selectedSessionId = host.activeSession?.id
        }
        guard let session = selectedSession else {
            selectedWindowId = nil
            focusedPaneId = nil
            return
        }
        if selectedWindowId == nil || !session.windows.contains(where: { $0.id == selectedWindowId }) {
            selectedWindowId = session.activeWindow?.id
        }
        // Keep the keyboard on a pane that still exists.
        if let window = selectedWindow {
            let ids = window.layoutTree?.paneIds ?? window.panes.map(\.id)
            if focusedPaneId == nil || !ids.contains(focusedPaneId!) {
                focusedPaneId = window.preferredPaneId
            }
        } else {
            focusedPaneId = nil
        }
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
        selectedHostId = hostId
        Task { try? await service.connectHost(hostId: hostId) }
    }

    /// An explicit reconnect. Distinct from `connect` in that it clears the circuit breaker: a host
    /// that has already spent its automatic attempts must still come back on a click.
    public func reconnect(_ hostId: String) {
        selectedHostId = hostId
        Task { await service.reconnectNow(hostId: hostId) }
    }

    public func disconnect(_ hostId: String) {
        Task { await service.disconnectHost(hostId: hostId) }
    }

    /// §7 — the user has read the refusal.
    public func dismissCommandFailure(_ hostId: String) {
        Task { await service.dismissCommandFailure(hostId: hostId) }
    }

    public func select(host hostId: String, session sessionId: String?, window windowId: String?) {
        let isNewSession = sessionId != nil && sessionId != hosts.first { $0.id == hostId }?.activeSessionId
        selectedHostId = hostId
        selectedSessionId = sessionId
        selectedWindowId = windowId
        focusedPaneId = nil

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

    public func presentNewHost() {
        hostDraft = HostDraft(isNew: true, host: StoredHost(id: "", name: ""))
    }

    public func presentEditHost(_ hostId: String) {
        guard let host = hosts.first(where: { $0.id == hostId }) else { return }
        hostDraft = HostDraft(isNew: false, host: host.config.asStoredHost)
    }

    /// Saves a host from the editor.
    ///
    /// `password` is non-nil only when the user typed one just now. An empty password with
    /// `savePassword` still set means "keep what is already in the Keychain", which is what an edit of
    /// some *other* field looks like.
    public func saveHost(_ draft: HostDraft, password: String?, savePassword: Bool) {
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

        hostDraft = nil
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

    public func requestCloseWindow() {
        let scope = activeScope
        guard let hostId = scope.hostId, let window = window(in: scope) else { return }
        pendingClose = closeWindow(hostId: hostId, window: window)
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
    public func confirmCloseWindow() {
        guard let pending = pendingClose else { return }
        pendingClose = nil
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

    public func requestRenameWindow(hostId: String? = nil, windowId: String? = nil) {
        let scope = activeScope
        guard let hostId = hostId ?? scope.hostId else { return }
        guard let window = windowId.flatMap({ id in hosts.first { $0.id == hostId }?.window(id) })
            ?? self.window(in: scope) else { return }
        pendingRename = renameRequest(hostId: hostId, window: window)
    }

    public func requestRenameSession(hostId: String? = nil, sessionId: String? = nil) {
        let scope = activeScope
        guard let hostId = hostId ?? scope.hostId, let host = hosts.first(where: { $0.id == hostId }) else { return }
        guard let session = (sessionId ?? scope.sessionId).flatMap({ id in host.sessions.first { $0.id == id } })
            ?? host.activeSession else { return }
        pendingRename = renameRequest(hostId: hostId, session: session)
    }

    /// Sends the rename and dismisses the sheet. The name in the tree updates when tmux answers with
    /// `%session-renamed`/`%window-renamed`, not here — tmux is authoritative for its own model.
    public func commitRename(to newName: String) {
        guard let pending = pendingRename else { return }
        pendingRename = nil
        commit(pending, to: newName)
    }

    /// The same commit, for a window holding its own rename state rather than the shared one. A sheet
    /// bound to shared state would try to present itself in every open window at once.
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

    public func createSession(hostId: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            if hosts.first(where: { $0.id == hostId })?.connectionState.isActive == true {
                await service.newSession(hostId: hostId, name: trimmed)
            } else {
                try? await service.connectHost(hostId: hostId, targetSession: trimmed)
            }
        }
    }

    public func pasteIntoFocusedPane() {
        let scope = activeScope
        guard let hostId = scope.hostId,
              let paneId = scope.paneId ?? window(in: scope)?.preferredPaneId,
              let text = NSPasteboard.general.string(forType: .string) else { return }
        Task { await service.paste(hostId: hostId, paneId: paneId, text: text) }
    }

    /// A tear-off the menu asked for.
    ///
    /// `openWindow` is an environment action, and `Commands` has no environment to read it from, so the
    /// menu records the request and the main window performs it.
    public var requestedDetachScene: DetachedScene?

    /// F4.12 — tears the frontmost window's tmux window off into its own macOS window.
    public func detachActiveWindow() {
        let scope = activeScope
        guard let hostId = scope.hostId,
              let sessionId = scope.sessionId,
              let windowId = scope.windowId ?? window(in: scope)?.id else { return }
        requestedDetachScene = DetachedScene(hostId: hostId, sessionId: sessionId, windowId: windowId)
    }

    /// Moves the client to a session without changing what any window shows. Used by a detached window
    /// showing a session that is not the attached one: only the attached session receives `%output`, so
    /// this is what makes its panes live — and it necessarily freezes whatever session was attached
    /// before, which is why the button that calls it says so.
    public func attachHere(hostId: String, sessionId: String) {
        Task { await service.switchSession(hostId: hostId, sessionId: sessionId) }
    }

    /// F4.25 — one ranked list over hosts, sessions, and windows.
    public func launcherItems() -> [LauncherItem] {
        var items: [LauncherItem] = []
        for host in hosts {
            let reachable = host.connectionState.isActive
            items.append(LauncherItem(
                title: host.config.name,
                subtitle: host.config.isLocal ? "Local tmux" : "SSH host",
                iconName: host.config.isLocal ? "laptopcomputer" : "server.rack",
                isAvailable: true
            ) { [weak self] in self?.connect(host.id) })

            for session in host.sessions {
                for window in session.windows {
                    items.append(LauncherItem(
                        title: "\(window.name)",
                        subtitle: "\(host.config.name) › \(session.name)\(reachable ? "" : " (will connect)")",
                        iconName: "square.split.2x1",
                        isAvailable: reachable
                    ) { [weak self] in
                        self?.select(host: host.id, session: session.id, window: window.id)
                    })
                }
            }
        }
        return items
    }
}
