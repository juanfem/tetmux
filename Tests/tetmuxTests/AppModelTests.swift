import XCTest
@testable import tetmuxCore
@testable import tetmuxUI

/// `AppModel` decisions that need no channel and no AppKit. Everything here was previously
/// unreachable from the test bundle, which linked only `tetmuxCore`.
@MainActor
final class AppModelTests: XCTestCase {

    /// A per-test Application Support directory.
    ///
    /// Not a nicety. `AppModel` writes files as a side effect of ordinary operations — rebinding a
    /// chord persists `settings.json`, selecting a session schedules a `workspace.json` save — so a
    /// default-constructed model in a test writes the *user's* files. It did, once: running the app
    /// after this suite found the keymap from `testOnlyEditedBindingsAreStored` in it.
    ///
    /// It is a `nonisolated let` initialised in place rather than a `var` assigned in
    /// `setUpWithError`, because `XCTestCase`'s setUp and tearDown are *nonisolated* under Swift
    /// 6.1's XCTest — a `@MainActor` `var` cannot be touched from them, and the suite failed to
    /// compile on CI while building fine on a newer toolchain, where they are inferred isolated.
    /// The annotation is written out rather than left to the implicit rule for immutable `Sendable`
    /// storage, since that rule is the part that moved between the two. XCTest builds one instance
    /// per test method, so each test still gets a directory of its own.
    private nonisolated let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tetmux-model-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel() -> AppModel {
        AppModel(directory: directory)
    }

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

    /// The Dock menu tells the local host from the remote ones by `isLocal`, so the tests need a host
    /// that is genuinely not local rather than one with a different id.
    private func remoteHost(id: String, sessions: [TmuxSession]) -> HostState {
        HostState(
            config: HostConfig(id: id, name: id, isLocal: false),
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
        model.hosts = []
        XCTAssertNotNil(model.closeWindow(hostId: "nope", window: window("@1")))
    }

    // MARK: - Saying that a window is linked (F4.9)

    /// The close controls and `closeWindow` ask the same question, so a tooltip cannot promise
    /// something the click will not do.
    func testCloseOutcomeNamesWhereTheWindowSurvives() {
        let shared = window("@5", name: "build")
        let model = makeModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "one", windows: [shared], isAttached: true),
            TmuxSession(id: "$2", name: "two", windows: [shared]),
            TmuxSession(id: "$3", name: "three", windows: [shared]),
        ])]

        XCTAssertEqual(
            model.closeOutcome(hostId: "local", windowId: "@5", in: "$1"),
            .unlinks(remaining: ["two", "three"]),
            "the sessions it keeps running in are the ones it is not being removed from"
        )
        XCTAssertTrue(model.isLinked(hostId: "local", windowId: "@5"))
    }

    /// The other half, and the one that matters: this session is its only one, so closing is killing.
    func testCloseOutcomeSaysWhenClosingKills() {
        let only = window("@7", name: "build")
        let model = makeModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "one", windows: [only], isAttached: true),
        ])]

        XCTAssertEqual(model.closeOutcome(hostId: "local", windowId: "@7", in: "$1"), .kills)
        XCTAssertFalse(model.isLinked(hostId: "local", windowId: "@7"))
        XCTAssertTrue(
            model.closeDescription(hostId: "local", windowId: "@7", in: "$1", windowName: "build")
                .contains("ends what is running in it"),
            "the tooltip has to say that this one is irreversible"
        )
    }

    /// The tooltip names the sessions rather than counting them — "it stays in two and three" is
    /// checkable where "linked into 3 sessions" is a number the user then has to go and resolve.
    func testCloseDescriptionNamesTheSurvivingSessions() {
        let shared = window("@5", name: "build")
        let model = makeModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "one", windows: [shared], isAttached: true),
            TmuxSession(id: "$2", name: "two", windows: [shared]),
        ])]

        let description = model.closeDescription(
            hostId: "local", windowId: "@5", in: "$1", windowName: "build"
        )
        XCTAssertTrue(description.contains("keeps running in two"), description)
        XCTAssertFalse(description.contains("one"), "the session it is leaving is not one it survives in")
    }

    /// An unknown host is not silently "linked into nothing": `closeWindow` treats it as the case that
    /// asks, and the description has to agree with that rather than promising a safe unlink.
    func testAnUnknownHostIsDescribedAsTheCaseThatAsks() {
        let model = makeModel()
        model.hosts = []
        XCTAssertEqual(model.closeOutcome(hostId: "nope", windowId: "@1", in: nil), .kills)
        XCTAssertNotNil(model.closeWindow(hostId: "nope", window: window("@1")))
    }

    // MARK: - Who else is attached (F4.10)

    /// The confirmation reports the clients a kill would throw out — everyone but us.
    ///
    /// Our own channels are filtered because they are this application: counting them turns "you are
    /// alone in here" into "2 clients attached" and makes the warning worthless on the occasion it
    /// matters. Session-scoped for the same reason: a client attached to a different session of the
    /// same server loses nothing when this one dies.
    func testOtherClientsExcludesOurOwnChannelsAndOtherSessions() {
        let model = makeModel()
        var host = host(sessions: [
            TmuxSession(id: "$1", name: "one", windows: [window("@1")], isAttached: true),
            TmuxSession(id: "$2", name: "two", windows: [window("@2")]),
        ])
        host.clients = [
            TmuxClient(tty: "/dev/ttys009", sessionId: "$1", user: "ada"),
            TmuxClient(tty: "/dev/ttys001", sessionId: "$1", user: "me", isControlMode: true, isOurs: true),
            TmuxClient(tty: "/dev/ttys004", sessionId: "$1", user: "grace"),
            TmuxClient(tty: "/dev/ttys007", sessionId: "$2", user: "elsewhere"),
        ]
        model.hosts = [host]

        XCTAssertEqual(
            model.otherClients(hostId: "local", sessionId: "$1").map(\.tty),
            ["/dev/ttys004", "/dev/ttys009"],
            "ours is excluded, another session's is excluded, and the rest are ordered by tty"
        )
        XCTAssertEqual(model.otherClients(hostId: "local", sessionId: "$2").map(\.user), ["elsewhere"])
        XCTAssertTrue(model.otherClients(hostId: "local", sessionId: nil).isEmpty)
    }

    /// ⌥ skips the confirmation, so the tooltip is the only place the warning can appear — and it
    /// names the clients while there are few enough to name, exactly as `closeDescription` does.
    func testOtherClientsSummaryNamesThemAndIsSilentWhenWeAreAlone() {
        let model = makeModel()
        var host = host(sessions: [TmuxSession(id: "$1", name: "one", windows: [window("@1")])])
        host.clients = [TmuxClient(tty: "/dev/ttys001", sessionId: "$1", isOurs: true)]
        model.hosts = [host]

        XCTAssertNil(
            model.otherClientsSummary(hostId: "local", sessionId: "$1"),
            "a tooltip that reports the ordinary case says nothing"
        )

        host.clients.append(TmuxClient(tty: "/dev/ttys004", sessionId: "$1", user: "ada"))
        model.hosts = [host]
        XCTAssertEqual(
            model.otherClientsSummary(hostId: "local", sessionId: "$1"),
            "1 other client is attached (ada on /dev/ttys004)"
        )

        host.clients.append(TmuxClient(tty: "/dev/ttys005", sessionId: "$1", user: "grace"))
        host.clients.append(TmuxClient(tty: "/dev/ttys006", sessionId: "$1", user: "alan"))
        model.hosts = [host]
        XCTAssertEqual(
            model.otherClientsSummary(hostId: "local", sessionId: "$1"),
            "3 other clients are attached (ada on /dev/ttys004, grace on /dev/ttys005 and 1 more)"
        )
    }

    /// A client with no user — tmux below 3.3 has no `client_user` — is still a client, and is still
    /// named by the field tmux does have.
    func testAClientWithNoUserIsStillNamedByItsTty() {
        XCTAssertEqual(TmuxClient(tty: "/dev/ttys004", sessionId: "$1").displayName, "/dev/ttys004")
    }

    /// The close confirmation is raised only for a window in one session (F4.9), and it carries that
    /// session so the sheet can ask who else is in it. Without the id the sheet has nothing to look
    /// the clients up by and silently reports an empty list, which reads as "nobody is attached".
    func testACloseConfirmationCarriesTheSessionItWouldKillTheWindowIn() {
        let only = window("@7", name: "build")
        let model = makeModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$3", name: "one", windows: [only], isAttached: true),
        ])]

        let pending = model.closeWindow(hostId: "local", window: only)
        XCTAssertEqual(pending?.sessionId, "$3")
    }

    // MARK: - Default session names

    /// The first session on a host with none takes index 1, not 0.
    func testDefaultSessionNameStartsAtOne() {
        let model = makeModel()
        model.hosts = [host(sessions: [])]
        XCTAssertEqual(model.defaultSessionName(hostId: "local"), "tetmux_1")
    }

    /// A name already in use is skipped. tmux refuses a duplicate session name, and that refusal would
    /// surface as a failure banner for a command the user never typed a name for.
    func testDefaultSessionNameSkipsNamesAlreadyTaken() {
        let model = makeModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "tetmux_1", windows: [], isAttached: true),
            TmuxSession(id: "$2", name: "tetmux_2", windows: []),
        ])]
        XCTAssertEqual(model.defaultSessionName(hostId: "local"), "tetmux_3")
    }

    /// The lowest free index, not a running count: closing a session in the middle makes its name
    /// available again rather than leaving a permanent gap and climbing forever.
    func testDefaultSessionNameReusesAFreedIndex() {
        let model = makeModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "tetmux_1", windows: [], isAttached: true),
            TmuxSession(id: "$3", name: "tetmux_3", windows: []),
        ])]
        XCTAssertEqual(model.defaultSessionName(hostId: "local"), "tetmux_2")
    }

    // MARK: - New Window

    /// ⌘N takes after the window it was pressed in; the Dock's identically-titled item always shows
    /// the tree. Different rules on purpose — the Dock is reached from outside the app, often with
    /// nothing on screen, so there is no window to take after.
    ///
    /// The bug this replaces was neither rule: ⌘N sent no seed at all, so the tree fell to
    /// `.automatic` and came up collapsed however the asking window looked. Worth a test because
    /// both paths are one line and read as obviously right in isolation — the failure is only
    /// visible with the two windows side by side.
    func testCommandNTakesTheAskingWindowsSidebar() {
        let model = makeModel()

        let collapsed = WindowState()
        collapsed.sidebarVisibility = .detailOnly
        model.focus(collapsed)
        model.openNewAppWindowFromMenu()
        XCTAssertEqual(model.consumeSeed()?.sidebar, .collapsed)

        let shown = WindowState()
        shown.sidebarVisibility = .all
        model.focus(shown)
        model.openNewAppWindowFromMenu()
        XCTAssertEqual(model.consumeSeed()?.sidebar, .shown)
    }

    /// `.automatic` is a tree that is *showing*, so it inherits as shown. Comparing against `.all`
    /// instead would read it as collapsed and hide a sidebar the user can see — and `.automatic` is
    /// what a window has before anything sets it, so that would be the common case. It is the same
    /// rule `WorkspaceWindow` stores `sidebarShown` by.
    func testAutomaticCountsAsShowing() {
        let model = makeModel()
        let automatic = WindowState()
        automatic.sidebarVisibility = .automatic
        model.focus(automatic)
        model.openNewAppWindowFromMenu()
        XCTAssertEqual(model.consumeSeed()?.sidebar, .shown)
    }

    /// ⌘N from the menu bar with every window closed has nothing to take after, which is the Dock's
    /// situation reached another way: somewhere to navigate from.
    func testCommandNWithNoWindowShowsTheTree() {
        let model = makeModel()
        model.openNewAppWindowFromMenu()
        XCTAssertEqual(model.consumeSeed()?.sidebar, .shown)
    }

    /// The Dock's rule does not inherit, even when there is a window to inherit from.
    func testTheDocksNewWindowAlwaysShowsTheTree() {
        let model = makeModel()
        let collapsed = WindowState()
        collapsed.sidebarVisibility = .detailOnly
        model.focus(collapsed)
        model.openNewAppWindow()
        XCTAssertEqual(model.consumeSeed()?.sidebar, .shown)
    }

    /// Sessions the user named themselves are not in the way of the generated series.
    func testDefaultSessionNameIgnoresUnrelatedNames() {
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
        model.hosts = [twoSessionHost]

        let asking = WindowState()
        let other = WindowState()
        model.presentNewHost(in: asking)

        XCTAssertNotNil(asking.hostDraft)
        XCTAssertNil(other.hostDraft, "a second window would present the same editor at the same time")
    }

    /// A rename raised in one window must not put a sheet in front of another.
    func testARenameSheetIsScopedToItsWindow() {
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
        model.openWindow(WindowSeed(hostId: "local", sessionId: "$1"))

        XCTAssertTrue(model.claimWindowRequest(), "the first window to react should open one")
        XCTAssertFalse(model.claimWindowRequest(), "a second window would open a duplicate")
        XCTAssertFalse(model.claimWindowRequest())
    }

    /// And with no request outstanding nothing is claimed, so an unrelated redraw opens nothing.
    func testNothingIsClaimedWithoutARequest() {
        XCTAssertFalse(makeModel().claimWindowRequest())
    }

    /// With every window closed there is nobody left to claim the request, so the model performs it
    /// itself. Without this the menu bar extra — the whole reason the app stays alive with no windows
    /// — switches to a session and nothing appears, and the request sits set for good.
    func testAWindowRequestWithNothingOpenIsPerformedByTheModel() {
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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

    /// Moving a tab into a new session shows the result, and waits for the *tab* to get there.
    ///
    /// The wait is the point. The session is made by `new-session`, which insists on making a window
    /// of its own, so between the two commands there is a real snapshot in which the session exists
    /// and holds a stray shell — selecting on that one would put the placeholder on screen for a
    /// moment and then leave the window selecting a window that has been killed.
    func testMovingATabToANewSessionShowsItOnceTheTabIsThere() {
        let source = TmuxSession(
            id: "$1", name: "work",
            windows: [window("@1", panes: ["%1"]), window("@2", name: "two", panes: ["%2"])],
            isAttached: true
        )
        let model = makeModel()
        model.hosts = [host(sessions: [source])]
        let state = WindowState()
        model.registerWindow(state)
        model.select(in: state, host: "local", session: "$1", window: "@1")

        model.moveWindowToNewSession(hostId: "local", windowId: "@2", from: "$1", revealIn: state)

        // The session has arrived; the window has not. tmux's placeholder is what is in it.
        var shrunk = source
        shrunk.windows.removeAll { $0.id == "@2" }
        publish(model, [host(sessions: [
            shrunk,
            TmuxSession(
                id: "$2", name: "tetmux_1",
                windows: [window("@3", name: "tetmux-new-session", panes: ["%3"])], isAttached: false
            ),
        ])])
        XCTAssertEqual(state.selectedSessionId, "$1", "selected a session holding only the placeholder")

        publish(model, [host(sessions: [
            shrunk,
            TmuxSession(
                id: "$2", name: "tetmux_1",
                windows: [window("@2", name: "two", panes: ["%2"])], isAttached: false
            ),
        ])])
        XCTAssertEqual(state.selectedSessionId, "$2")
        XCTAssertEqual(state.selectedWindowId, "@2", "showed the session but not the tab that was moved")
        XCTAssertTrue(
            model.takeSessionExpansion(hostId: "local", sessionId: "$2"),
            "the tree should open the session the tab was moved into"
        )
    }

    // MARK: - The Dock menu
    //
    // The Dock is the app's only surface while it has no window and is not frontmost, and it used to
    // offer New Window alone. A window opened that way reconciles to the first host's *active*
    // session and window, which is very often the window already on screen — so the one item the Dock
    // had mostly produced a second view of what the user was already looking at.

    /// New Window is now a window to navigate *from*, which means the tree has to be showing.
    ///
    /// `.automatic` is not good enough and is what this replaces: it is AppKit deciding, and someone
    /// reaching for the Dock icon has no window in front of them and needs one they can find their
    /// way around from.
    func testTheDocksNewWindowAsksForOneWithTheTreeShowing() {
        let model = makeModel()
        model.hosts = [twoSessionHost]
        _ = openWindows(model, 1)

        model.openNewAppWindow()

        XCTAssertEqual(model.requestedWindow?.sidebar, .shown)
        XCTAssertNil(model.requestedWindow?.sessionId, "the selection is reconcile's job, not the seed's")
    }

    /// The seed can say all three things, which a `collapseSidebar` flag could not: a window opened
    /// onto one session hides the tree, the Dock's New Window shows it, and ⌘N asks for neither.
    func testASeedCanShowHideOrLeaveTheTreeAlone() {
        let state = WindowState()
        state.sidebarVisibility = .automatic

        state.apply(WindowSeed(sidebar: .unchanged))
        XCTAssertEqual(state.sidebarVisibility, .automatic, "no instruction must not become one")

        state.apply(WindowSeed(sidebar: .collapsed))
        XCTAssertEqual(state.sidebarVisibility, .detailOnly)

        state.apply(WindowSeed(sidebar: .shown))
        XCTAssertEqual(state.sidebarVisibility, .all, "a window opened to navigate from must show the tree")
    }

    /// New Local Session and each New Remote Session row are the same action with a different host,
    /// and both are `preferNewWindow`: the Dock is reached from outside the app, so there is no
    /// current window the user meant to retarget — often no window at all.
    func testADockSessionItemOpensItsOwnWindowForWhicheverHostItNames() {
        let model = makeModel()
        model.hosts = [host(sessions: []), remoteHost(id: "remote-1", sessions: [])]
        let state = WindowState()
        model.registerWindow(state)

        model.createSessionWithDefaultName(hostId: "remote-1", revealIn: nil, preferNewWindow: true)

        publish(model, [
            host(sessions: []),
            remoteHost(id: "remote-1", sessions: [
                TmuxSession(id: "$3", name: "tetmux_1", windows: [window("@4", panes: ["%4"])], isAttached: true),
            ]),
        ])

        XCTAssertEqual(model.requestedWindow?.hostId, "remote-1")
        XCTAssertEqual(model.requestedWindow?.sessionId, "$3")
        XCTAssertEqual(model.requestedWindow?.sidebar, .collapsed, "it has one thing to show")
        XCTAssertNil(
            state.selectedSessionId,
            "the open window must not be retargeted — the Dock did not mean that window"
        )
    }

    /// ⌥ on the menu bar's New Session means the session gets a window of its own. The window cannot
    /// be opened at the moment of asking — `new-session` answers with no id, so there is nothing to
    /// seed one with — so the request has to survive until tmux confirms the session.
    func testCreatingASessionInANewWindowAsksForOneWhenItArrives() {
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        let model = makeModel()
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
        XCTAssertEqual(ApplicationShortcut.newAppWindow.title, "New Window")
        XCTAssertEqual(ApplicationShortcut.newWindow.title, "New Tab")
    }

    /// The ⌘W family, which AppKit competes for and wins silently.
    ///
    /// ⌥⌘W belongs to `Close All`, the automatic alternate of AppKit's `Close`, and `Close Pane`
    /// asked for it anyway. Nothing failed loudly: AppKit kept our modifier mask and dropped the key
    /// character, so the Keys tab and the README advertised a chord that fired Close All instead.
    /// Measured before the fix — ⌥⌘W with two panes in one window left the panes at two and the
    /// macOS windows at zero. The app now removes AppKit's whole `.saveItem` group, which takes both
    /// `Close` and `Close All` out and frees ⌥⌘W along with ⌘W.
    ///
    /// This pins the *intent*. It cannot see a chord AppKit has stolen, because that happens in a
    /// live menu bar and not in this map — so a change here still wants checking against the running
    /// app, reading `AXMenuItemCmdChar`: a binding with a modifier mask and no character is the
    /// signature of exactly this bug.
    func testTheCloseFamilyMatchesTabbedMacApps() {
        let keymap = KeymapPolicy.default
        // ⌘W is the tab, as in Safari, Chrome, Terminal.app and iTerm2.
        XCTAssertEqual(keymap.binding(for: .closeWindow), KeyBinding("w"))
        // Not ⌥⌘W, which AppKit's Close All owns.
        XCTAssertEqual(keymap.binding(for: .closePane), KeyBinding("w", [.command, .control]))
        XCTAssertNotEqual(
            keymap.binding(for: .closePane), KeyBinding("w", [.command, .option]),
            "⌥⌘W is AppKit's Close All; a binding there is dropped without a word"
        )
        // The macOS window's ⇧⌘W is not in this map at all — it is the replacement item in
        // `CommandGroup(replacing: .saveItem)`, so nothing here may claim that chord either.
        for shortcut in ApplicationShortcut.allCases {
            guard let binding = keymap.binding(for: shortcut), binding.key == "w" else { continue }
            XCTAssertNotEqual(
                binding.modifiers, [.command, .shift],
                "\(shortcut) takes ⇧⌘W, which closes the macOS window"
            )
        }
    }

    /// The vocabulary, which is the thing that actually broke: a tmux window is a **Tab** in every
    /// user-facing string, and "Window" names the macOS window alone.
    ///
    /// It drifted twice before being pinned. The qualifier was applied to some commands and not
    /// others — "New tmux Window" beside a bare "Close Window…" for the same object — and "New
    /// Window" meant the macOS window in the menu bar while meaning the tmux one in the sidebar's
    /// session menu. Both read as correct in isolation, which is why this needs a test rather than
    /// care: the failure is only visible with two surfaces side by side.
    ///
    /// This deliberately replaced a check that *banned* the titles "New Tab"/"Close Tab", on the
    /// grounds that AppKit manages them. It does — under automatic window tabbing, which this app
    /// turns off. Confirmed against the running app: one "New Tab" in File at ⌘T, one "Close Tab…"
    /// in Session at ⇧⌘W, both enabled, and no AppKit-injected tab items anywhere in the bar.
    func testATmuxWindowIsCalledATabInEveryCommandTitle() {
        for shortcut in ApplicationShortcut.allCases {
            let title = shortcut.title
            XCTAssertFalse(
                title.contains("tmux Window"),
                "\(shortcut) still qualifies the old way; a tmux window is a Tab"
            )
            if shortcut != .newAppWindow {
                XCTAssertFalse(
                    title.contains("Window"),
                    "\(shortcut) says Window, which names the macOS window and only that"
                )
            }
        }
        // The tmux-window commands, all of them, by the one name.
        for shortcut in [
            ApplicationShortcut.newWindow, .closeWindow, .renameWindow, .nextWindow, .previousWindow,
        ] {
            XCTAssertTrue(
                shortcut.title.contains("Tab"),
                "\(shortcut) acts on a tmux window and must say Tab"
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

    /// The half of a named key that the display table cannot vouch for: a chord that reads correctly
    /// and matches nothing is worse than one that reads badly. `charactersIgnoringModifiers` for
    /// ⌃⌘Space really is `" "`, which is the same character the binding holds.
    func testTheSpaceChordMatchesTheEventItWasRecordedFrom() {
        let keymap = KeymapPolicy.default
        XCTAssertEqual(
            keymap.shortcut(for: keyEvent(" ", [.command, .control])),
            .copyModeStartSelection
        )
        XCTAssertEqual(
            KeyBinding(event: keyEvent(" ", [.command, .control])),
            KeyBinding(" ", [.command, .control]),
            "the recorder has to produce the binding the default map holds"
        )
        // Still exact about modifiers: a bare space belongs to the pane.
        XCTAssertNil(keymap.shortcut(for: keyEvent(" ", [])))
    }

    /// F4.21 — after the literal escape, even a bound chord belongs to the pane.
    func testLiteralEscapeLetsABoundChordThrough() {
        let keymap = KeymapPolicy.default
        XCTAssertEqual(keymap.shortcut(for: keyEvent("v", [.command])), .paste)
        XCTAssertNil(keymap.shortcut(for: keyEvent("v", [.command]), literalEscapeActive: true))
    }

    // MARK: - The editable keymap (F4.19)

    /// A chord has to survive `settings.json` and come back as the same chord, or a rebind is lost
    /// on the next launch and looks like a setting that does not stick.
    func testAChordRoundTripsThroughItsStoredForm() {
        for binding in [
            KeyBinding("k"),
            KeyBinding("w", [.command, .shift]),
            KeyBinding("]", [.command, .option]),
            KeyBinding("=", [.command]),
            // The one the `+` separator could eat.
            KeyBinding("+", [.command, .shift]),
            // …and the ones with no glyph of their own, which are stored by name.
            KeyBinding(" ", [.command, .control]),
            KeyBinding("\t", [.command]),
            KeyBinding(Character(UnicodeScalar(0xF700)!), [.command]),
        ] {
            let text = binding.storageString
            XCTAssertEqual(KeyBinding(storageString: text), binding, "round trip of \(text)")
        }
    }

    /// A shortcut nobody can read back is a shortcut nobody can check, which is most of what the
    /// settings table is for. Uppercasing the character rendered the space key as a chord ending in
    /// nothing, and an arrow key as a private-use codepoint the font draws as a box.
    func testKeysWithNoGlyphAreNamedTheWayMacOSNamesThem() {
        XCTAssertEqual(KeyBinding(" ", [.command, .control]).displayString, "⌃⌘Space")
        XCTAssertEqual(KeyBinding("\t", [.command]).displayString, "⌘⇥")
        XCTAssertEqual(KeyBinding(Character(UnicodeScalar(0xF700)!), [.command]).displayString, "⌘↑")
        XCTAssertEqual(KeyBinding("w", [.command, .shift]).displayString, "⇧⌘W")
    }

    /// `settings.json` is meant to be read and edited by hand (§2.3), so the stored form is the name
    /// rather than the character — a literal trailing space would not survive anyone looking at it.
    func testAKeyWithNoGlyphIsStoredByName() {
        XCTAssertEqual(KeyBinding(" ", [.command, .control]).storageString, "ctrl+cmd+space")
        XCTAssertEqual(KeyBinding(storageString: "ctrl+cmd+space"), KeyBinding(" ", [.command, .control]))
        // A name and a one-character key cannot collide: every name is longer than one character.
        XCTAssertEqual(KeyBinding(storageString: "cmd+s"), KeyBinding("s"))
    }

    func testAnUnparseableChordIsRejectedRatherThanGuessedAt() {
        XCTAssertNil(KeyBinding(storageString: "k"), "a chord with no modifier is not one")
        XCTAssertNil(KeyBinding(storageString: "meta+k"), "an unknown modifier name")
        XCTAssertNil(KeyBinding(storageString: "cmd+ab"), "the key is one character")
        XCTAssertNil(KeyBinding(storageString: ""))
    }

    /// F4.19/F4.20 — the application lives in `Cmd` space so everything else reaches the pane. A
    /// rebind that could take `Ctrl+K` would take kill-line away from every shell on every host.
    func testARebindOutsideCommandSpaceIsRefused() {
        let model = makeModel()
        XCTAssertEqual(
            model.rebind(.launcher, to: KeyBinding("k", [.control])),
            .notInCommandSpace
        )
        XCTAssertEqual(model.keymap.binding(for: .launcher), KeyBinding("k"), "the old binding stands")
    }

    /// Two commands on one chord means one of them silently stops working, since `shortcut(for:)`
    /// breaks the tie by the enum case's spelling. So it is refused at the point of being typed.
    func testARebindOntoATakenChordIsRefused() {
        let model = makeModel()
        XCTAssertEqual(model.rebind(.zoomPane, to: KeyBinding("k")), .conflict(.launcher))
        XCTAssertEqual(model.keymap.binding(for: .zoomPane), KeyBinding("z", [.command, .shift]))
        // The chord a shortcut already holds is not a conflict with itself.
        XCTAssertEqual(model.rebind(.launcher, to: KeyBinding("k")), .applied)
    }

    /// Only the difference from the defaults is written, so a later change to a default binding
    /// reaches everybody who never touched it.
    func testOnlyEditedBindingsAreStored() {
        let model = makeModel()
        XCTAssertTrue(model.keymap.overrides.isEmpty, "an untouched keymap stores nothing")

        XCTAssertEqual(model.rebind(.launcher, to: KeyBinding("j", [.command, .shift])), .applied)
        XCTAssertEqual(model.keymap.overrides, ["launcher": "shift+cmd+j"])

        // An unbinding is a decision too, and a null is how it is stated — distinct from a key that
        // was never edited.
        XCTAssertEqual(model.rebind(.find, to: nil), .applied)
        XCTAssertEqual(model.keymap.overrides["find"], .some(.none))
    }

    func testStoredOverridesRebuildTheKeymap() {
        let policy = KeymapPolicy.applying(overrides: [
            "launcher": "shift+cmd+j",
            "find": nil,
            // Ignored rather than fatal: this file is one the user is invited to edit.
            "nonsense": "cmd+q",
            "zoomPane": "ctrl+z",
        ])
        XCTAssertEqual(policy.binding(for: .launcher), KeyBinding("j", [.command, .shift]))
        XCTAssertNil(policy.binding(for: .find))
        XCTAssertEqual(
            policy.binding(for: .zoomPane), KeyBinding("z", [.command, .shift]),
            "a chord outside Cmd space is discarded, not applied"
        )
        XCTAssertEqual(policy.binding(for: .paste), KeyBinding("v"), "untouched bindings keep the default")
    }

    /// The whole point of persisting overrides: what comes back has to intercept the same chords.
    func testARebindChangesWhatIsIntercepted() {
        var policy = KeymapPolicy.applying(overrides: ["launcher": "shift+cmd+j"])
        XCTAssertEqual(policy.shortcut(for: keyEvent("j", [.command, .shift])), .launcher)
        XCTAssertNil(policy.shortcut(for: keyEvent("k", [.command])), "the old chord is free again")

        policy.rebind(.launcher, to: nil)
        XCTAssertNil(policy.shortcut(for: keyEvent("j", [.command, .shift])))
    }

    /// The recorder reads the event the same way the interception does, or a chord records as one
    /// thing and fires as another. ⇧⌘Y arrives with the character `Y`, upper case, because shift is
    /// held — a keymap that stored that would never match the event it was recorded from.
    func testARecordedChordMatchesTheEventItWasRecordedFrom() {
        let event = keyEvent("Y", [.command, .shift])
        guard let binding = KeyBinding(event: event) else { return XCTFail("no chord from the event") }
        XCTAssertEqual(binding, KeyBinding("y", [.command, .shift]))

        let policy = KeymapPolicy.applying(overrides: ["find": binding.storageString])
        XCTAssertEqual(policy.shortcut(for: event), .find)
    }

    /// The chord has to survive the file, not just the struct: `[String: String?]` is exactly the
    /// shape whose null values disappear if anything along the way uses a subscript assignment.
    func testKeymapOverridesSurviveTheSettingsFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tetmux-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)

        var policy = KeymapPolicy.default
        policy.rebind(.launcher, to: KeyBinding("j", [.command, .shift]))
        policy.rebind(.find, to: nil)
        await store.saveKeymapOverrides(policy.overrides)

        let reloaded = KeymapPolicy.applying(overrides: await SettingsStore(directory: directory).keymapOverrides())
        XCTAssertEqual(reloaded.binding(for: .launcher), KeyBinding("j", [.command, .shift]))
        XCTAssertNil(reloaded.binding(for: .find), "an unbound shortcut must not come back bound")
        XCTAssertEqual(reloaded.binding(for: .paste), KeyBinding("v"))
    }

    /// The other file, the same question: a window's place has to come back as the window's place.
    func testAWorkspaceSurvivesItsFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tetmux-workspace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let entries = [
            WorkspaceWindow(
                hostId: "local", sessionId: "$1", sessionName: "work",
                windowId: "@2", windowName: "vim", sidebarShown: false,
                frame: [10, 20, 900, 600]
            ),
            WorkspaceWindow(hostId: "remote", sessionId: "$4", sessionName: "build"),
        ]
        let saved = Workspace(
            windows: entries,
            watchedWindows: [WatchedWindow(hostId: "remote", windowId: "@9")],
            recents: [
                RecentTarget(hostId: "remote", sessionName: "build", windowId: "@9"),
                RecentTarget(hostId: "local"),
            ]
        )
        await WorkspaceStore(directory: directory).save(saved)
        let reloaded = await WorkspaceStore(directory: directory).load()
        XCTAssertEqual(reloaded, saved)
    }

    /// The file used to *be* the array of windows, and one written by a previous version is the
    /// ordinary state of every upgrade. Discarding it would greet the feature by throwing away the
    /// user's window arrangement.
    func testAWorkspaceWrittenBeforeTheEnvelopeStillLoads() {
        let json = Data(#"[{"hostId": "local", "sessionName": "work", "sidebarShown": false}]"#.utf8)
        let workspace = WorkspaceStore.decode(json)
        XCTAssertEqual(workspace.windows.count, 1)
        XCTAssertEqual(workspace.windows[0].sessionName, "work")
        XCTAssertFalse(workspace.windows[0].sidebarShown)
        XCTAssertTrue(workspace.watchedWindows.isEmpty)
    }

    /// …and one written after it, missing the new key, is the same case one layer up.
    func testAWorkspaceEnvelopeDecodesWithFieldsMissing() {
        let workspace = WorkspaceStore.decode(Data(#"{"windows": []}"#.utf8))
        XCTAssertTrue(workspace.windows.isEmpty)
        XCTAssertTrue(workspace.watchedWindows.isEmpty)
        XCTAssertTrue(workspace.recents.isEmpty)
    }

    /// A file written before a field existed, and one a person has edited down to the essentials,
    /// are the same case: one missing key must not discard the whole workspace.
    func testAWorkspaceEntryDecodesWithFieldsMissing() throws {
        let json = Data(#"[{"hostId": "local", "sessionName": "work"}]"#.utf8)
        let decoded = try JSONDecoder().decode([WorkspaceWindow].self, from: json)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].sessionName, "work")
        XCTAssertNil(decoded[0].windowId)
        XCTAssertTrue(decoded[0].sidebarShown, "the tree shows unless the file says otherwise")
    }

    // MARK: - Reordering tabs

    /// The rule every tab bar has: the dragged tab takes the target's position and the tabs between
    /// them shift by one. Which side of the target that is depends on the direction of travel, and
    /// getting it wrong makes a rightward drag by one position do nothing at all.
    func testDraggingATabRightwardsLandsAfterItsTarget() {
        let order = ["@1", "@2", "@3", "@4"]
        // @1 onto @3: @1 goes after @3, so it is inserted before @4.
        XCTAssertEqual(AppModel.dropDestination(order: order, dragged: "@1", onto: "@3"), .some("@4"))
        // Onto the last one there is nothing after it, so it lands at the end.
        XCTAssertEqual(AppModel.dropDestination(order: order, dragged: "@1", onto: "@4"), .some(nil))
    }

    func testDraggingATabLeftwardsLandsOnItsTarget() {
        let order = ["@1", "@2", "@3", "@4"]
        XCTAssertEqual(AppModel.dropDestination(order: order, dragged: "@4", onto: "@2"), .some("@2"))
        XCTAssertEqual(AppModel.dropDestination(order: order, dragged: "@3", onto: "@1"), .some("@1"))
    }

    func testDroppingATabOnItselfIsNotAMove() {
        // Compared against a typed `.none` rather than asserted nil: the result is a *double*
        // optional, and `XCTAssertNil` takes `Any?`, so the outer nil it is being asked about is the
        // one the coercion flattens away.
        XCTAssertEqual(AppModel.dropDestination(order: ["@1", "@2"], dragged: "@1", onto: "@1"), String??.none)
        XCTAssertEqual(AppModel.dropDestination(order: ["@1", "@2"], dragged: "@9", onto: "@1"), String??.none)
    }

    /// Adjacent tabs swap, in both directions — the ordinary case, and the one where an off-by-one
    /// in either branch shows up as a drag that does nothing.
    func testDraggingOntoAnAdjacentTabSwapsThem() {
        let order = ["@1", "@2", "@3"]
        XCTAssertEqual(AppModel.dropDestination(order: order, dragged: "@1", onto: "@2"), .some("@3"))
        XCTAssertEqual(AppModel.dropDestination(order: order, dragged: "@2", onto: "@1"), .some("@1"))
    }

    // MARK: - Workspace restoration

    /// A relaunch against a still-running tmux server matches on the id, which is exact.
    func testARestoredWindowFindsItsSessionById() {
        let state = WindowState()
        state.beginRestore(WorkspaceWindow(
            hostId: "local", sessionId: "$2", sessionName: "work", windowId: "@7", windowName: "vim"
        ))
        state.reconcile(with: [host(sessions: [
            TmuxSession(id: "$1", name: "other", windows: [window("@1")], isAttached: true),
            TmuxSession(id: "$2", name: "work", windows: [window("@7", name: "vim"), window("@8")]),
        ])])

        XCTAssertEqual(state.selectedSessionId, "$2")
        XCTAssertEqual(state.selectedWindowId, "@7")
        XCTAssertNil(state.pendingRestore, "a resolved restore is spent")
    }

    /// The server was restarted in between, so every id was reissued and matching on one would land
    /// on a stranger's session. The names are what survive.
    func testARestoredWindowFallsBackToTheSessionName() {
        let state = WindowState()
        state.beginRestore(WorkspaceWindow(
            hostId: "local", sessionId: "$2", sessionName: "work", windowId: "@7", windowName: "vim"
        ))
        state.reconcile(with: [host(sessions: [
            TmuxSession(id: "$9", name: "work", windows: [window("@3", name: "vim")], isAttached: true),
        ])])

        XCTAssertEqual(state.selectedSessionId, "$9")
        XCTAssertEqual(state.selectedWindowId, "@3")
        XCTAssertNil(state.pendingRestore)
    }

    /// A remote host has not been connected yet, so there is nothing to select — but the window must
    /// wait *there* rather than being pulled onto the first host in the list, which is where it would
    /// have to be dragged back from.
    func testARestoredWindowWaitsOnItsHostUntilTheSessionsArrive() {
        let state = WindowState()
        state.beginRestore(WorkspaceWindow(hostId: "remote", sessionId: "$1", sessionName: "work"))
        let local = host(sessions: [TmuxSession(id: "$1", name: "local", windows: [window("@1")], isAttached: true)])
        let remote = HostState(config: HostConfig(id: "remote", name: "remote"), connectionState: .disconnected)

        state.reconcile(with: [local, remote])
        XCTAssertEqual(state.selectedHostId, "remote")
        XCTAssertNotNil(state.pendingRestore, "still waiting: the session does not exist yet")

        let connected = HostState(
            config: HostConfig(id: "remote", name: "remote"),
            connectionState: .connected,
            sessions: [TmuxSession(id: "$1", name: "work", windows: [window("@4")], isAttached: true)],
            activeSessionId: "$1"
        )
        state.reconcile(with: [local, connected])
        XCTAssertEqual(state.selectedSessionId, "$1")
        XCTAssertEqual(state.selectedWindowId, "@4")
        XCTAssertNil(state.pendingRestore)
    }

    /// F4.26 — a session found on an idle host is offered by the launcher, as a session rather than
    /// as the windows it has not been asked about.
    ///
    /// The row acts even though the host is unreachable: F4.26's whole point is that the launcher
    /// works while a host is unreachable, and this row is the one that *makes* it reachable. It is
    /// marked as costing a connection, which is what the recession means now that no row is inert.
    func testTheLauncherOffersSessionsFoundWithoutAttaching() {
        let model = makeModel()
        var idle = HostState(
            config: HostConfig(id: "devbox", name: "devbox"),
            connectionState: .disconnected
        )
        idle.discoveredSessions = [TmuxSession(id: "$4", name: "deploy", isAttached: false)]
        model.hosts = [idle]

        let state = WindowState()
        model.registerWindow(state)
        let items = model.launcherItems(for: state)

        let row = try? XCTUnwrap(items.first { $0.title == "deploy" })
        XCTAssertEqual(row?.subtitle, "devbox (will connect)")
        XCTAssertEqual(row?.connectsFirst, true, "the words and the mark have to say the same thing")
        // …and it is one row, not one per window: the probe never asked about windows.
        XCTAssertEqual(items.filter { $0.title == "deploy" }.count, 1)
    }

    // MARK: - The launcher's ranking and its window row (F4.25/F4.26)

    /// A host with sessions that are known but out of reach: the shape the window row exists for.
    /// tmux's own topology survives a dropped link — those sessions are unreachable, not gone — which
    /// is exactly when somebody reaches for ⌘K to get back to what they were doing.
    private func idleHost(id: String, sessions: [TmuxSession]) -> HostState {
        HostState(
            config: HostConfig(id: id, name: id),
            connectionState: .disconnected,
            sessions: sessions
        )
    }

    /// F4.25 — "ranked by recency". Nothing recorded when anything was used, so the empty-query list
    /// was config order: the window somebody left thirty seconds ago sat wherever its host happened
    /// to be in `hosts.json`.
    func testTheLauncherRanksTheMostRecentlyUsedFirst() {
        let model = makeModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "work", windows: [window("@1", name: "edit"), window("@2", name: "logs")]),
        ])]
        let state = WindowState()
        model.registerWindow(state)

        // Config order to begin with: the host row, then its windows as the session lists them.
        XCTAssertEqual(model.launcherItems(for: state).map(\.title), ["local", "edit", "logs"])

        model.select(in: state, host: "local", session: "$1", window: "@2")
        XCTAssertEqual(model.launcherItems(for: state).map(\.title), ["logs", "local", "edit"])

        // …and the *second* use of something moves it rather than leaving a copy behind, which would
        // rank it lower the more it was used.
        model.select(in: state, host: "local", session: "$1", window: "@1")
        XCTAssertEqual(model.launcherItems(for: state).map(\.title), ["edit", "logs", "local"])
        XCTAssertEqual(model.recents.count, 2)
    }

    /// tmux numbers windows per *server*, so `@1` exists on every host at once — and two hosts is the
    /// ordinary case, not the odd one. A key without the host in it would have opening `@1` here
    /// promote `@1` on the other machine.
    func testRecencyIsHostQualified() {
        let model = makeModel()
        model.hosts = [
            host(sessions: [TmuxSession(id: "$1", name: "work", windows: [window("@1", name: "here")])]),
            remoteHost(id: "devbox", sessions: [
                TmuxSession(id: "$1", name: "work", windows: [window("@1", name: "there")]),
            ]),
        ]
        let state = WindowState()
        model.registerWindow(state)

        model.select(in: state, host: "devbox", session: "$1", window: "@1")

        let titles = model.launcherItems(for: state).map(\.title)
        XCTAssertEqual(titles.first, "there")
        XCTAssertEqual(
            model.recents, [RecentTarget(hostId: "devbox", sessionName: "work", windowId: "@1")],
            "the entry has to name the host, or it ranks the other machine's window too"
        )
    }

    /// The local host connects itself at launch (it is always reachable and cannot prompt), which is
    /// not the user using it. Stamping that would put it at the top of the list before anybody had
    /// touched anything.
    func testConnectingWithoutBeingAskedRanksNothing() {
        let model = makeModel()
        model.hosts = [host(sessions: [])]
        model.connect("local")
        XCTAssertTrue(model.recents.isEmpty)
    }

    /// Once a query is typed the score decides — but a tie keeps the recency order rather than
    /// whatever `sorted(by:)` left behind, which is not even repeatable: Swift's sort is not stable.
    func testATypedQueryOutranksRecencyAndTiesKeepIt() {
        let items = ["beta", "alpha", "alpine"].map {
            LauncherItem(title: $0, subtitle: "devbox", iconName: "square") {}
        }
        // Two rows scoring identically on "alp" come back in the order they were handed over.
        XCTAssertEqual(
            LauncherOverlay.matches("alp", in: items).map(\.title), ["alpha", "alpine"]
        )
        // …and a better match beats a more recent one: "beta" contains an "a" and is ranked first,
        // but the two that *start* with one score higher and go ahead of it.
        XCTAssertEqual(
            LauncherOverlay.matches("a", in: items).map(\.title), ["alpha", "alpine", "beta"]
        )
        XCTAssertEqual(LauncherOverlay.matches("", in: items).map(\.title), items.map(\.title))
    }

    /// F4.26 — the window row on an unreachable host connects first.
    ///
    /// It subtitled itself "(will connect)" while its action was a plain `select`, which connects
    /// nothing: the one row in the launcher whose words and click disagreed. The selection cannot be
    /// made at the moment of the click — there is no channel to make it on — so it waits, and lands
    /// when the topology arrives.
    func testTheLauncherWindowRowConnectsAnUnreachableHostAndThenLands() throws {
        let model = makeModel()
        model.hosts = [idleHost(id: "devbox", sessions: [
            TmuxSession(id: "$2", name: "build", windows: [window("@3", name: "make")]),
        ])]
        let state = WindowState()
        model.registerWindow(state)

        let row = try XCTUnwrap(model.launcherItems(for: state).first { $0.title == "make" })
        XCTAssertEqual(row.subtitle, "devbox › build (will connect)")
        XCTAssertTrue(row.connectsFirst)
        row.action()

        // The host is claimed immediately, so the window shows that host connecting rather than
        // sitting on whichever host the reconciler would otherwise pull it to.
        XCTAssertEqual(state.selectedHostId, "devbox")
        let pending = try XCTUnwrap(state.pendingRestore, "the target has to wait for a channel")
        XCTAssertEqual(pending.sessionId, "$2")
        XCTAssertEqual(pending.windowId, "@3")
        XCTAssertEqual(pending.sessionName, "build", "and by name, for a server restarted in between")
        XCTAssertEqual(pending.windowName, "make")

        // The connection lands, reissuing every id the way a restarted server does. The name is what
        // survives, and it is what the window comes back onto.
        let reconnected = HostState(
            config: HostConfig(id: "devbox", name: "devbox"),
            connectionState: .connected,
            sessions: [TmuxSession(id: "$9", name: "build", windows: [window("@8", name: "make")])],
            activeSessionId: "$9"
        )
        state.reconcile(with: [reconnected])

        XCTAssertEqual(state.selectedSessionId, "$9")
        XCTAssertEqual(state.selectedWindowId, "@8")
        XCTAssertNil(state.pendingRestore)
    }

    /// The same row on a host that *is* connected is an ordinary selection, with nothing left pending.
    func testTheLauncherWindowRowOnAReachableHostJustSelects() throws {
        let model = makeModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "work", windows: [window("@1", name: "edit"), window("@2", name: "logs")]),
        ])]
        let state = WindowState()
        model.registerWindow(state)

        let row = try XCTUnwrap(model.launcherItems(for: state).first { $0.title == "logs" })
        XCTAssertEqual(row.subtitle, "local › work", "nothing to promise: this one is reachable")
        XCTAssertFalse(row.connectsFirst)
        row.action()

        XCTAssertEqual(state.selectedSessionId, "$1")
        XCTAssertEqual(state.selectedWindowId, "@2")
        XCTAssertNil(state.pendingRestore)
    }

    /// A launcher result is reached without touching the tree, so the tree has to be moved to it: the
    /// row would otherwise highlight inside a session that is still collapsed, which is the selection
    /// being invisible in the one view whose job is to show it.
    func testTheLauncherOpensTheTreeOntoWhatItPicked() throws {
        let model = makeModel()
        model.hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "work", windows: [window("@1", name: "edit")]),
        ])]
        let state = WindowState()
        model.registerWindow(state)

        try XCTUnwrap(model.launcherItems(for: state).first { $0.title == "edit" }).action()

        XCTAssertTrue(model.takeSessionExpansion(hostId: "local", sessionId: "$1"))
    }

    /// …and when the host has to be connected first, once there is a session to open. The id cannot
    /// be the one the row was built from: a server restarted since that topology was read has
    /// reissued it, which is what the name fallback is for.
    func testTheTreeOpensOnceTheLauncherTargetLands() throws {
        let model = makeModel()
        model.hosts = [idleHost(id: "devbox", sessions: [
            TmuxSession(id: "$2", name: "build", windows: [window("@3", name: "make")]),
        ])]
        let state = WindowState()
        model.registerWindow(state)

        try XCTUnwrap(model.launcherItems(for: state).first { $0.title == "make" }).action()
        XCTAssertFalse(
            model.takeSessionExpansion(hostId: "devbox", sessionId: "$2"),
            "there is nothing to open yet, and $2 is an id from before the disconnection"
        )

        model.applyForTesting([HostState(
            config: HostConfig(id: "devbox", name: "devbox"),
            connectionState: .connected,
            sessions: [TmuxSession(id: "$9", name: "build", windows: [window("@8", name: "make")])],
            activeSessionId: "$9"
        )])

        XCTAssertEqual(state.selectedSessionId, "$9")
        XCTAssertTrue(model.takeSessionExpansion(hostId: "devbox", sessionId: "$9"))
    }

    /// The workspace restore shares that field and must not share this: every launch would open a
    /// node per restored window, which is not what anybody asked for by quitting the app.
    func testAWorkspaceRestoreLandingOpensNothing() {
        let model = makeModel()
        let state = WindowState()
        model.registerWindow(state)
        state.beginRestore(WorkspaceWindow(hostId: "local", sessionId: "$1", sessionName: "work"))

        model.applyForTesting([host(sessions: [
            TmuxSession(id: "$1", name: "work", windows: [window("@1")]),
        ])])

        XCTAssertEqual(state.selectedSessionId, "$1", "it still lands")
        XCTAssertFalse(model.takeSessionExpansion(hostId: "local", sessionId: "$1"))
    }

    /// A window picked while its host was unreachable must not be re-asserted after the user has
    /// changed their mind — the pending target is what `select` clears, and this is why it does.
    func testPickingSomethingElseDropsAWaitingLauncherTarget() throws {
        let model = makeModel()
        model.hosts = [
            idleHost(id: "devbox", sessions: [
                TmuxSession(id: "$2", name: "build", windows: [window("@3", name: "make")]),
            ]),
            host(sessions: [TmuxSession(id: "$1", name: "work", windows: [window("@1")])]),
        ]
        let state = WindowState()
        model.registerWindow(state)

        try XCTUnwrap(model.launcherItems(for: state).first { $0.title == "make" }).action()
        XCTAssertNotNil(state.pendingRestore)

        model.select(in: state, host: "local", session: "$1", window: "@1")
        XCTAssertNil(state.pendingRestore, "the user has said where this window belongs")
        XCTAssertEqual(state.selectedHostId, "local")
    }

    /// The file is documented as one a person may open and edit. A duplicated entry must rank
    /// something, not take the application down — `Dictionary(uniqueKeysWithValues:)` traps.
    func testAHandEditedDuplicateInTheRecentsIsHarmless() {
        let model = makeModel()
        model.hosts = [host(sessions: [TmuxSession(id: "$1", name: "work", windows: [window("@1", name: "edit")])])]
        let state = WindowState()
        model.registerWindow(state)

        let duplicate = RecentTarget(hostId: "local", sessionName: "work", windowId: "@1")
        model.applyRecentsForTesting([duplicate, duplicate])

        XCTAssertEqual(model.launcherItems(for: state).map(\.title).first, "edit")
    }

    /// Promotion is the half that is silently wrong: leave the old copy behind and the second use of
    /// anything ranks it lower than the first.
    func testPromotingMovesAnEntryAndBoundsTheList() {
        let a = RecentTarget(hostId: "local", sessionName: "work", windowId: "@1")
        let b = RecentTarget(hostId: "local", sessionName: "work", windowId: "@2")

        XCTAssertEqual(Workspace.promoting(a, in: [b, a]), [a, b])
        XCTAssertEqual(Workspace.promoting(a, in: [a]), [a])

        let many = (0..<Workspace.recentsLimit + 10).map {
            RecentTarget(hostId: "local", sessionName: "work", windowId: "@\($0)")
        }
        let bounded = many.reduce([RecentTarget]()) { Workspace.promoting($1, in: $0) }
        XCTAssertEqual(bounded.count, Workspace.recentsLimit)
        XCTAssertEqual(bounded.first, many.last, "most recently used first")
    }

    /// §4.6 — a restore onto a passthrough host lands rather than waiting, because what it is
    /// waiting for cannot happen.
    ///
    /// Found by running the app. A pending restore re-asserts its host on *every* snapshot until a
    /// session resolves, and a passthrough host has no sessions and will not grow any while it is in
    /// that mode — so clicking any other host in the tree was silently undone by the next topology
    /// change, and the window was pinned to that host for the life of the process. The host is kept,
    /// since it is the part of the entry that still means something.
    func testARestoreOntoAPassthroughHostStopsWaiting() {
        let state = WindowState()
        state.beginRestore(WorkspaceWindow(hostId: "old", sessionId: "$1", sessionName: "work"))
        let local = host(sessions: [TmuxSession(id: "$1", name: "local", windows: [window("@1")], isAttached: true)])
        var old = HostState(
            config: HostConfig(id: "old", name: "oldbox"),
            connectionState: .degraded(reason: "below the floor")
        )
        old.passthrough = PassthroughState(
            reason: .belowControlModeFloor(version: "2.3"), phase: .running, detail: ""
        )

        state.reconcile(with: [local, old])
        XCTAssertEqual(state.selectedHostId, "old")
        XCTAssertNil(state.pendingRestore, "nothing left to resolve to: this host has no sessions")

        // …and the window can now be moved somewhere else and stay there.
        state.selectedHostId = "local"
        state.reconcile(with: [local, old])
        XCTAssertEqual(state.selectedHostId, "local", "the restore pulled the window back")
    }

    /// The user has said where this window belongs, which outranks where it was last time — a
    /// pending restore left in place would move the window again when its host finally connected.
    func testSelectingSomethingCancelsAPendingRestore() {
        let model = makeModel()
        model.hosts = [host(sessions: [TmuxSession(id: "$1", name: "one", windows: [window("@1")], isAttached: true)])]
        let state = WindowState()
        state.beginRestore(WorkspaceWindow(hostId: "remote", sessionId: "$9", sessionName: "gone"))
        model.registerWindow(state)

        model.select(in: state, host: "local", session: "$1", window: "@1")
        XCTAssertNil(state.pendingRestore)
    }

    /// An unresolved restore is written back unchanged. Quitting before a remote host was ever
    /// connected must not replace the session the user wants with whatever the reconciler picked.
    func testAnUnresolvedRestoreIsWrittenBackRatherThanOverwritten() {
        let state = WindowState()
        let saved = WorkspaceWindow(hostId: "remote", sessionId: "$9", sessionName: "gone", sidebarShown: false)
        state.beginRestore(saved)
        state.selectedHostId = "local"
        state.selectedSessionId = "$1"

        XCTAssertEqual(state.workspaceEntry(in: []), saved)
    }

    func testAResolvedWindowIsRecordedWithBothItsIdAndItsName() {
        let hosts = [host(sessions: [
            TmuxSession(id: "$2", name: "work", windows: [window("@7", name: "vim")], isAttached: true),
        ])]
        let state = WindowState()
        state.selectedHostId = "local"
        state.selectedSessionId = "$2"
        state.selectedWindowId = "@7"

        let entry = state.workspaceEntry(in: hosts)
        XCTAssertEqual(entry.sessionId, "$2")
        XCTAssertEqual(entry.sessionName, "work")
        XCTAssertEqual(entry.windowId, "@7")
        XCTAssertEqual(entry.windowName, "vim")
        XCTAssertTrue(entry.sidebarShown)
    }

    /// A frame off every screen is a window the user cannot reach, and one saved there would come
    /// back invisible on every launch afterwards.
    func testAWorkspaceFrameIsOnlyUsedWhenItIsARealOne() {
        XCTAssertNil(WorkspaceWindow(frame: [0, 0, 0, 0]).rect)
        XCTAssertNil(WorkspaceWindow(frame: [10, 20]).rect)
        XCTAssertNil(WorkspaceWindow().rect)
        XCTAssertEqual(
            WorkspaceWindow(frame: [10, 20, 900, 600]).rect,
            NSRect(x: 10, y: 20, width: 900, height: 600)
        )
    }

    // MARK: - Activity notifications (F4.31)

    private func activeWindow(_ id: String, name: String = "build", active: Bool) -> TmuxWindow {
        var window = TmuxWindow(id: id, name: name)
        window.hasActivity = active
        return window
    }

    /// The event is the *transition*, and everything below is a way of getting that wrong.
    func testAWatchedWindowThatStartsPrintingIsReported() {
        let before = [host(sessions: [TmuxSession(id: "$1", name: "one", windows: [
            activeWindow("@1", active: false),
        ])])]
        let after = [host(sessions: [TmuxSession(id: "$1", name: "one", windows: [
            activeWindow("@1", active: true),
        ])])]

        let alerts = AppModel.newlyActive(
            from: before, to: after, watching: [WatchedWindow(hostId: "local", windowId: "@1")]
        )
        XCTAssertEqual(alerts.map(\.windowId), ["@1"])
    }

    /// `hasActivity` stays true until somebody looks at the window, so reporting on the value rather
    /// than the transition would re-fire on every topology snapshot — a job that printed once would
    /// notify for the rest of the afternoon.
    func testAWindowThatWasAlreadyActiveDoesNotFireAgain() {
        let snapshot = [host(sessions: [TmuxSession(id: "$1", name: "one", windows: [
            activeWindow("@1", active: true),
        ])])]

        let alerts = AppModel.newlyActive(
            from: snapshot, to: snapshot, watching: [WatchedWindow(hostId: "local", windowId: "@1")]
        )
        XCTAssertTrue(alerts.isEmpty)
    }

    func testAnUnwatchedWindowIsNeverReported() {
        let before = [host(sessions: [TmuxSession(id: "$1", name: "one", windows: [
            activeWindow("@1", active: false),
            activeWindow("@2", active: false),
        ])])]
        let after = [host(sessions: [TmuxSession(id: "$1", name: "one", windows: [
            activeWindow("@1", active: true),
            activeWindow("@2", active: true),
        ])])]

        let alerts = AppModel.newlyActive(
            from: before, to: after, watching: [WatchedWindow(hostId: "local", windowId: "@2")]
        )
        XCTAssertEqual(alerts.map(\.windowId), ["@2"])
    }

    /// tmux ids are per server, so a watch on `local`'s `@1` must say nothing about another host's.
    func testTheWatchDoesNotCrossHosts() {
        let before = [remoteHost(id: "build-box", sessions: [
            TmuxSession(id: "$1", name: "one", windows: [activeWindow("@1", active: false)]),
        ])]
        let after = [remoteHost(id: "build-box", sessions: [
            TmuxSession(id: "$1", name: "one", windows: [activeWindow("@1", active: true)]),
        ])]

        let alerts = AppModel.newlyActive(
            from: before, to: after, watching: [WatchedWindow(hostId: "local", windowId: "@1")]
        )
        XCTAssertTrue(alerts.isEmpty)
    }

    /// A window that has only just appeared has no previous value. Attaching to a server whose
    /// watched window is already active is not the same event as it becoming active, and treating it
    /// as one means a banner on every reconnect.
    func testAWindowSeenForTheFirstTimeIsNotReported() {
        let after = [host(sessions: [TmuxSession(id: "$1", name: "one", windows: [
            activeWindow("@1", active: true),
        ])])]

        let alerts = AppModel.newlyActive(
            from: [], to: after, watching: [WatchedWindow(hostId: "local", windowId: "@1")]
        )
        XCTAssertTrue(alerts.isEmpty)
    }

    /// A window linked into several sessions is one window (F4.9's subject) and appears once in each.
    /// Reporting per appearance would notify twice for one event.
    func testALinkedWindowIsReportedOnce() {
        let quiet = activeWindow("@5", active: false)
        let loud = activeWindow("@5", active: true)
        let before = [host(sessions: [
            TmuxSession(id: "$1", name: "one", windows: [quiet]),
            TmuxSession(id: "$2", name: "two", windows: [quiet]),
        ])]
        let after = [host(sessions: [
            TmuxSession(id: "$1", name: "one", windows: [loud]),
            TmuxSession(id: "$2", name: "two", windows: [loud]),
        ])]

        let alerts = AppModel.newlyActive(
            from: before, to: after, watching: [WatchedWindow(hostId: "local", windowId: "@5")]
        )
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.label, "build")
    }

    /// Watching is a toggle and it persists. The round trip through the file is covered separately;
    /// this is the decision.
    func testWatchingAWindowIsAToggle() {
        let model = makeModel()
        XCTAssertFalse(model.isWatching(hostId: "local", windowId: "@1"))
        model.toggleWatch(hostId: "local", windowId: "@1")
        XCTAssertTrue(model.isWatching(hostId: "local", windowId: "@1"))
        XCTAssertFalse(model.isWatching(hostId: "local", windowId: "@2"))
        model.toggleWatch(hostId: "local", windowId: "@1")
        XCTAssertFalse(model.isWatching(hostId: "local", windowId: "@1"))
    }

    // MARK: - The session-gone offer (F4.15)

    /// A window that had the session on screen when it ended is offered it back by name. Everything
    /// this asserts is a thing that is silently wrong when it is wrong: the offer either never
    /// appears, or appears over the wrong window with somebody else's session named in it.
    func testTheWindowThatWasInTheEndedSessionIsOfferedItBack() {
        var hosts = [host(sessions: [TmuxSession(id: "$1", name: "work", windows: [window("@1")])])]
        let state = WindowState()
        state.selectedHostId = "local"
        state.selectedSessionId = "$1"
        state.reconcile(with: hosts)

        // What the server ending looks like: the sessions are gone, not merely out of reach.
        hosts[0].sessions = []
        hosts[0].activeSessionId = nil
        hosts[0].connectionState = .disconnected
        hosts[0].endedSessionName = "work"

        XCTAssertEqual(state.recreatableSessionName(in: hosts[0]), "work")
    }

    /// A second window sitting on a different session of the same host gets the ordinary disconnected
    /// placeholder. Offering it "Recreate 'work'" would put a button in front of someone for a
    /// session that was never theirs.
    func testAWindowOnAnotherSessionIsNotOfferedTheRecreation() {
        var hosts = [host(sessions: [
            TmuxSession(id: "$1", name: "work", windows: [window("@1")]),
            TmuxSession(id: "$2", name: "spare", windows: [window("@2")]),
        ])]
        let state = WindowState()
        state.selectedHostId = "local"
        state.selectedSessionId = "$2"
        state.reconcile(with: hosts)

        hosts[0].sessions = []
        hosts[0].activeSessionId = nil
        hosts[0].connectionState = .disconnected
        hosts[0].endedSessionName = "work"

        XCTAssertNil(state.recreatableSessionName(in: hosts[0]))
    }

    /// tmux numbers and names sessions per server, so `work` on two machines is two different pieces
    /// of work — the remembered host has to be part of the match.
    func testTheOfferDoesNotCrossHosts() {
        let local = host(sessions: [TmuxSession(id: "$1", name: "work", windows: [window("@1")])])
        let state = WindowState()
        state.selectedHostId = "local"
        state.selectedSessionId = "$1"
        state.reconcile(with: [local])

        var other = remoteHost(id: "build-box", sessions: [])
        other.connectionState = .disconnected
        other.endedSessionName = "work"

        XCTAssertNil(state.recreatableSessionName(in: other))
    }

    /// A dropped link is not an ended session. The field is what tells them apart, and without it the
    /// placeholder must stay the plain one — this is the direction that matters, because an offer to
    /// recreate a session that is merely unreachable would make an empty one beside the user's.
    func testADroppedLinkOffersNothingToRecreate() {
        var hosts = [host(sessions: [TmuxSession(id: "$1", name: "work", windows: [window("@1")])])]
        let state = WindowState()
        state.selectedHostId = "local"
        state.selectedSessionId = "$1"
        state.reconcile(with: hosts)

        hosts[0].connectionState = .disconnected

        XCTAssertNil(state.recreatableSessionName(in: hosts[0]))
    }

    /// The offer belongs to the disconnected placeholder and nowhere else: while the host is
    /// reconnecting or connected there is either something in flight or something on screen.
    func testTheOfferIsOnlyMadeWhileDisconnected() {
        var hosts = [host(sessions: [TmuxSession(id: "$1", name: "work", windows: [window("@1")])])]
        let state = WindowState()
        state.selectedHostId = "local"
        state.selectedSessionId = "$1"
        state.reconcile(with: hosts)

        hosts[0].sessions = []
        hosts[0].endedSessionName = "work"
        hosts[0].connectionState = .connecting
        XCTAssertNil(state.recreatableSessionName(in: hosts[0]))

        hosts[0].connectionState = .reconnecting(attempt: 2, nextRetryInSeconds: 4)
        XCTAssertNil(state.recreatableSessionName(in: hosts[0]))
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

// MARK: - A session ending under a window

/// Closing the last tab of a session ends that session, and the window it was in must say so
/// rather than following the client somewhere else.
///
/// tmux moves an attached client when its session is destroyed, and the reconciler used to follow —
/// the window became a view of another session with no announcement. With the tree open that reads
/// as a jumping selection; with it collapsed the only signal is that the contents changed, which is
/// indistinguishable from the session having been replaced under you.
final class EndedSessionOfferTests: XCTestCase {

    private func connectedHost(sessions: [TmuxSession]) -> HostState {
        HostState(
            config: HostConfig(id: "local", name: "local", isLocal: true),
            connectionState: .connected,
            sessions: sessions,
            activeSessionId: sessions.first?.id
        )
    }

    private func session(_ id: String, _ name: String) -> TmuxSession {
        TmuxSession(id: id, name: name, windows: [TmuxWindow(id: "@1", name: "w")], isAttached: true)
    }

    @MainActor
    func testTheWindowStopsRatherThanFollowingToAnotherSession() {
        let state = WindowState()
        let before = connectedHost(sessions: [session("$1", "work"), session("$2", "other")])
        state.selectedHostId = "local"
        state.selectedSessionId = "$1"
        state.reconcile(with: [before])
        XCTAssertEqual(state.lastShownSessionName, "work")

        // `work` ends; tmux moves the client to `other`, which is what the host now reports active.
        let after = HostState(
            config: before.config, connectionState: .connected,
            sessions: [session("$2", "other")], activeSessionId: "$2"
        )
        state.reconcile(with: [after])

        XCTAssertNil(state.selectedSessionId, "it followed the client to another session")
        XCTAssertEqual(state.endedSessionName, "work")
        XCTAssertEqual(state.recreatableSessionName(in: after), "work")
        XCTAssertTrue(state.sessionEndedWhileHostLives(in: after))
        // What the view asks. `selectedSession` falls back to the host's active session, which is
        // the one tmux moved the client to, so the state being right is not enough.
        XCTAssertNil(state.selectedSession(in: [after]))
        XCTAssertNil(state.selectedWindow(in: [after]))
    }

    /// The user's report: three sessions, close the last tab of one, and the window shows a tab from
    /// another session. Replays the snapshots tmux actually produces, including the intermediate one
    /// where `%window-close` has been applied but `list-sessions` has not yet removed the session.
    @MainActor
    func testThreeSessionsClosingTheLastTabOfOne() {
        let state = WindowState()
        func host(_ sessions: [TmuxSession], active: String?) -> HostState {
            HostState(
                config: HostConfig(id: "local", name: "local", isLocal: true),
                connectionState: .connected, sessions: sessions, activeSessionId: active
            )
        }
        func sess(_ id: String, _ name: String, windows: [TmuxWindow]) -> TmuxSession {
            TmuxSession(id: id, name: name, windows: windows, isAttached: true)
        }
        let w1 = TmuxWindow(id: "@1", name: "w")

        // A: three sessions, this window on `work`.
        state.selectedHostId = "local"
        state.selectedSessionId = "$1"
        state.reconcile(with: [host([
            sess("$1", "work", windows: [w1]),
            sess("$2", "other", windows: [TmuxWindow(id: "@2", name: "w")]),
            sess("$3", "third", windows: [TmuxWindow(id: "@3", name: "w")]),
        ], active: "$1")])
        XCTAssertEqual(state.lastShownSessionName, "work")

        // B: %window-close applied — the session is still listed, with no windows.
        state.reconcile(with: [host([
            sess("$1", "work", windows: []),
            sess("$2", "other", windows: [TmuxWindow(id: "@2", name: "w")]),
            sess("$3", "third", windows: [TmuxWindow(id: "@3", name: "w")]),
        ], active: "$1")])

        // C: list-sessions catches up; tmux has moved the client to `other`.
        state.reconcile(with: [host([
            sess("$2", "other", windows: [TmuxWindow(id: "@2", name: "w")]),
            sess("$3", "third", windows: [TmuxWindow(id: "@3", name: "w")]),
        ], active: "$2")])

        XCTAssertNil(state.selectedSessionId, "followed the client to another session")
        XCTAssertEqual(state.endedSessionName, "work")
        // The assertion that matters, and the one whose absence let this ship broken: the *view*
        // asks `selectedSession(in:)`, which fell through `?? host.activeSession` to the session
        // tmux had moved the client to. The stored selection was correct the whole time and the
        // window still rendered another session's tabs.
        let current = [host([
            sess("$2", "other", windows: [TmuxWindow(id: "@2", name: "w")]),
            sess("$3", "third", windows: [TmuxWindow(id: "@3", name: "w")]),
        ], active: "$2")]
        XCTAssertNil(state.selectedSession(in: current), "the view would render another session")
        XCTAssertNil(state.selectedWindow(in: current), "and one of its tabs")
    }

    /// The fallback this suppresses is load-bearing everywhere else: a window that has never chosen
    /// a session shows what the host has active rather than an empty detail column.
    @MainActor
    func testAWindowWithNoSelectionStillShowsTheActiveSession() {
        let state = WindowState()
        state.selectedHostId = "local"
        let live = connectedHost(sessions: [session("$1", "work")])
        XCTAssertEqual(state.selectedSession(in: [live])?.id, "$1")
    }

    /// Answering the offer — by either button, or by picking a session in the tree — clears it.
    @MainActor
    func testLandingOnASessionAnswersTheOffer() {
        let state = WindowState()
        state.selectedHostId = "local"
        state.endedSessionName = "work"

        state.selectedSessionId = "$3"

        XCTAssertNil(state.endedSessionName)
    }

    /// The guard that keeps this honest. A dropped link leaves sessions listed but out of reach, and
    /// a server that restarted reissues its ids — so a `selectedSessionId` that no longer matches
    /// means "we cannot see it from here", not "it ended". Claiming otherwise would put a Recreate
    /// button over a session that is still running.
    @MainActor
    func testADisconnectedHostIsNotAnEndedSession() {
        let state = WindowState()
        let live = connectedHost(sessions: [session("$1", "work")])
        state.selectedHostId = "local"
        state.selectedSessionId = "$1"
        state.reconcile(with: [live])

        let dropped = HostState(
            config: live.config, connectionState: .disconnected,
            sessions: [session("$9", "work")], activeSessionId: "$9"
        )
        state.reconcile(with: [dropped])

        XCTAssertNil(state.endedSessionName, "a reissued id is not an ended session")
    }
}

// MARK: - Chord uniqueness

/// Two commands on one chord is not resolvable: `shortcut(for:)` breaks the tie by the enum case's
/// spelling, so one of them silently stops working and which one depends on how it was named.
///
/// Pinned because a new binding is exactly when this happens and nothing else would say so — the
/// menu still draws both items, both still show the chord, and only one of them ever fires.
final class KeymapUniquenessTests: XCTestCase {

    func testNoTwoDefaultBindingsShareAChord() {
        let keymap = KeymapPolicy.default
        var seen: [String: ApplicationShortcut] = [:]
        for shortcut in ApplicationShortcut.allCases {
            guard let binding = keymap.binding(for: shortcut) else { continue }
            let chord = binding.storageString
            if let other = seen[chord] {
                XCTFail("\(shortcut) and \(other) both take \(binding.displayString)")
            }
            seen[chord] = shortcut
        }
    }

    /// The one the menu bar cannot show: ⇧⌘W belongs to File ▸ Close Window, which is supplied by
    /// `CommandGroup(replacing: .saveItem)` and so is not in this map at all.
    func testNothingTakesTheMacOSWindowsCloseChord() {
        let keymap = KeymapPolicy.default
        for shortcut in ApplicationShortcut.allCases {
            guard let binding = keymap.binding(for: shortcut) else { continue }
            XCTAssertNotEqual(binding.storageString, "shift+cmd+w", "\(shortcut) takes ⇧⌘W")
        }
    }

    /// New Session exists as a command with a chord, which is what the app menu was missing: the
    /// Dock menu and the menu bar extra could both make one and the main menu could not.
    func testNewSessionIsBoundAndDistinctFromNewWindow() {
        let keymap = KeymapPolicy.default
        let session = keymap.binding(for: .newSession)
        XCTAssertEqual(session, KeyBinding("n", [.command, .shift]))
        XCTAssertNotEqual(session, keymap.binding(for: .newAppWindow))
        XCTAssertEqual(ApplicationShortcut.newSession.title, "New Session")
    }
}
