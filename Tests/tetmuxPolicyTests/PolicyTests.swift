import XCTest
import tetmuxCore
@testable import tetmuxPolicy

/// The decisions every front end shares, tested with nothing but a topology snapshot — which is what
/// lets them run on Linux beside the fixture replay, rather than only inside an AppKit test bundle.
final class PolicyTests: XCTestCase {
    private func window(_ id: String, name: String = "shell", active: Bool = false) -> TmuxWindow {
        var window = TmuxWindow(id: id, name: name)
        window.hasActivity = active
        return window
    }

    private func host(id: String = "local", isLocal: Bool = true, sessions: [TmuxSession]) -> HostState {
        HostState(
            config: HostConfig(id: id, name: id, isLocal: isLocal),
            connectionState: .connected,
            sessions: sessions,
            activeSessionId: sessions.first?.id
        )
    }

    // MARK: - Closing (F4.9)

    func testALinkedWindowUnlinksAndNamesWhereItSurvives() {
        let shared = window("@5", name: "build")
        let hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "one", windows: [shared], isAttached: true),
            TmuxSession(id: "$2", name: "two", windows: [shared]),
            TmuxSession(id: "$3", name: "three", windows: [shared]),
        ])]
        XCTAssertEqual(
            ClosePolicy.outcome(in: hosts, hostId: "local", windowId: "@5", closingIn: "$1"),
            .unlinks(remaining: ["two", "three"])
        )
    }

    func testAWindowInOneSessionKills() {
        let hosts = [host(sessions: [TmuxSession(id: "$1", name: "one", windows: [window("@7")])])]
        XCTAssertEqual(ClosePolicy.outcome(in: hosts, hostId: "local", windowId: "@7", closingIn: "$1"), .kills)
    }

    /// An unknown host is the case that asks, never a silent unlink of nothing.
    func testAnUnknownHostKills() {
        XCTAssertEqual(ClosePolicy.outcome(in: [], hostId: "nope", windowId: "@1"), .kills)
    }

    /// tmux ids are per server: `@5` linked twice on one host says nothing about `@5` on another.
    func testLinkingDoesNotCrossHosts() {
        let shared = window("@5")
        let hosts = [
            host(sessions: [TmuxSession(id: "$1", name: "one", windows: [shared])]),
            host(id: "build-box", isLocal: false, sessions: [
                TmuxSession(id: "$1", name: "a", windows: [shared]),
                TmuxSession(id: "$2", name: "b", windows: [shared]),
            ]),
        ]
        XCTAssertEqual(ClosePolicy.outcome(in: hosts, hostId: "local", windowId: "@5"), .kills)
    }

    func testTheDescriptionSaysWhichOneIsIrreversible() {
        XCTAssertTrue(
            ClosePolicy.description(of: .kills, windowName: "build").contains("ends what is running in it")
        )
        let many = ClosePolicy.description(of: .unlinks(remaining: ["a", "b", "c", "d", "e"]), windowName: "w")
        XCTAssertTrue(many.contains("keeps running in a, b, c and 2 more"), many)
    }

    // MARK: - Reordering tabs

    /// The dragged tab takes the target's position; which side of it depends on the direction.
    func testDraggingATabRightwardsLandsAfterItsTarget() {
        let order = ["@1", "@2", "@3", "@4"]
        XCTAssertEqual(TabOrder.dropDestination(order: order, dragged: "@1", onto: "@3"), .some("@4"))
        // Onto the last one there is nothing after it, so it lands at the end.
        XCTAssertEqual(TabOrder.dropDestination(order: order, dragged: "@1", onto: "@4"), .some(nil))
    }

    func testDraggingATabLeftwardsLandsOnItsTarget() {
        let order = ["@1", "@2", "@3", "@4"]
        XCTAssertEqual(TabOrder.dropDestination(order: order, dragged: "@4", onto: "@2"), .some("@2"))
        XCTAssertEqual(TabOrder.dropDestination(order: order, dragged: "@3", onto: "@1"), .some("@1"))
    }

    func testDroppingATabOnItselfIsNotAMove() {
        // Compared against a typed `.none` rather than asserted nil: the result is a *double*
        // optional, and `XCTAssertNil` takes `Any?`, so the outer nil it is being asked about is the
        // one the coercion flattens away.
        XCTAssertEqual(TabOrder.dropDestination(order: ["@1", "@2"], dragged: "@1", onto: "@1"), String??.none)
        XCTAssertEqual(TabOrder.dropDestination(order: ["@1", "@2"], dragged: "@9", onto: "@1"), String??.none)
    }

    /// Adjacent tabs swap, in both directions — where an off-by-one shows up as a drag that does nothing.
    func testDraggingOntoAnAdjacentTabSwapsThem() {
        let order = ["@1", "@2", "@3"]
        XCTAssertEqual(TabOrder.dropDestination(order: order, dragged: "@1", onto: "@2"), .some("@3"))
        XCTAssertEqual(TabOrder.dropDestination(order: order, dragged: "@2", onto: "@1"), .some("@1"))
    }

    // MARK: - Activity notifications (F4.31)

    /// The event is the *transition*, and everything below is a way of getting that wrong.
    func testAWatchedWindowThatStartsPrintingIsReported() {
        let before = [host(sessions: [TmuxSession(id: "$1", name: "one", windows: [window("@1", name: "build")])])]
        let after = [host(sessions: [TmuxSession(id: "$1", name: "one", windows: [
            window("@1", name: "build", active: true),
        ])])]
        let alerts = ActivityPolicy.newlyActive(
            from: before, to: after, watching: [WatchedWindow(hostId: "local", windowId: "@1")]
        )
        XCTAssertEqual(alerts.map(\.windowId), ["@1"])
    }

    /// `hasActivity` stays true until somebody looks, so reporting on the value would re-fire on
    /// every topology snapshot.
    func testAWindowThatWasAlreadyActiveDoesNotFireAgain() {
        let snapshot = [host(sessions: [TmuxSession(id: "$1", name: "one", windows: [window("@1", active: true)])])]
        let alerts = ActivityPolicy.newlyActive(
            from: snapshot, to: snapshot, watching: [WatchedWindow(hostId: "local", windowId: "@1")]
        )
        XCTAssertTrue(alerts.isEmpty)
    }

    func testAnUnwatchedWindowIsNeverReported() {
        let before = [host(sessions: [TmuxSession(id: "$1", name: "one", windows: [
            window("@1"), window("@2"),
        ])])]
        let after = [host(sessions: [TmuxSession(id: "$1", name: "one", windows: [
            window("@1", active: true), window("@2", active: true),
        ])])]
        let alerts = ActivityPolicy.newlyActive(
            from: before, to: after, watching: [WatchedWindow(hostId: "local", windowId: "@2")]
        )
        XCTAssertEqual(alerts.map(\.windowId), ["@2"])
    }

    /// tmux ids are per server, so a watch on `local`'s `@1` must say nothing about another host's.
    func testTheWatchDoesNotCrossHosts() {
        let before = [host(id: "build-box", isLocal: false, sessions: [
            TmuxSession(id: "$1", name: "one", windows: [window("@1")]),
        ])]
        let after = [host(id: "build-box", isLocal: false, sessions: [
            TmuxSession(id: "$1", name: "one", windows: [window("@1", active: true)]),
        ])]
        let alerts = ActivityPolicy.newlyActive(
            from: before, to: after, watching: [WatchedWindow(hostId: "local", windowId: "@1")]
        )
        XCTAssertTrue(alerts.isEmpty)
    }

    /// Attaching to a server whose watched window is already active is not it *becoming* active.
    func testAWindowSeenForTheFirstTimeIsNotReported() {
        let after = [host(sessions: [TmuxSession(id: "$1", name: "one", windows: [window("@1", active: true)])])]
        let alerts = ActivityPolicy.newlyActive(
            from: [], to: after, watching: [WatchedWindow(hostId: "local", windowId: "@1")]
        )
        XCTAssertTrue(alerts.isEmpty)
    }

    /// A window linked into several sessions is one window and appears once in each.
    func testALinkedWindowIsReportedOnce() {
        let quiet = window("@5", name: "build")
        let loud = window("@5", name: "build", active: true)
        let before = [host(sessions: [
            TmuxSession(id: "$1", name: "one", windows: [quiet]),
            TmuxSession(id: "$2", name: "two", windows: [quiet]),
        ])]
        let after = [host(sessions: [
            TmuxSession(id: "$1", name: "one", windows: [loud]),
            TmuxSession(id: "$2", name: "two", windows: [loud]),
        ])]
        let alerts = ActivityPolicy.newlyActive(
            from: before, to: after, watching: [WatchedWindow(hostId: "local", windowId: "@5")]
        )
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.label, "build")
    }
}
