import Foundation
import tetmuxCore

/// A place a browser can look: one pane, and the window, session and host around it.
struct ViewTarget: Equatable, Hashable, Sendable {
    let host: String
    let session: String
    let window: String
    let pane: String
}

/// What a browser asked to see, any part of which may be missing or out of date.
struct ViewRequest: Equatable, Sendable {
    var host: String?
    var session: String?
    var window: String?
    var pane: String?

    init(host: String? = nil, session: String? = nil, window: String? = nil, pane: String? = nil) {
        self.host = host
        self.session = session
        self.window = window
        self.pane = pane
    }

    init(_ target: ViewTarget) {
        self.init(host: target.host, session: target.session, window: target.window, pane: target.pane)
    }
}

/// Turns a request into a pane, keeping as much of the request as still exists.
///
/// The same rule covers a tap on a tab (`window` given, `pane` left to the relay), a page restoring
/// where it was after iOS dropped the socket (all four given, some possibly gone), and the relay
/// following a pane that was closed under the viewer (its own last target, re-resolved against a
/// topology that no longer has it). Each level falls back to what tmux considers current at that
/// level, so closing a pane lands on the window's active pane and closing a window on the session's
/// active window — the same place a tmux client would end up.
enum ViewResolver {
    /// `nil` when there is nothing to show yet: the host is not connected, or has no session.
    static func resolve(_ request: ViewRequest, in hosts: [HostState]) -> ViewTarget? {
        let host = request.host.flatMap { id in hosts.first { $0.id == id } }
            // Nothing asked for, or a host that is no longer configured: the first one that is up.
            ?? hosts.first { $0.connectionState.isActive && !$0.sessions.isEmpty }
        guard let host, host.connectionState.isActive else { return nil }

        guard let session = request.session.flatMap({ id in host.sessions.first { $0.id == id } })
            ?? host.activeSession else { return nil }

        guard let window = request.window.flatMap({ id in session.windows.first { $0.id == id } })
            ?? session.activeWindow ?? session.windows.first else { return nil }

        let pane = request.pane.flatMap { id in window.panes.first { $0.id == id }?.id }
            ?? window.preferredPaneId
        guard let pane else { return nil }

        return ViewTarget(host: host.id, session: session.id, window: window.id, pane: pane)
    }
}

/// Which sessions every open socket is looking at, collapsed into the one map the service wants.
///
/// A tmux client streams `%output` only for the session it is attached to, so a phone looking at a
/// session nobody else is attached to would see one repaint and then a frozen screen. The service
/// already keeps one client per *displayed* session for the app's windows (`setDisplayedSessions`);
/// in the relay, the sockets are the windows. One registry, because the service takes the whole map
/// at once and two sockets reporting separately would each overwrite the other.
actor ViewRegistry {
    private let service: SessionService
    private var views: [UUID: (host: String, session: String)] = [:]

    init(service: SessionService) {
        self.service = service
    }

    func set(_ socket: UUID, host: String, session: String) async {
        if let current = views[socket], current == (host, session) { return }
        views[socket] = (host, session)
        await publish()
    }

    func remove(_ socket: UUID) async {
        guard views.removeValue(forKey: socket) != nil else { return }
        await publish()
    }

    private func publish() async {
        var displayed: [String: Set<String>] = [:]
        for view in views.values {
            displayed[view.host, default: []].insert(view.session)
        }
        await service.setDisplayedSessions(displayed)
    }
}
