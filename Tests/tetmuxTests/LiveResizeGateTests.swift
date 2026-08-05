import AppKit
import XCTest
@testable import tetmuxUI

/// R3.7 — no channel traffic while a window's edge is being dragged, and one request at the size it
/// was let go of.
///
/// The gate rather than the container view is what these drive, and that is the whole of the
/// decision worth pinning: the view's job is to compute a size and hand it over, the gate's job is
/// to decide whether that ask reaches tmux now, later, or never. Getting it wrong is silent in both
/// directions — a request that escapes during the drag is the churn this exists to stop, and a
/// request that never arrives afterwards leaves a tab holding the grid it had before the drag.
@MainActor
final class LiveResizeGateTests: XCTestCase {

    func testARequestOutsideALiveResizeIsSentImmediately() {
        let gate = LiveResizeGate()
        var sent: [String] = []
        gate.submit(key: "@1") { sent.append("80x24") }
        XCTAssertEqual(sent, ["80x24"])
    }

    func testNothingIsSentWhileTheWindowIsBeingResized() {
        let gate = LiveResizeGate()
        var sent: [String] = []
        gate.begin()
        for cols in 80...90 {
            gate.submit(key: "@1") { sent.append("\(cols)") }
        }
        XCTAssertTrue(gate.isLiveResizing)
        XCTAssertEqual(sent, [], "every ask during the drag is a refresh-client the user pays for")
    }

    func testTheDragEndsWithExactlyOneRequestAtTheFinalSize() {
        let gate = LiveResizeGate()
        var sent: [String] = []
        gate.begin()
        for cols in 80...90 {
            gate.submit(key: "@1") { sent.append("\(cols)") }
        }
        gate.end()
        XCTAssertFalse(gate.isLiveResizing)
        XCTAssertEqual(sent, ["90"])
    }

    /// Every tmux window of the session is built and measuring itself — the unselected ones are
    /// hidden with `.opacity(0)`, not omitted — so a single held request would let the last tab laid
    /// out overwrite the others, and they would come out of the drag with the old grid.
    func testEachTmuxWindowKeepsItsOwnHeldRequest() {
        let gate = LiveResizeGate()
        var sent: Set<String> = []
        gate.begin()
        gate.submit(key: "@1") { sent.insert("@1:70") }
        gate.submit(key: "@2") { sent.insert("@2:70") }
        gate.submit(key: "@1") { sent.insert("@1:90") }
        gate.submit(key: "@2") { sent.insert("@2:90") }
        gate.end()
        XCTAssertEqual(sent, ["@1:90", "@2:90"])
    }

    /// A container that goes away mid-drag must not resize its tmux window on the way out.
    func testAWithdrawnRequestIsNotSentWhenTheDragEnds() {
        let gate = LiveResizeGate()
        var sent: [String] = []
        gate.begin()
        gate.submit(key: "@1") { sent.append("@1") }
        gate.submit(key: "@2") { sent.append("@2") }
        gate.cancel(key: "@1")
        gate.end()
        XCTAssertEqual(sent, ["@2"])
    }

    func testASecondDragStartsWithNothingHeldOverFromTheFirst() {
        let gate = LiveResizeGate()
        var sent: [String] = []
        gate.begin()
        gate.submit(key: "@1") { sent.append("first") }
        gate.end()
        gate.begin()
        gate.end()
        XCTAssertEqual(sent, ["first"], "the first drag's request must not be replayed by the second")
    }

    /// The wiring, not the arithmetic: the gate is driven by AppKit's own notifications for one
    /// window, and a gate watching the wrong names or the wrong window is a gate that never closes.
    func testTheWindowsOwnLiveResizeNotificationsDriveTheGate() {
        let center = NotificationCenter()
        let gate = LiveResizeGate(center: center)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: true
        )
        gate.observe(window)

        var sent: [String] = []
        center.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        gate.submit(key: "@1") { sent.append("mid-drag") }
        XCTAssertEqual(sent, [])

        center.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        XCTAssertEqual(sent, ["mid-drag"])
    }

    /// Every open window listens to the same two notification names, so the filter on the posting
    /// window is the only thing keeping one drag from silencing the rest of the application.
    func testAnotherWindowsDragDoesNotSilenceThisOne() {
        let center = NotificationCenter()
        let gate = LiveResizeGate(center: center)
        let mine = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: true
        )
        let theirs = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: true
        )
        gate.observe(mine)

        center.post(name: NSWindow.willStartLiveResizeNotification, object: theirs)
        var sent: [String] = []
        gate.submit(key: "@1") { sent.append("sent") }
        XCTAssertFalse(gate.isLiveResizing)
        XCTAssertEqual(sent, ["sent"])
    }

    func testStopObservingEndsTheSubscription() {
        let center = NotificationCenter()
        let gate = LiveResizeGate(center: center)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: true
        )
        gate.observe(window)
        gate.stopObserving()
        center.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        XCTAssertFalse(gate.isLiveResizing)
    }
}
