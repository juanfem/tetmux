import XCTest
import tetmuxCore
@testable import tetmux_relay

/// Where a browser lands when what it asked for is partly missing or gone: a tab tap names only a
/// window, a page coming back from the background names a pane that may have closed meanwhile.
final class ViewResolverTests: XCTestCase {
    private func pane(_ id: String, _ command: String = "zsh", path: String = "/home/me/src") -> TmuxPane {
        TmuxPane(id: id, command: command, currentPath: path)
    }

    private func window(_ id: String, panes: [TmuxPane], active: String? = nil) -> TmuxWindow {
        TmuxWindow(id: id, name: id, panes: panes, activePaneId: active ?? panes.first?.id)
    }

    private func host(
        _ id: String = "local", state: ConnectionState = .connected, sessions: [TmuxSession]
    ) -> HostState {
        HostState(
            config: HostConfig(id: id, name: id, isLocal: id == "local"),
            connectionState: state,
            sessions: sessions,
            activeSessionId: sessions.first?.id
        )
    }

    private var work: TmuxSession {
        TmuxSession(id: "$0", name: "work", windows: [
            window("@0", panes: [pane("%0")]),
            window("@1", panes: [pane("%1"), pane("%2", "vim")], active: "%2"),
        ], activeWindowId: "@0")
    }

    private var other: TmuxSession {
        TmuxSession(id: "$1", name: "other", windows: [window("@2", panes: [pane("%3")])], activeWindowId: "@2")
    }

    func testAnEmptyRequestLandsOnTheActivePaneOfTheFirstHostThatIsUp() {
        let hosts = [host("down", state: .disconnected, sessions: []), host(sessions: [work, other])]
        XCTAssertEqual(
            ViewResolver.resolve(ViewRequest(), in: hosts),
            ViewTarget(host: "local", session: "$0", window: "@0", pane: "%0")
        )
    }

    func testAWindowTapTakesThatWindowsActivePane() {
        let target = ViewResolver.resolve(ViewRequest(host: "local", session: "$0", window: "@1"),
                                          in: [host(sessions: [work])])
        XCTAssertEqual(target?.pane, "%2")
    }

    func testAPaneThatClosedFallsBackWithinItsWindow() {
        let target = ViewResolver.resolve(
            ViewRequest(host: "local", session: "$0", window: "@1", pane: "%9"), in: [host(sessions: [work])]
        )
        XCTAssertEqual(target, ViewTarget(host: "local", session: "$0", window: "@1", pane: "%2"))
    }

    func testAWindowThatClosedFallsBackToTheSessionsActiveWindow() {
        let target = ViewResolver.resolve(
            ViewRequest(host: "local", session: "$0", window: "@9", pane: "%9"), in: [host(sessions: [work])]
        )
        XCTAssertEqual(target, ViewTarget(host: "local", session: "$0", window: "@0", pane: "%0"))
    }

    func testASessionThatEndedFallsBackToTheHostsActiveSession() {
        let target = ViewResolver.resolve(ViewRequest(host: "local", session: "$7"), in: [host(sessions: [other, work])])
        XCTAssertEqual(target?.session, "$1")
    }

    /// Picking a host that is still connecting is a request to wait for it, not to be shown another.
    func testAHostThatIsNotUpYetResolvesToNothing() {
        let hosts = [host(sessions: [work]), host("far", state: .reconnecting(attempt: 1, nextRetryInSeconds: 2),
                                                  sessions: [other])]
        XCTAssertNil(ViewResolver.resolve(ViewRequest(host: "far"), in: hosts))
    }

    func testAHostNoLongerConfiguredFallsBackToOneThatIsUp() {
        let target = ViewResolver.resolve(ViewRequest(host: "gone", session: "$0"), in: [host(sessions: [work])])
        XCTAssertEqual(target?.host, "local")
    }

    // MARK: - Topology

    func testPanesAreLabelledByCommandAndDirectory() {
        XCTAssertEqual(Wire.Topology.label(of: pane("%1", "vim", path: "/home/me/src")), "vim · src")
        XCTAssertEqual(Wire.Topology.label(of: pane("%1", "zsh", path: "")), "zsh")
        XCTAssertEqual(Wire.Topology.label(of: pane("%1", "", path: "")), "%1")
    }

    /// Sizes are not part of it, so a resize does not resend the tree.
    func testTheTopologyIgnoresSizes() {
        var resized = work
        resized.windows[0].panes[0].cols = 40
        XCTAssertEqual(Wire.Topology([host(sessions: [work])]), Wire.Topology([host(sessions: [resized])]))
    }

    /// F4.38 — the page is sent the colour by name, resolved by the policy the Mac uses, and nothing
    /// for the local host.
    func testTheTopologyCarriesEachHostsColourByName() {
        let local = host(sessions: [work])
        let prod = HostState(
            config: HostConfig(id: "custom-prod", name: "prod", color: .fixed(.red)), connectionState: .connected
        )
        let quiet = HostState(
            config: HostConfig(id: "custom-quiet", name: "quiet", color: .none), connectionState: .connected
        )
        let auto = HostState(config: HostConfig(id: "ssh-devbox", name: "devbox"), connectionState: .connected)
        let colors = Wire.Topology([local, prod, quiet, auto]).hosts.map(\.color)
        XCTAssertEqual(colors, [nil, "red", nil, "orange"])
    }
}
