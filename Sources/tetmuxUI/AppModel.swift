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
    public var isAddHostPresented = false
    public var newSessionTarget: String?
    /// A window the user asked to close, pending confirmation (F4.10).
    public var pendingClose: PendingClose?

    @ObservationIgnored private var networkMonitor: NetworkStateMonitor?
    @ObservationIgnored private var stateTask: Task<Void, Never>?

    public struct PendingClose: Identifiable, Equatable {
        public var id: String { "\(hostId)/\(windowId)" }
        public let hostId: String
        public let windowId: String
        public let windowName: String
        public let paneCount: Int
        public let runningCommands: [String]
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

    public func addHost(name: String, port: Int?, user: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            var stored = await store.loadHosts()
            let host = StoredHost(id: "custom-\(trimmed)", name: trimmed, user: user, port: port, isLocal: false)
            stored.removeAll { $0.id == host.id }
            stored.append(host)
            try? await store.saveHosts(stored)
            await service.addHost(host.asConfig)
        }
    }

    public func removeHost(_ hostId: String) {
        Task {
            await service.removeHost(hostId: hostId)
            var stored = await store.loadHosts()
            stored.removeAll { $0.id == hostId }
            try? await store.saveHosts(stored)
        }
    }

    public func newWindow() {
        guard let hostId = selectedHostId, let sessionId = selectedSession?.id else { return }
        Task { await service.newWindow(hostId: hostId, sessionId: sessionId) }
    }

    public func split(leftRight: Bool) {
        guard let hostId = selectedHostId, let paneId = focusedPaneId ?? selectedWindow?.preferredPaneId else { return }
        Task { await service.splitPane(hostId: hostId, paneId: paneId, leftRight: leftRight) }
    }

    public func requestCloseWindow() {
        guard let hostId = selectedHostId, let window = selectedWindow else { return }
        pendingClose = PendingClose(
            hostId: hostId,
            windowId: window.id,
            windowName: window.name,
            paneCount: window.paneCount,
            runningCommands: window.panes.map(\.command).filter { !$0.isEmpty }
        )
    }

    public func confirmCloseWindow() {
        guard let pending = pendingClose else { return }
        pendingClose = nil
        Task { await service.killWindow(hostId: pending.hostId, windowId: pending.windowId) }
    }

    public func closePane() {
        guard let hostId = selectedHostId, let paneId = focusedPaneId else { return }
        Task { await service.killPane(hostId: hostId, paneId: paneId) }
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
        guard let hostId = selectedHostId,
              let paneId = focusedPaneId ?? selectedWindow?.preferredPaneId,
              let text = NSPasteboard.general.string(forType: .string) else { return }
        Task { await service.paste(hostId: hostId, paneId: paneId, text: text) }
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
