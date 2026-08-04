import XCTest
@testable import tetmuxCore
@testable import tetmuxUI

/// `AppModel` decisions that need no channel and no AppKit. Everything here was previously
/// unreachable from the test bundle, which linked only `tetmuxCore`.
@MainActor
final class AppModelTests: XCTestCase {

    private func window(_ id: String, name: String = "shell", panes: [String] = ["%1"]) -> TmuxWindow {
        var window = TmuxWindow(id: id, name: name)
        window.panes = panes.map { TmuxPane(id: $0, command: "vim") }
        return window
    }

    private func host(id: String = "local", sessions: [TmuxSession]) -> HostState {
        HostState(
            config: HostConfig(id: id, name: id, isLocal: true),
            connectionState: .connected,
            sessions: sessions,
            activeSessionId: sessions.first?.id
        )
    }

    // MARK: - Closing a window (F4.9)

    /// A window linked to several sessions can simply leave this one, so closing it asks nothing:
    /// nothing is destroyed and there is nothing to confirm.
    func testClosingAMultiLinkedWindowNeedsNoConfirmation() {
        let shared = window("@5")
        let model = AppModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "one", windows: [shared], isAttached: true),
            TmuxSession(id: "$2", name: "two", windows: [shared]),
        ])]

        XCTAssertNil(
            model.closeWindow(hostId: "local", window: shared),
            "an unlinkable window must not raise a destructive confirmation"
        )

        // …and nothing is queued in the window that asked, either.
        let state = WindowState()
        state.selectedHostId = "local"
        state.selectedSessionId = "$1"
        state.selectedWindowId = "@5"
        model.focus(state)
        model.requestCloseWindow(in: state)
        XCTAssertNil(state.pendingClose)
    }

    /// A window in exactly one session cannot be removed without destroying it — tmux refuses the
    /// unlink outright — so this is the one case that stops and asks (F4.10).
    func testClosingASingleLinkedWindowAsksBeforeKilling() {
        let only = window("@7", name: "build", panes: ["%1", "%2"])
        let model = AppModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "one", windows: [only], isAttached: true),
        ])]

        let pending = model.closeWindow(hostId: "local", window: only)
        let confirmation = try? XCTUnwrap(pending)
        XCTAssertEqual(confirmation?.windowId, "@7")
        XCTAssertEqual(confirmation?.windowName, "build")
        XCTAssertEqual(confirmation?.paneCount, 2)
        // F4.10 — the confirmation has to name what is running, not just the window.
        XCTAssertEqual(confirmation?.runningCommands, ["vim", "vim"])
    }

    /// ⌥ at the moment of the click is the user asserting they already know what the confirmation
    /// would have told them, so the question is skipped and the window is killed by the same call
    /// the confirmation would have made.
    ///
    /// Deliberately per-click: there is still no persistent "don't ask again" (F4.10), so the
    /// assertion has to be made again for the next window.
    func testOptionClickClosingAWindowSkipsTheConfirmation() {
        let only = window("@7", name: "build", panes: ["%1", "%2"])
        let model = AppModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "one", windows: [only], isAttached: true),
        ])]
        let state = WindowState()
        state.selectedHostId = "local"
        state.selectedSessionId = "$1"
        state.selectedWindowId = "@7"
        model.focus(state)

        model.requestCloseWindow(in: state, skippingConfirmation: true)

        XCTAssertNil(state.pendingClose, "⌥ must not raise the sheet it exists to skip")
    }

    /// A window belonging to a host we know nothing about is not silently unlinked. Treating an
    /// unknown host as "not multi-linked" is the safe direction: it asks rather than acting.
    func testClosingAWindowOnAnUnknownHostAsks() {
        let model = AppModel()
        model.hosts = []
        XCTAssertNotNil(model.closeWindow(hostId: "nope", window: window("@1")))
    }

    // MARK: - Default session names

    /// The first session on a host with none takes index 1, not 0.
    func testDefaultSessionNameStartsAtOne() {
        let model = AppModel()
        model.hosts = [host(sessions: [])]
        XCTAssertEqual(model.defaultSessionName(hostId: "local"), "tetmux_1")
    }

    /// A name already in use is skipped. tmux refuses a duplicate session name, and that refusal would
    /// surface as a failure banner for a command the user never typed a name for.
    func testDefaultSessionNameSkipsNamesAlreadyTaken() {
        let model = AppModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "tetmux_1", windows: [], isAttached: true),
            TmuxSession(id: "$2", name: "tetmux_2", windows: []),
        ])]
        XCTAssertEqual(model.defaultSessionName(hostId: "local"), "tetmux_3")
    }

    /// The lowest free index, not a running count: closing a session in the middle makes its name
    /// available again rather than leaving a permanent gap and climbing forever.
    func testDefaultSessionNameReusesAFreedIndex() {
        let model = AppModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "tetmux_1", windows: [], isAttached: true),
            TmuxSession(id: "$3", name: "tetmux_3", windows: []),
        ])]
        XCTAssertEqual(model.defaultSessionName(hostId: "local"), "tetmux_2")
    }

    /// Sessions the user named themselves are not in the way of the generated series.
    func testDefaultSessionNameIgnoresUnrelatedNames() {
        let model = AppModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "work", windows: [], isAttached: true),
            TmuxSession(id: "$2", name: "tetmux_dev", windows: []),
        ])]
        XCTAssertEqual(model.defaultSessionName(hostId: "local"), "tetmux_1")
    }

    // MARK: - Scope resolution

    /// Menu commands act on whichever window is key. Every window publishes its own scope now — there
    /// is no privileged main window to fall back to, because there can be several of them.
    func testFocusPublishesTheFocusedWindowsScope() {
        let model = AppModel()
        model.hosts = [twoSessionHost]

        let first = WindowState()
        first.selectedHostId = "local"
        first.selectedSessionId = "$1"
        first.selectedWindowId = "@1"

        let second = WindowState()
        second.selectedHostId = "local"
        second.selectedSessionId = "$2"
        second.selectedWindowId = "@2"

        model.focus(first)
        XCTAssertEqual(model.activeScope.windowId, "@1")

        model.focus(second)
        XCTAssertEqual(model.activeScope.windowId, "@2")
        XCTAssertEqual(model.activeScope.sessionId, "$2")

        // Focus going back is all it takes; nothing has to be cleared by the other window.
        model.focus(first)
        XCTAssertEqual(model.activeScope.windowId, "@1")
    }

    /// Item 15. Two windows used to share one selection, so navigating in either moved both.
    func testSelectingInOneWindowLeavesTheOtherAlone() {
        let model = AppModel()
        model.hosts = [twoSessionHost]

        let first = WindowState()
        model.select(in: first, host: "local", session: "$1", window: "@1")
        let second = WindowState()
        model.select(in: second, host: "local", session: "$2", window: "@2")

        XCTAssertEqual(first.selectedWindowId, "@1", "the second window's click moved the first one")
        XCTAssertEqual(first.selectedSessionId, "$1")
        XCTAssertEqual(second.selectedWindowId, "@2")
    }

    /// Item 13. One `.sheet(item:)` bound to shared model state opened the same editor once per open
    /// window; the draft belongs to the window that asked for it.
    func testTheHostEditorOpensOnlyInTheWindowThatAskedForIt() {
        let model = AppModel()
        model.hosts = [twoSessionHost]

        let asking = WindowState()
        let other = WindowState()
        model.presentNewHost(in: asking)

        XCTAssertNotNil(asking.hostDraft)
        XCTAssertNil(other.hostDraft, "a second window would present the same editor at the same time")
    }

    /// A rename raised in one window must not put a sheet in front of another.
    func testARenameSheetIsScopedToItsWindow() {
        let model = AppModel()
        model.hosts = [twoSessionHost]

        let asking = WindowState()
        asking.selectedHostId = "local"
        asking.selectedSessionId = "$1"
        asking.selectedWindowId = "@1"
        model.focus(asking)

        let other = WindowState()
        model.requestRenameWindow(in: asking)

        XCTAssertEqual(asking.pendingRename?.subject, .window("@1"))
        XCTAssertNil(other.pendingRename)
    }

    // MARK: - Host-level sheets

    /// An ssh prompt belongs to a host, not a window, and no window asked for it — so exactly one
    /// window presents it. Shown in all of them it is a password typed once per window.
    func testExactlyOneWindowPresentsHostLevelSheets() {
        let model = AppModel()
        let first = WindowState()
        let second = WindowState()
        model.registerWindow(first)
        model.registerWindow(second)

        XCTAssertTrue(model.presentsHostLevelSheets(first.id))
        XCTAssertFalse(model.presentsHostLevelSheets(second.id))
    }

    /// …and closing that window promotes the next, rather than leaving nothing able to show a prompt
    /// and a host stuck at "Connecting…" forever.
    func testClosingThePresentingWindowPromotesTheNext() {
        let model = AppModel()
        let first = WindowState()
        let second = WindowState()
        model.registerWindow(first)
        model.registerWindow(second)

        model.unregisterWindow(first.id)
        XCTAssertTrue(model.presentsHostLevelSheets(second.id))
    }

    /// Registration is idempotent: SwiftUI can run `onAppear` again for a window that never went away,
    /// and a duplicated entry would outlive one `onDisappear` and keep a dead window at the head.
    func testRegisteringTheSameWindowTwiceIsHarmless() {
        let model = AppModel()
        let first = WindowState()
        let second = WindowState()
        model.registerWindow(first)
        model.registerWindow(first)
        model.registerWindow(second)

        model.unregisterWindow(first.id)
        XCTAssertTrue(model.presentsHostLevelSheets(second.id))
    }

    // MARK: - Routing a session to a window (items 5, 9, 10, 12)

    /// Registers `count` windows and hands them back.
    private func openWindows(_ model: AppModel, _ count: Int) -> [WindowState] {
        (0..<count).map { _ in
            let state = WindowState()
            model.registerWindow(state)
            return state
        }
    }

    /// Item 9's first rule. A session already on screen is shown by bringing *that* window forward —
    /// retargeting a different one would hijack whatever it was displaying to duplicate something
    /// already visible.
    func testShowingASessionPrefersTheWindowAlreadyDisplayingIt() {
        let model = AppModel()
        model.hosts = [twoSessionHost]
        let windows = openWindows(model, 2)
        model.select(in: windows[0], host: "local", session: "$2", window: "@2")
        model.focus(windows[1])

        let target = model.showSession(hostId: "local", sessionId: "$2")

        XCTAssertIdentical(target, windows[0], "should have reused the window already on $2")
        XCTAssertNil(windows[1].selectedSessionId, "the last-used window was retargeted needlessly")
        XCTAssertNil(model.requestedWindow, "no new window should have been asked for")
    }

    /// Item 9's second rule: nothing is showing it, so the last-used window takes it. Not a new
    /// window — the menu bar picking a session should not litter the screen.
    func testShowingASessionFallsBackToTheLastUsedWindow() {
        let model = AppModel()
        model.hosts = [twoSessionHost]
        let windows = openWindows(model, 2)
        model.focus(windows[0])
        model.focus(windows[1])

        let target = model.showSession(hostId: "local", sessionId: "$2")

        XCTAssertIdentical(target, windows[1], "the most recently focused window should have taken it")
        XCTAssertEqual(windows[1].selectedSessionId, "$2")
        XCTAssertNil(model.requestedWindow)
    }

    /// Item 10 — Option-click opens a new window even when one is already showing the session.
    func testPreferNewWindowAsksForOneEvenWhenTheSessionIsAlreadyShown() {
        let model = AppModel()
        model.hosts = [twoSessionHost]
        let windows = openWindows(model, 1)
        model.select(in: windows[0], host: "local", session: "$2", window: "@2")

        let target = model.showSession(
            hostId: "local", sessionId: "$2", collapseSidebar: true, preferNewWindow: true
        )

        XCTAssertNil(target, "a new window is opened asynchronously, so nothing is returned")
        XCTAssertEqual(model.requestedWindow?.sessionId, "$2")
        XCTAssertEqual(model.requestedWindow?.collapseSidebar, true)
    }

    /// Item 5 — the double-clicked window takes the session when nothing else is showing it, rather
    /// than whichever window happened to be focused last.
    func testAnExplicitFallbackWinsOverTheLastUsedWindow() {
        let model = AppModel()
        model.hosts = [twoSessionHost]
        let windows = openWindows(model, 2)
        model.focus(windows[1])

        let target = model.showSession(
            hostId: "local", sessionId: "$2", collapseSidebar: true, fallback: windows[0]
        )

        XCTAssertIdentical(target, windows[0])
        XCTAssertEqual(windows[0].sidebarVisibility, .detailOnly, "item 5 collapses the tree")
        XCTAssertNil(windows[1].selectedSessionId)
    }

    /// With every window closed — the menu bar extra keeps the app alive with none — there is nothing
    /// to reuse and a window has to be opened.
    func testShowingASessionWithNoWindowsOpenAsksForOne() {
        let model = AppModel()
        model.hosts = [twoSessionHost]

        let target = model.showSession(hostId: "local", sessionId: "$2")

        XCTAssertNil(target)
        XCTAssertEqual(model.requestedWindow?.sessionId, "$2")
        // Seeded with the session's first window, so it does not come up empty.
        XCTAssertEqual(model.requestedWindow?.windowId, "@2")
    }

    /// A closed window must stop being offered as somewhere to put a session. The registry holds
    /// windows weakly for the same reason, but `unregisterWindow` is what runs in practice.
    func testAClosedWindowIsNoLongerARoutingTarget() {
        let model = AppModel()
        model.hosts = [twoSessionHost]
        let windows = openWindows(model, 2)
        model.select(in: windows[0], host: "local", session: "$2", window: "@2")
        model.focus(windows[0])

        model.unregisterWindow(windows[0].id)

        XCTAssertNil(model.window(showing: "$2", on: "local"), "a closed window was still offered")
        XCTAssertIdentical(model.lastUsedWindow, windows[1])
    }

    /// The seed is taken once. Otherwise ⌘N straight after opening a session would land on that
    /// session instead of coming up as a plain new window.
    func testASeedIsConsumedExactlyOnce() {
        let model = AppModel()
        model.openWindow(WindowSeed(hostId: "local", sessionId: "$2", collapseSidebar: true))

        XCTAssertEqual(model.consumeSeed()?.sessionId, "$2")
        XCTAssertNil(model.consumeSeed(), "a second window would inherit the first one's target")
    }

    /// One request opens one window, however many windows are watching for it.
    ///
    /// Every open window observes `requestedWindow`, and each of their observers fires for the same
    /// change — so a request claimed by value rather than by this method would open one window per
    /// window already on screen.
    func testAWindowRequestIsClaimedByExactlyOneWindow() {
        let model = AppModel()
        model.openWindow(WindowSeed(hostId: "local", sessionId: "$1"))

        XCTAssertTrue(model.claimWindowRequest(), "the first window to react should open one")
        XCTAssertFalse(model.claimWindowRequest(), "a second window would open a duplicate")
        XCTAssertFalse(model.claimWindowRequest())
    }

    /// And with no request outstanding nothing is claimed, so an unrelated redraw opens nothing.
    func testNothingIsClaimedWithoutARequest() {
        XCTAssertFalse(AppModel().claimWindowRequest())
    }

    /// With every window closed there is nobody left to claim the request, so the model performs it
    /// itself. Without this the menu bar extra — the whole reason the app stays alive with no windows
    /// — switches to a session and nothing appears, and the request sits set for good.
    func testAWindowRequestWithNothingOpenIsPerformedByTheModel() {
        let model = AppModel()
        model.hosts = [twoSessionHost]
        var opened = 0
        model.openAppWindow = { opened += 1 }

        model.showSession(hostId: "local", sessionId: "$2")

        XCTAssertEqual(opened, 1)
        XCTAssertNil(model.requestedWindow, "a request nobody can see must not be left outstanding")
        // The window that appears still starts where it was asked to.
        XCTAssertEqual(model.consumeSeed()?.sessionId, "$2")
    }

    /// …and with a window on screen it must *not*, or the request is honoured twice: once here and
    /// once by the window observing it.
    func testAWindowRequestWithAWindowOpenIsLeftToThatWindow() {
        let model = AppModel()
        model.hosts = [twoSessionHost]
        // Held, not discarded: the registry keeps windows weakly, so a released `WindowState` is
        // indistinguishable from a closed window and this would test the case above instead.
        let windows = openWindows(model, 1)
        var opened = 0
        model.openAppWindow = { opened += 1 }

        model.openWindow(WindowSeed(hostId: "local", sessionId: "$2"))

        XCTAssertEqual(opened, 0)
        XCTAssertTrue(model.claimWindowRequest(), "the open window's claim is still there to make")
        XCTAssertEqual(windows.count, 1)
    }

    // MARK: - Showing what was just created

    /// Pushes a snapshot through the same path the channel uses, so pending reveals resolve.
    private func publish(_ model: AppModel, _ hosts: [HostState]) {
        model.hosts = hosts
        model.resolveRevealsForTesting()
    }

    /// Creating a session selects it once tmux confirms it, rather than leaving the user to find it.
    /// Nothing can be selected at the moment of asking: control mode returns no id and the session
    /// only exists, from our side, when the topology comes back.
    func testCreatingASessionSelectsItWhenItArrives() {
        let model = AppModel()
        model.hosts = [host(sessions: [])]
        let state = WindowState()
        model.registerWindow(state)

        model.createSession(hostId: "local", name: "tetmux_1", revealIn: state)
        XCTAssertNil(state.selectedSessionId, "nothing exists to select yet")

        publish(model, [host(sessions: [
            TmuxSession(id: "$7", name: "tetmux_1", windows: [window("@9", panes: ["%9"])], isAttached: true),
        ])])

        XCTAssertEqual(state.selectedSessionId, "$7")
        XCTAssertEqual(state.selectedWindowId, "@9")
        XCTAssertTrue(
            model.takeSessionExpansion(hostId: "local", sessionId: "$7"),
            "the tree should open a session the user just made"
        )
    }

    /// The menu bar's plain New Session, once the last window has been closed: there is nothing to
    /// reveal *in*, so the reveal has to bring its own window. Without this the session is created on
    /// the server and nobody is ever shown it — no reveal was even queued.
    func testCreatingASessionWithNothingOpenBringsItsOwnWindow() {
        let model = AppModel()
        model.hosts = [host(sessions: [])]
        var opened = 0
        model.openAppWindow = { opened += 1 }

        // No window to reveal in, and no ⌥ either — the modifier is not what makes this one needed.
        model.createSession(hostId: "local", name: "tetmux_1")

        publish(model, [host(sessions: [
            TmuxSession(id: "$7", name: "tetmux_1", windows: [window("@9", panes: ["%9"])], isAttached: true),
        ])])

        XCTAssertEqual(opened, 1)
        XCTAssertEqual(model.consumeSeed()?.sessionId, "$7")
    }

    /// A new window is identified by not having been there before — not by whichever tmux made
    /// active, which a window opened elsewhere in the meantime would win.
    func testCreatingAWindowSelectsTheOneThatWasNotThereBefore() {
        let existing = TmuxSession(
            id: "$1", name: "one", windows: [window("@1", panes: ["%1"])], isAttached: true
        )
        let model = AppModel()
        model.hosts = [host(sessions: [existing])]
        let state = WindowState()
        model.registerWindow(state)

        model.newWindow(hostId: "local", sessionId: "$1", revealIn: state)

        var grown = existing
        grown.windows.append(window("@2", panes: ["%2"]))
        // tmux made some *other* window active in the meantime.
        grown.activeWindowId = "@1"
        publish(model, [host(sessions: [grown])])

        XCTAssertEqual(state.selectedWindowId, "@2", "selected the active window instead of the new one")
    }

    /// ⌥ on the menu bar's New Session means the session gets a window of its own. The window cannot
    /// be opened at the moment of asking — `new-session` answers with no id, so there is nothing to
    /// seed one with — so the request has to survive until tmux confirms the session.
    func testCreatingASessionInANewWindowAsksForOneWhenItArrives() {
        let model = AppModel()
        model.hosts = [host(sessions: [])]
        let state = WindowState()
        model.registerWindow(state)

        model.createSessionWithDefaultName(hostId: "local", preferNewWindow: true)
        XCTAssertNil(model.requestedWindow, "nothing exists to open a window onto yet")

        publish(model, [host(sessions: [
            TmuxSession(id: "$7", name: "tetmux_1", windows: [window("@9", panes: ["%9"])], isAttached: true),
        ])])

        XCTAssertEqual(model.requestedWindow?.sessionId, "$7")
        XCTAssertEqual(model.requestedWindow?.windowId, "@9")
        XCTAssertEqual(model.requestedWindow?.collapseSidebar, true)
        XCTAssertNil(
            state.selectedSessionId,
            "the new session belongs in the new window, not in the one that was already open"
        )
    }

    /// The new window is the only place the session goes, so the request must outlive the window that
    /// asked — unlike an ordinary reveal, which has nobody to show anything to once that window closes.
    func testANewWindowRevealSurvivesTheWindowThatAskedForIt() {
        let model = AppModel()
        model.hosts = [host(sessions: [])]
        var state: WindowState? = WindowState()
        model.registerWindow(state!)
        model.createSessionWithDefaultName(hostId: "local", preferNewWindow: true)

        model.unregisterWindow(state!.id)
        state = nil

        publish(model, [host(sessions: [
            TmuxSession(id: "$7", name: "tetmux_1", windows: [window("@9")], isAttached: true),
        ])])
        XCTAssertEqual(model.requestedWindow?.sessionId, "$7")
    }

    /// A reveal waits for its subject rather than settling for whatever is there.
    func testAPendingRevealDoesNotSelectSomethingElse() {
        let model = AppModel()
        model.hosts = [host(sessions: [])]
        let state = WindowState()
        model.registerWindow(state)

        model.createSession(hostId: "local", name: "tetmux_2", revealIn: state)
        publish(model, [host(sessions: [
            TmuxSession(id: "$3", name: "unrelated", windows: [window("@3")], isAttached: true),
        ])])

        XCTAssertNil(state.selectedSessionId, "a different session was selected")
    }

    /// A window closed before its request resolves takes the request with it, rather than the model
    /// holding a dead window open.
    func testARevealForAClosedWindowIsDiscarded() {
        let model = AppModel()
        model.hosts = [host(sessions: [])]
        var state: WindowState? = WindowState()
        model.registerWindow(state!)
        model.createSession(hostId: "local", name: "tetmux_1", revealIn: state)

        model.unregisterWindow(state!.id)
        state = nil

        publish(model, [host(sessions: [
            TmuxSession(id: "$7", name: "tetmux_1", windows: [window("@9")], isAttached: true),
        ])])
        XCTAssertFalse(model.takeSessionExpansion(hostId: "local", sessionId: "$7"))
    }

    // MARK: - A client per displayed session

    /// Two windows on one session ask for one client. A second client on the same session would
    /// stream the same panes twice and buy nothing.
    func testTwoWindowsOnTheSameSessionAskForOneClient() {
        let model = AppModel()
        model.hosts = [host(sessions: [TmuxSession(id: "$1", name: "one", windows: [window("@1")])])]
        // Held: the model's window registry is weak, so a window nothing keeps alive is a window
        // that closed the instant it opened.
        let windows = (0..<2).map { _ -> WindowState in
            let state = WindowState()
            state.selectedHostId = "local"
            state.selectedSessionId = "$1"
            model.registerWindow(state)
            return state
        }
        XCTAssertEqual(model.displayedSessions, ["local": ["$1"]])
        XCTAssertEqual(windows.count, 2)
    }

    /// Two sessions on screen are two clients, which is the entire point: one tmux client streams
    /// output for one session, so the second window used to be a still frame.
    func testEverySessionOnScreenIsAskedFor() {
        let model = AppModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "one", windows: [window("@1")]),
            TmuxSession(id: "$2", name: "two", windows: [window("@2")]),
        ])]
        let windows = ["$1", "$2"].map { sessionId -> WindowState in
            let state = WindowState()
            state.selectedHostId = "local"
            state.selectedSessionId = sessionId
            model.registerWindow(state)
            return state
        }
        // Plus a window showing nothing at all, which asks for nothing.
        let empty = WindowState()
        model.registerWindow(empty)

        XCTAssertEqual(model.displayedSessions, ["local": ["$1", "$2"]])
        XCTAssertEqual(windows.count, 2)
    }

    /// Closing a window gives its client back, unless another window is still showing that session.
    func testAClosedWindowStopsAskingForItsSession() {
        let model = AppModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "one", windows: [window("@1")]),
            TmuxSession(id: "$2", name: "two", windows: [window("@2")]),
        ])]
        let shared = WindowState()
        shared.selectedHostId = "local"
        shared.selectedSessionId = "$1"
        let other = WindowState()
        other.selectedHostId = "local"
        other.selectedSessionId = "$2"
        let duplicate = WindowState()
        duplicate.selectedHostId = "local"
        duplicate.selectedSessionId = "$1"
        for state in [shared, other, duplicate] { model.registerWindow(state) }

        model.unregisterWindow(other.id)
        XCTAssertEqual(model.displayedSessions, ["local": ["$1"]])

        model.unregisterWindow(duplicate.id)
        XCTAssertEqual(model.displayedSessions, ["local": ["$1"]], "the other window still shows it")

        model.unregisterWindow(shared.id)
        XCTAssertEqual(model.displayedSessions, [:])
    }

    // MARK: - Window labels

    /// A name the user chose beats what happens to be running, however many panes there are. That is
    /// the whole point of having named it.
    func testAnExplicitlyNamedWindowKeepsItsName() {
        var named = window("@1", name: "build", panes: ["%1", "%2"])
        named.hasExplicitName = true
        XCTAssertEqual(named.displayLabel, "build")
    }

    /// A split window tmux is naming for itself lists every pane. tmux's automatic name follows the
    /// *active* pane, so the label used to change as the user moved between panes, and two split
    /// windows read identically whenever their active panes matched.
    func testASplitWindowListsEveryPanesCommand() {
        var split = TmuxWindow(id: "@2", name: "zsh")
        split.panes = [
            TmuxPane(id: "%1", command: "zsh"),
            TmuxPane(id: "%2", command: "vim"),
            TmuxPane(id: "%3", command: "htop"),
        ]
        XCTAssertEqual(split.displayLabel, "zsh · vim · htop")
    }

    /// A single pane is just the window name, which is tmux's automatic name — the running command.
    /// Using the name rather than the pane keeps it live: `%window-renamed` updates it immediately,
    /// where a pane's command waits for a refresh.
    func testASinglePaneWindowUsesItsName() {
        let single = TmuxWindow(id: "@3", name: "vim", panes: [TmuxPane(id: "%1", command: "vim")])
        XCTAssertEqual(single.displayLabel, "vim")
    }

    /// Panes whose command is not known yet must not produce a label of separators.
    func testASplitWindowWithNoKnownCommandsFallsBackToItsName() {
        var split = TmuxWindow(id: "@4", name: "shell")
        split.panes = [TmuxPane(id: "%1", command: ""), TmuxPane(id: "%2", command: "")]
        XCTAssertEqual(split.displayLabel, "shell")
    }

    // MARK: - Ids collide across hosts

    /// tmux numbers sessions and windows per *server*, so `$0` and `@1` exist on every host at once.
    ///
    /// This is not a hypothetical: the ordinary way to reach a second host is to ssh into it, and the
    /// tmux there starts numbering from zero exactly like the first one's — so two hosts with a `$0`
    /// containing an `@1` is the common case, not the odd one. Comparing only the tmux ids highlighted
    /// the matching row on *every* connected host simultaneously.
    func testRowSelectionDistinguishesHostsWithCollidingIds() {
        let state = WindowState()
        state.selectedHostId = "local"
        state.selectedSessionId = "$0"
        state.selectedWindowId = "@1"

        XCTAssertTrue(state.isShowing(hostId: "local", sessionId: "$0", windowId: "@1"))
        XCTAssertFalse(
            state.isShowing(hostId: "remote", sessionId: "$0", windowId: "@1"),
            "the same tmux ids on another host must not read as selected"
        )
        XCTAssertTrue(state.isShowing(hostId: "local", sessionId: "$0"))
        XCTAssertFalse(state.isShowing(hostId: "remote", sessionId: "$0"))
    }

    /// A window on the right host but the wrong session, or the right session and the wrong window,
    /// is still not the selected row.
    func testRowSelectionNeedsAllThreeToMatch() {
        let state = WindowState()
        state.selectedHostId = "local"
        state.selectedSessionId = "$0"
        state.selectedWindowId = "@1"

        XCTAssertFalse(state.isShowing(hostId: "local", sessionId: "$3", windowId: "@1"))
        XCTAssertFalse(state.isShowing(hostId: "local", sessionId: "$0", windowId: "@9"))
    }

    /// The commands behind the row buttons carry the host explicitly, so a colliding id on another
    /// host cannot receive them. Asserted on the confirmation, which is the observable half.
    func testKillTargetsTheHostTheRowBelongsTo() {
        let model = AppModel()
        let colliding = TmuxSession(
            id: "$0", name: "shared-id", windows: [window("@1", panes: ["%1"])], isAttached: true
        )
        model.hosts = [
            host(id: "local", sessions: [colliding]),
            host(id: "remote", sessions: [colliding]),
        ]
        let state = WindowState()

        model.requestKillSession(in: state, hostId: "remote", sessionId: "$0")

        XCTAssertEqual(state.pendingKillSession?.hostId, "remote", "the kill went to the wrong host")
        XCTAssertEqual(state.pendingKillSession?.sessionId, "$0")
    }

    /// Likewise for renaming: `$0` exists on both hosts and the request must name which one.
    func testRenameTargetsTheHostTheRowBelongsTo() {
        let model = AppModel()
        model.hosts = [
            host(id: "local", sessions: [TmuxSession(id: "$0", name: "here", windows: [], isAttached: true)]),
            host(id: "remote", sessions: [TmuxSession(id: "$0", name: "there", windows: [], isAttached: true)]),
        ]
        let state = WindowState()

        model.requestRenameSession(in: state, hostId: "remote", sessionId: "$0")

        XCTAssertEqual(state.pendingRename?.hostId, "remote")
        XCTAssertEqual(state.pendingRename?.currentName, "there", "picked the other host's session")
    }

    // MARK: - Killing a session (item 3)

    /// Killing a session ends every process in every window it has, and tmux has no unlink to soften
    /// it, so the confirmation has to say what is about to go.
    func testKillingASessionAsksAndNamesWhatIsRunning() {
        let model = AppModel()
        model.hosts = [host(sessions: [
            TmuxSession(
                id: "$1", name: "work",
                windows: [window("@1", panes: ["%1"]), window("@2", panes: ["%2", "%3"])],
                isAttached: true
            ),
        ])]
        let state = WindowState()

        model.requestKillSession(in: state, hostId: "local", sessionId: "$1")

        XCTAssertEqual(state.pendingKillSession?.sessionName, "work")
        XCTAssertEqual(state.pendingKillSession?.windowCount, 2)
        XCTAssertEqual(state.pendingKillSession?.runningCommands, ["vim", "vim", "vim"])
    }

    /// ⌥ skips it here too. Same modifier, same meaning, one level up the tree.
    func testOptionClickKillingASessionSkipsTheConfirmation() {
        let model = AppModel()
        model.hosts = [twoSessionHost]
        let state = WindowState()

        model.requestKillSession(
            in: state, hostId: "local", sessionId: "$1", skippingConfirmation: true
        )

        XCTAssertNil(state.pendingKillSession)
    }

    /// A session that is already gone raises nothing, rather than a confirmation naming a session
    /// that cannot be killed.
    func testKillingAnUnknownSessionRaisesNothing() {
        let model = AppModel()
        model.hosts = [twoSessionHost]
        let state = WindowState()

        model.requestKillSession(in: state, hostId: "local", sessionId: "$99")

        XCTAssertNil(state.pendingKillSession)
    }

    // MARK: - Per-window reconciliation

    /// Selection follows the topology per window. A window pointing at a session that has gone lands
    /// on a live one rather than showing an empty detail pane forever.
    func testReconcileMovesASelectionOffSomethingThatIsGone() {
        let state = WindowState()
        state.selectedHostId = "local"
        state.selectedSessionId = "$9"
        state.selectedWindowId = "@9"
        state.focusedPaneId = "%9"

        state.reconcile(with: [twoSessionHost])

        XCTAssertEqual(state.selectedHostId, "local")
        XCTAssertEqual(state.selectedSessionId, "$1", "should fall back to the attached session")
        XCTAssertEqual(state.selectedWindowId, "@1")
        XCTAssertEqual(state.focusedPaneId, "%1")
    }

    /// A selection that is still valid is left exactly where it is — reconciliation runs on every
    /// topology change, so moving a good selection would drag the user's window around under them.
    func testReconcileLeavesALiveSelectionAlone() {
        let state = WindowState()
        state.selectedHostId = "local"
        state.selectedSessionId = "$2"
        state.selectedWindowId = "@2"
        state.focusedPaneId = "%2"

        state.reconcile(with: [twoSessionHost])

        XCTAssertEqual(state.selectedSessionId, "$2")
        XCTAssertEqual(state.selectedWindowId, "@2")
        XCTAssertEqual(state.focusedPaneId, "%2")
    }

    /// Two hosts, one session each, and a window pointing at the second: reconciliation must not drag
    /// it back to the first just because that one is listed first.
    func testReconcileKeepsAWindowOnItsOwnHost() {
        let other = HostState(
            config: HostConfig(id: "remote", name: "remote", isLocal: false),
            connectionState: .connected,
            sessions: [TmuxSession(id: "$5", name: "five", windows: [window("@5", panes: ["%5"])], isAttached: true)],
            activeSessionId: "$5"
        )
        let state = WindowState()
        state.selectedHostId = "remote"
        state.reconcile(with: [twoSessionHost, other])

        XCTAssertEqual(state.selectedHostId, "remote")
        XCTAssertEqual(state.selectedWindowId, "@5")
    }

    /// One host with two sessions, the first attached.
    private var twoSessionHost: HostState {
        host(sessions: [
            TmuxSession(id: "$1", name: "one", windows: [window("@1", panes: ["%1"])], isAttached: true),
            TmuxSession(id: "$2", name: "two", windows: [window("@2", panes: ["%2"])]),
        ])
    }

    // MARK: - Keymap policy (F4.19/F4.22)

    /// Item 11 — a macOS window and a tmux window are different things and need different chords.
    /// ⌘N was the tmux one, which is not what ⌘N means in any other application.
    func testTheTwoKindsOfNewWindowAreDistinctCommands() {
        let keymap = KeymapPolicy.default
        let app = keymap.binding(for: .newAppWindow)
        let tmux = keymap.binding(for: .newWindow)

        XCTAssertEqual(app?.key, "n")
        XCTAssertEqual(tmux?.key, "t")
        XCTAssertNotEqual(app, tmux)
        XCTAssertNotEqual(
            ApplicationShortcut.newAppWindow.title, ApplicationShortcut.newWindow.title,
            "two menu items with one title is not a menu"
        )
        // AppKit manages items literally titled "New Tab"/"Close Tab" itself under automatic window
        // tabbing; ours must not compete with it for those names.
        for shortcut in ApplicationShortcut.allCases {
            XCTAssertFalse(
                ["New Tab", "Close Tab", "Close Tab…"].contains(shortcut.title),
                "\(shortcut) uses a title AppKit reserves for window tabbing"
            )
        }
    }

    /// The whole default set lives in Cmd space so that bare Ctrl chords — readline, Emacs, tmux's
    /// own prefix — reach the pane untouched.
    func testEveryDefaultBindingUsesCommand() {
        let keymap = KeymapPolicy.default
        for shortcut in ApplicationShortcut.allCases {
            guard let binding = keymap.binding(for: shortcut) else { continue }
            XCTAssertTrue(
                binding.modifiers.contains(.command),
                "\(shortcut) is bound without Cmd, so it would intercept a chord meant for the pane"
            )
        }
    }

    func testShortcutMatchingIsExactAboutModifiers() {
        let keymap = KeymapPolicy.default
        XCTAssertEqual(keymap.shortcut(for: keyEvent("d", [.command])), .splitRight)
        XCTAssertEqual(keymap.shortcut(for: keyEvent("d", [.command, .shift])), .splitDown)
        // Bare Ctrl chords are the pane's (F4.20) — Ctrl+K is kill-line, not the launcher.
        XCTAssertNil(keymap.shortcut(for: keyEvent("k", [.control])))
        XCTAssertNil(keymap.shortcut(for: keyEvent("k", [])))
    }

    /// F4.21 — after the literal escape, even a bound chord belongs to the pane.
    func testLiteralEscapeLetsABoundChordThrough() {
        let keymap = KeymapPolicy.default
        XCTAssertEqual(keymap.shortcut(for: keyEvent("v", [.command])), .paste)
        XCTAssertNil(keymap.shortcut(for: keyEvent("v", [.command]), literalEscapeActive: true))
    }

    private func keyEvent(_ character: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        )!
    }
}
