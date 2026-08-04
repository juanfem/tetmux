import XCTest
@testable import tetmuxCore
@testable import tetmuxUI

/// End-to-end over a real PTY and a real tmux server (§8, integration matrix). Skipped when tmux
/// is not installed so the suite still runs on a bare CI image.
final class SessionIntegrationTests: XCTestCase {
    private var sessionName = ""

    override func setUp() async throws {
        try XCTSkipIf(PtyTransport.resolveExecutable("tmux") == nil, "tmux is not installed")
        sessionName = "tetmux-test-\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() async throws {
        guard !sessionName.isEmpty else { return }
        runTmux(["kill-session", "-t", sessionName])
    }

    private func runTmux(_ arguments: [String]) {
        guard let tmux = PtyTransport.resolveExecutable("tmux") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Transport

    func testTransportSpawnsAndStreams() async throws {
        let transport = PtyTransport()
        let stream = try transport.spawn(executable: "/bin/echo", arguments: ["tetmux-transport-ok"])

        var received = Data()
        for try await chunk in stream {
            received.append(chunk)
        }
        XCTAssertTrue(String(decoding: received, as: UTF8.self).contains("tetmux-transport-ok"))
    }

    func testTransportReportsAFailedExec() async throws {
        let transport = PtyTransport()
        XCTAssertThrowsError(try transport.spawn(executable: "definitely-not-a-real-binary", arguments: [])) { error in
            guard case PtyError.executableNotFound = error else {
                return XCTFail("expected .executableNotFound, got \(error)")
            }
        }
    }

    func testTransportSurfacesANonZeroExit() async throws {
        let transport = PtyTransport()
        let stream = try transport.spawn(executable: "/bin/sh", arguments: ["-c", "exit 42"])
        do {
            for try await _ in stream {}
            XCTFail("expected the stream to throw")
        } catch let error as PtyError {
            guard case .childExited(let code) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(code, 42)
        }
    }

    /// The transport spawns from a process with a live Swift concurrency pool. A child that touches
    /// the Swift runtime between fork and exec can deadlock on the malloc lock and hang forever
    /// with no diagnostic, so spawn under concurrent load and insist every one completes.
    func testRepeatedSpawnsUnderConcurrencyDoNotHang() async throws {
        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let transport = PtyTransport()
                    let stream = try transport.spawn(executable: "/bin/echo", arguments: ["child-\(index)"])
                    var data = Data()
                    for try await chunk in stream { data.append(chunk) }
                    return String(decoding: data, as: UTF8.self)
                }
            }
            var seen = 0
            for try await output in group {
                XCTAssertTrue(output.contains("child-"), output)
                seen += 1
            }
            XCTAssertEqual(seen, 12)
        }
    }

    // MARK: - Session service

    func testConnectDiscoversTopologyAndEchoesInput() async throws {
        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)

        let host = try await waitForHost(service) { host in
            host.connectionState == .connected
                && host.tmuxVersion != nil
                && host.activeSession?.activeWindow?.layoutTree != nil
        }

        // Version probe (§3.4).
        XCTAssertNotNil(TmuxVersion(host.tmuxVersion ?? ""))

        // Topology: a session with one window with one pane, and a parsed layout tree.
        let session = try XCTUnwrap(host.activeSession)
        XCTAssertEqual(session.name, sessionName)
        let window = try XCTUnwrap(session.activeWindow)
        let paneId = try XCTUnwrap(window.preferredPaneId)
        XCTAssertTrue(paneId.hasPrefix("%"), "pane ids keep their sigil: \(paneId)")
        XCTAssertEqual(window.layoutTree?.paneIds, [paneId])
        XCTAssertFalse(window.panes.isEmpty, "list-panes should have populated the pane list")

        // Output plane: subscribing repaints from tmux's scrollback (F4.16), then send-keys
        // round-trips through the command plane and comes back as %output.
        let stream = await service.subscribeToPane(hostId: "local", paneId: paneId).stream
        let collected = Task { () -> String in
            var text = ""
            for await chunk in stream {
                text += String(decoding: chunk, as: UTF8.self)
                if text.contains("tetmux-echo-ok") { break }
            }
            return text
        }

        try await Task.sleep(for: .milliseconds(500))
        await service.sendKeys(hostId: "local", paneId: paneId, text: "echo tetmux-echo-ok\r")

        let output = try await withTimeout(seconds: 10) { await collected.value }
        XCTAssertTrue(output.contains("tetmux-echo-ok"), "never saw the echo; got:\n\(output)")

        await service.disconnectHost(hostId: "local")
    }

    /// Typed non-ASCII survives `send-keys -H` byte for byte.
    ///
    /// Keystrokes are delivered as hex, one pair per byte of UTF-8, so an accented letter or an emoji
    /// is several `send-keys` arguments rather than one. Modern tmux ORs `KEYC_LITERAL` for `-H` and
    /// passes each byte straight through, which makes that correct; older builds re-encoded each byte
    /// as a Unicode key and produced mojibake. Nothing here covered it either way — every existing
    /// round-trip test types ASCII — so the behaviour was an assumption rather than a fact.
    ///
    /// Sent as one batch on purpose: the flush coalesces a frame's keystrokes into a single
    /// `send-keys`, so this also covers a multi-byte character split across the hex list.
    func testNonAsciiKeystrokesRoundTripByteForByte() async throws {
        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)

        let host = try await waitForHost(service) { $0.activeSession?.activeWindow?.layoutTree != nil }
        let paneId = try XCTUnwrap(host.activeSession?.activeWindow?.preferredPaneId)

        // Two-byte, three-byte and four-byte UTF-8, plus a combining sequence.
        let payload = "héllo — 日本語 🎉 e\u{0301}"
        let stream = await service.subscribeToPane(hostId: "local", paneId: paneId).stream
        let collected = Task { () -> String in
            var text = ""
            for await chunk in stream {
                text += String(decoding: chunk, as: UTF8.self)
                if text.contains("tetmux-utf8:\(payload)") { break }
            }
            return text
        }

        try await Task.sleep(for: .milliseconds(500))
        await service.sendKeys(hostId: "local", paneId: paneId, text: "echo tetmux-utf8:\(payload)\r")

        let output = try await withTimeout(seconds: 10) { await collected.value }
        XCTAssertTrue(
            output.contains("tetmux-utf8:\(payload)"),
            "non-ASCII did not survive send-keys -H; got:\n\(output)"
        )

        await service.disconnectHost(hostId: "local")
    }

    func testSplittingAWindowUpdatesTheLayoutTree() async throws {
        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)

        let host = try await waitForHost(service) { $0.activeSession?.activeWindow?.layoutTree != nil }
        let paneId = try XCTUnwrap(host.activeSession?.activeWindow?.preferredPaneId)

        await service.splitPane(hostId: "local", paneId: paneId, leftRight: true)

        // The split is only real once tmux confirms it with %layout-change (F4.8).
        let after = try await waitForHost(service) { host in
            (host.activeSession?.activeWindow?.layoutTree?.paneIds.count ?? 0) == 2
        }
        let window = try XCTUnwrap(after.activeSession?.activeWindow)
        XCTAssertEqual(window.paneCount, 2)
        guard case .container(let direction, _, _, _, _, _) = try XCTUnwrap(window.layoutTree) else {
            return XCTFail("expected a container after splitting")
        }
        XCTAssertEqual(direction, .leftRight)

        await service.disconnectHost(hostId: "local")
    }

    /// Control mode only streams `%output` for the session the client is attached to. Selecting
    /// another session in the sidebar therefore has to move the client with `switch-client`;
    /// otherwise its panes render once from `capture-pane` and then sit frozen forever.
    func testSwitchingSessionsMovesTheClientAndResumesOutput() async throws {
        let other = "\(sessionName)-other"
        defer { runTmux(["kill-session", "-t", other]) }
        runTmux(["new-session", "-d", "-s", other])
        runTmux(["send-keys", "-t", other, "echo marker-in-other-session", "Enter"])

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)

        _ = try await waitForHost(service) { $0.sessions.contains { $0.name == other } }
        let host = try await waitForHost(service) { host in
            host.sessions.first { $0.name == other }?.activeWindow?.preferredPaneId != nil
        }
        let target = try XCTUnwrap(host.sessions.first { $0.name == other })
        let paneId = try XCTUnwrap(target.activeWindow?.preferredPaneId)

        await service.switchSession(hostId: "local", sessionId: target.id)

        // The client really moved: tmux reports the new session as the attached one.
        let switched = try await waitForHost(service, timeout: 10) { $0.activeSessionId == target.id }
        XCTAssertTrue(try XCTUnwrap(switched.sessions.first { $0.id == target.id }).isAttached)

        // And output for a pane in the newly attached session now flows.
        let stream = await service.subscribeToPane(hostId: "local", paneId: paneId).stream
        let collected = Task { () -> String in
            var text = ""
            for await chunk in stream {
                text += String(decoding: chunk, as: UTF8.self)
                if text.contains("switched-ok") { break }
            }
            return text
        }
        try await Task.sleep(for: .milliseconds(500))
        await service.sendKeys(hostId: "local", paneId: paneId, text: "echo switched-ok\r")

        let output = try await withTimeout(seconds: 10) { await collected.value }
        XCTAssertTrue(output.contains("switched-ok"), "no output after switching session; got:\n\(output)")

        await service.disconnectHost(hostId: "local")
    }

    /// A client per session on screen: both sessions stream at once, which one channel cannot do.
    ///
    /// This is the whole point of follower channels. With a single client, output arrives only for
    /// the attached session, so a second window on a second session was a photograph — and the only
    /// cure, `switch-client`, moved the freeze to the first window instead of removing it.
    func testTwoDisplayedSessionsBothStreamOutputAtOnce() async throws {
        let other = "\(sessionName)-second"
        defer { runTmux(["kill-session", "-t", other]) }
        runTmux(["new-session", "-d", "-s", other])

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)

        let host = try await waitForHost(service, timeout: 10) { host in
            host.sessions.first { $0.name == self.sessionName }?.activeWindow?.preferredPaneId != nil
                && host.sessions.first { $0.name == other }?.activeWindow?.preferredPaneId != nil
        }
        let first = try XCTUnwrap(host.sessions.first { $0.name == sessionName })
        let second = try XCTUnwrap(host.sessions.first { $0.name == other })
        let firstPane = try XCTUnwrap(first.activeWindow?.preferredPaneId)
        let secondPane = try XCTUnwrap(second.activeWindow?.preferredPaneId)

        // Both on screen, as two macOS windows would be.
        await service.setDisplayedSessions(["local": [first.id, second.id]])
        let live = try await waitForHost(service, timeout: 15) { host in
            host.liveSessionIds.isSuperset(of: [first.id, second.id])
        }
        XCTAssertTrue(live.isLive(second.id), "the second session never got a client")

        let firstStream = await service.subscribeToPane(hostId: "local", paneId: firstPane).stream
        let secondStream = await service.subscribeToPane(hostId: "local", paneId: secondPane).stream
        let firstText = collect(firstStream, until: "one-is-live")
        let secondText = collect(secondStream, until: "two-is-live")

        try await Task.sleep(for: .milliseconds(700))
        await service.sendKeys(hostId: "local", paneId: firstPane, text: "echo one-is-live\r")
        await service.sendKeys(hostId: "local", paneId: secondPane, text: "echo two-is-live\r")

        let one = try await withTimeout(seconds: 15) { await firstText.value }
        let two = try await withTimeout(seconds: 15) { await secondText.value }
        XCTAssertTrue(one.contains("one-is-live"), "the primary session stopped streaming; got:\n\(one)")
        XCTAssertTrue(two.contains("two-is-live"), "the second session never streamed; got:\n\(two)")

        await service.disconnectHost(hostId: "local")
    }

    /// A session put on screen counts as live from the moment it is asked for, not from the moment
    /// tmux answers.
    ///
    /// This is the banner flash: attaching is a round trip, and for its duration the honest answer
    /// is "no client here" — so the window showed "not attached" for a tenth of a second and then
    /// took it back, which reads as a glitch rather than as information.
    func testASessionIsLiveTheMomentItIsDisplayed() async throws {
        let other = "\(sessionName)-instant"
        defer { runTmux(["kill-session", "-t", other]) }
        runTmux(["new-session", "-d", "-s", other])

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)

        let host = try await waitForHost(service, timeout: 10) { host in
            host.sessions.contains { $0.name == other } && host.activeSessionId != nil
        }
        let first = try XCTUnwrap(host.sessions.first { $0.name == self.sessionName })
        let second = try XCTUnwrap(host.sessions.first { $0.name == other })

        await service.setDisplayedSessions(["local": [first.id, second.id]])
        // No waiting: the very next read of the model must already say both are live, because that
        // read is what a view about to draw a banner would do.
        let snapshot = await service.getHost("local")
        let immediately = try XCTUnwrap(snapshot)
        XCTAssertTrue(
            immediately.isLive(second.id),
            "the session was displayed and is not live yet — this is the frame the banner flashes in"
        )
        XCTAssertTrue(immediately.isLive(first.id))

        await service.disconnectHost(hostId: "local")
    }

    /// The wiring, end to end: two macOS windows on two sessions really do produce two tmux clients.
    ///
    /// Everything above tests `SessionService` directly. This one goes through `AppModel`, because
    /// the decision of what is on screen is made there — from every open window's selection — and a
    /// service that reconciles perfectly against a set nobody sends it would still leave the second
    /// window frozen.
    func testTheModelAsksForAClientPerWindowOnScreen() async throws {
        let other = "\(sessionName)-model"
        defer { runTmux(["kill-session", "-t", other]) }
        runTmux(["new-session", "-d", "-s", other])

        let model = await AppModel()
        let service = await model.service
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)

        let host = try await waitForHost(service, timeout: 10) { host in
            host.sessions.contains { $0.name == other } && host.sessions.contains { $0.name == self.sessionName }
        }
        let first = try XCTUnwrap(host.sessions.first { $0.name == self.sessionName })
        let second = try XCTUnwrap(host.sessions.first { $0.name == other })

        // Two windows, as ⌘N and a sidebar double-click would leave them.
        let windows = await MainActor.run { () -> [WindowState] in
            [first.id, second.id].map { sessionId in
                let state = WindowState()
                state.selectedHostId = "local"
                state.selectedSessionId = sessionId
                model.registerWindow(state)
                return state
            }
        }

        let live = try await waitForHost(service, timeout: 15) { host in
            host.liveSessionIds.isSuperset(of: [first.id, second.id])
        }
        XCTAssertTrue(live.isLive(second.id), "the second window's session never got a client")

        // And closing one hands its client back.
        await MainActor.run { model.unregisterWindow(windows[1].id) }
        _ = try await waitForHost(service, timeout: 15) { !$0.liveSessionIds.contains(second.id) }

        await service.disconnectHost(hostId: "local")
    }

    /// A session that leaves the screen takes its client with it. Otherwise every session ever looked
    /// at would keep a tmux client — and a `window-size manual` — for the life of the app.
    func testASessionThatLeavesTheScreenLosesItsClient() async throws {
        let other = "\(sessionName)-third"
        defer { runTmux(["kill-session", "-t", other]) }
        runTmux(["new-session", "-d", "-s", other])

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)

        let host = try await waitForHost(service, timeout: 10) { host in
            host.sessions.contains { $0.name == other } && host.sessions.contains { $0.name == self.sessionName }
        }
        let first = try XCTUnwrap(host.sessions.first { $0.name == self.sessionName })
        let second = try XCTUnwrap(host.sessions.first { $0.name == other })

        await service.setDisplayedSessions(["local": [first.id, second.id]])
        _ = try await waitForHost(service, timeout: 15) { $0.liveSessionIds.contains(second.id) }

        // The window showing it closed.
        await service.setDisplayedSessions(["local": [first.id]])
        let after = try await waitForHost(service, timeout: 15) { !$0.liveSessionIds.contains(second.id) }
        XCTAssertTrue(after.isLive(first.id), "the session still on screen must stay live")

        await service.disconnectHost(hostId: "local")
    }

    /// One window, two displayed sessions, one copy of the output.
    ///
    /// A window can be linked into several sessions (F4.9's whole subject), and each attached client
    /// streams `%output` for every pane it can see. With a client per displayed session that means
    /// two identical streams for the same pane, and painting both would double every byte the pane
    /// produces — a corrupted screen rather than a frozen one.
    func testAWindowLinkedIntoTwoDisplayedSessionsIsNotPaintedTwice() async throws {
        let other = "\(sessionName)-linked"
        defer { runTmux(["kill-session", "-t", other]) }
        runTmux(["new-session", "-d", "-s", other])

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)

        let host = try await waitForHost(service, timeout: 10) { host in
            host.sessions.first { $0.name == self.sessionName }?.activeWindow?.preferredPaneId != nil
                && host.sessions.contains { $0.name == other }
        }
        let first = try XCTUnwrap(host.sessions.first { $0.name == self.sessionName })
        let windowId = try XCTUnwrap(first.activeWindow?.id)
        let paneId = try XCTUnwrap(first.activeWindow?.preferredPaneId)

        // The same window, now in both sessions.
        runTmux(["link-window", "-s", windowId, "-t", other])
        let linked = try await waitForHost(service, timeout: 10) { host in
            host.sessions.first { $0.name == other }?.windows.contains { $0.id == windowId } == true
        }
        let second = try XCTUnwrap(linked.sessions.first { $0.name == other })

        await service.setDisplayedSessions(["local": [first.id, second.id]])
        _ = try await waitForHost(service, timeout: 15) { host in
            host.liveSessionIds.isSuperset(of: [first.id, second.id])
        }

        let stream = await service.subscribeToPane(hostId: "local", paneId: paneId).stream
        // Read for a fixed span rather than stopping at the marker. Stopping at the first hit is
        // exactly how this test can pass while the bug is present: the duplicate is the *second*
        // copy, and a reader that has already returned never sees it.
        let collector = OutputCollector()
        let reader = Task {
            for await chunk in stream { await collector.append(String(decoding: chunk, as: UTF8.self)) }
        }
        try await Task.sleep(for: .milliseconds(700))
        // The marker is assembled by the shell, so the line the tty echoes back does not contain it
        // and every occurrence counted here is one the pane actually produced.
        await service.sendKeys(hostId: "local", paneId: paneId, text: "echo dup$(echo -n check)\r")

        // Wait for the marker to arrive rather than for a fixed span: on a loaded machine three
        // seconds is not always enough for the *first* copy, and a reader that collected nothing
        // counts no duplicates and passes for the wrong reason. Then keep reading, because the
        // duplicate is the second copy and by definition arrives after the first.
        for _ in 0..<150 {
            if await collector.text.contains("dupcheck") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(2))
        reader.cancel()
        let output = await collector.text
        await service.disconnectHost(hostId: "local")

        let occurrences = output.components(separatedBy: "dupcheck").count - 1
        XCTAssertEqual(occurrences, 1, "the pane was painted by both clients; got:\n\(output)")
    }

    /// Reading a stream until a marker appears, so two of them can be in flight at once.
    private func collect(_ stream: AsyncStream<Data>, until marker: String) -> Task<String, Never> {
        Task {
            var text = ""
            for await chunk in stream {
                text += String(decoding: chunk, as: UTF8.self)
                if text.contains(marker) { break }
            }
            return text
        }
    }

    /// A pane subscription has to survive the channel it was made on. A view subscribes exactly
    /// once, when its `NSView` is made, and pane ids survive on the server across a drop — so the
    /// view is never rebuilt and never subscribes again. Ending the streams on teardown therefore
    /// left every pane frozen for the rest of the app's life after the first network blip, and did
    /// it silently: keystrokes still reached tmux, but nothing came back.
    func testPaneSubscriptionSurvivesAReconnect() async throws {
        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)

        let host = try await waitForHost(service) { $0.activeSession?.activeWindow?.layoutTree != nil }
        let paneId = try XCTUnwrap(host.activeSession?.activeWindow?.preferredPaneId)

        // Subscribe once, as a pane view does, and hold the *same* stream across the drop.
        let stream = await service.subscribeToPane(hostId: "local", paneId: paneId).stream
        let collected = Task { () -> String in
            var text = ""
            for await chunk in stream {
                text += String(decoding: chunk, as: UTF8.self)
                if text.contains("after-reconnect-ok") { break }
            }
            return text
        }

        try await Task.sleep(for: .milliseconds(500))

        // Stands in for the channel dying: the tmux client goes away, the server-side session and
        // its pane ids do not.
        await service.disconnectHost(hostId: "local")
        try await Task.sleep(for: .milliseconds(300))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        _ = try await waitForHost(service) { $0.connectionState == .connected }

        try await Task.sleep(for: .milliseconds(500))
        await service.sendKeys(hostId: "local", paneId: paneId, text: "echo after-reconnect-ok\r")

        let output = try await withTimeout(seconds: 10) { await collected.value }
        XCTAssertTrue(
            output.contains("after-reconnect-ok"),
            "the stream died with the channel; got:\n\(output)"
        )

        await service.disconnectHost(hostId: "local")
    }

    /// A reconnect has to land on the session the client was actually attached to, which is not
    /// necessarily the one it originally connected with: `switch-client` moves it. Reattaching to
    /// the original target instead strands the user on a session that gets no `%output` — its panes
    /// repaint once from scrollback and then never move again.
    func testReconnectReattachesToTheSessionTheClientWasSwitchedTo() async throws {
        let other = "\(sessionName)-other"
        defer { runTmux(["kill-session", "-t", other]) }
        runTmux(["new-session", "-d", "-s", other])

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)

        let host = try await waitForHost(service) { $0.sessions.contains { $0.name == other } }
        let target = try XCTUnwrap(host.sessions.first { $0.name == other })
        await service.switchSession(hostId: "local", sessionId: target.id)
        _ = try await waitForHost(service, timeout: 10) { $0.activeSessionId == target.id }

        // Drop the channel and bring it back the way the retry path does: no explicit target.
        await service.disconnectHost(hostId: "local")
        try await Task.sleep(for: .milliseconds(300))
        try await service.connectHost(hostId: "local")

        let after = try await waitForHost(service, timeout: 10) { host in
            host.connectionState == .connected && host.activeSession?.name != nil
        }
        XCTAssertEqual(
            after.activeSession?.name, other,
            "reconnected to the original target instead of the session the client was on"
        )

        await service.disconnectHost(hostId: "local")
    }

    /// `reconnectTarget` is a session *name*, so renaming the attached session has to move it with
    /// the rename. If it does not, the reconnect path runs `new-session -A -s <stale name>` and
    /// cheerfully creates an empty session under the old name — stranding the user in it while every
    /// real pane sits in the renamed session, which looks like "my work is gone" rather than a bug.
    func testReconnectFollowsARenameOfTheAttachedSession() async throws {
        let renamed = "\(sessionName)-renamed"
        defer { runTmux(["kill-session", "-t", renamed]) }

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)

        let original = sessionName
        let host = try await waitForHost(service) { $0.activeSession?.name == original }
        let sessionId = try XCTUnwrap(host.activeSessionId)

        await service.renameSession(hostId: "local", sessionId: sessionId, newName: renamed)
        _ = try await waitForHost(service, timeout: 10) { $0.activeSession?.name == renamed }

        // Drop and come back the way the retry path does: no explicit target.
        await service.disconnectHost(hostId: "local")
        try await Task.sleep(for: .milliseconds(300))
        try await service.connectHost(hostId: "local")

        let after = try await waitForHost(service, timeout: 10) { host in
            host.connectionState == .connected && host.activeSession?.name != nil
        }
        XCTAssertEqual(after.activeSession?.name, renamed, "reconnected to the pre-rename name")
        XCTAssertFalse(
            after.sessions.contains { $0.name == original },
            "the stale name was recreated as an empty session"
        )

        await service.disconnectHost(hostId: "local")
    }

    // MARK: - A session that ends on purpose

    /// Runs `body` against a tmux server of its own.
    ///
    /// Necessary rather than tidy: these tests are about what happens when the *last* session goes
    /// away, which on a shared server never happens, and about `attach-session` with no target —
    /// which on a developer's machine would cheerfully attach to their real work. `TMUX_TMPDIR` moves
    /// the socket, and `SessionService.childEnvironment` inherits the process environment, so the
    /// service's own spawns land on the same private server. Kept short: socket paths cap at 104
    /// bytes.
    private func withPrivateTmuxServer(_ body: () async throws -> Void) async throws {
        let directory = URL(fileURLWithPath: "/tmp/tetmux-t-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["TMUX_TMPDIR"]
        setenv("TMUX_TMPDIR", directory.path, 1)
        defer {
            runTmux(["kill-server"])
            if let previous { setenv("TMUX_TMPDIR", previous, 1) } else { unsetenv("TMUX_TMPDIR") }
            try? FileManager.default.removeItem(at: directory)
        }
        try await body()
    }

    /// Killing the session the client is attached to must not bring it back.
    ///
    /// It used to. `kill-session` ends the client, tmux says `%exit`, the channel closes — and the
    /// recovery path could not tell that from a dropped link, so it reconnected with
    /// `new-session -A -s <the name it had just been killed under>`, recreating the session with a
    /// fresh window in it. From the user's side the kill button appeared to open a new window.
    func testKillingTheAttachedSessionDoesNotRecreateIt() async throws {
        try await withPrivateTmuxServer {
            let survivor = "\(sessionName)-survivor"
            runTmux(["new-session", "-d", "-s", survivor])

            let service = SessionService()
            await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
            try await service.connectHost(hostId: "local", targetSession: sessionName)

            let attached = sessionName
            let host = try await waitForHost(service) { $0.activeSession?.name == attached }
            let doomed = try XCTUnwrap(host.sessions.first { $0.name == attached })

            await service.killSession(hostId: "local", sessionId: doomed.id)

            // The client has to end up on the session that is still there.
            //
            // Deliberately not `waitForHost`: that throws `XCTSkip` when it times out, and a skip is
            // exactly as green as a pass. A regression here has to be a failure.
            let landedOnSurvivor = try await waitFor(seconds: 15) {
                await service.getHost("local")?.activeSession?.name == survivor
            }
            XCTAssertTrue(landedOnSurvivor, "never attached to the session that outlived the kill")

            let state = await service.getHost("local")
            let after = try XCTUnwrap(state)
            XCTAssertFalse(
                after.sessions.contains { $0.name == attached },
                "the killed session came back — the reconnect recreated it"
            )
            // And tmux must agree: nothing recreated it behind our back either.
            let live = tmuxSessionNames()
            XCTAssertFalse(
                live.contains(attached),
                "tmux still has the killed session: \(live)"
            )
            XCTAssertEqual(live, [survivor], "the server should hold only the surviving session")

            await service.disconnectHost(hostId: "local")
        }
    }

    /// The Ctrl+D case: the last pane of the last window of the only session exits, so tmux has
    /// nothing left and the server goes with it.
    ///
    /// The host must simply be disconnected. Previously the backoff recreated the session — pressing
    /// Ctrl+D produced a *new* shell, which is the opposite of what the keystroke means.
    func testTheLastSessionEndingLeavesTheHostDisconnected() async throws {
        try await withPrivateTmuxServer {
            let service = SessionService()
            await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
            try await service.connectHost(hostId: "local", targetSession: sessionName)

            let attached = sessionName
            _ = try await waitForHost(service) { $0.activeSession?.name == attached }

            // The pane exiting of its own accord, exactly as Ctrl+D leaves it.
            runTmux(["send-keys", "-t", sessionName, "exit", "Enter"])

            // As above: a timeout here must fail rather than skip.
            let disconnected = try await waitFor(seconds: 20) {
                await service.getHost("local")?.connectionState == .disconnected
            }
            XCTAssertTrue(
                disconnected,
                "the host never settled as disconnected — it is still retrying, or it recreated the session"
            )

            let state = await service.getHost("local")
            let after = try XCTUnwrap(state)
            XCTAssertTrue(
                after.sessions.isEmpty,
                "sessions that no longer exist are still listed: \(after.sessions.map(\.name))"
            )
            // The decisive assertion: nothing was recreated on the server.
            XCTAssertNil(
                tmuxQuery(["list-sessions", "-F", "#{session_name}"]),
                "a session was recreated after the last one exited"
            )
        }
    }

    // MARK: - Paste

    /// Clipboard text is routinely multi-line, and control-mode commands are newline-framed: under
    /// single-quoted `set-buffer` the command ended at the first line break, tmux reported an
    /// unterminated string, and every following line of the paste was interpreted as a *command*.
    ///
    /// Checked by pasting into `cat > file` and comparing the bytes that actually landed — the only way
    /// to see what tmux's lexer made of the encoding. Lines are kept short because the pane's pty is in
    /// canonical mode, where a line over ~1 KB is dropped by the tty rather than by us.
    func testAMultiLinePasteArrivesIntact() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("tetmux-paste-\(UUID().uuidString.prefix(8)).txt")
        defer { try? FileManager.default.removeItem(at: destination) }

        // Every hazard the encoding has to survive, and over the 512-byte threshold so it takes the
        // buffer path rather than send-keys.
        var lines = [
            "first line",
            "cd $HOME && echo \"quoted\"",
            "#{session_name} is a tmux format",
            #"a backslash \ and a double \\ one"#,
            "tab\tseparated\tfields",
            "unicode: 日本語 🙂 👨‍👩‍👧‍👦",
            "'single quoted'",
            "$(id) and `hostname`",
        ]
        lines += (0..<20).map { "filler line \($0) — padding this past the paste threshold" }
        let text = lines.joined(separator: "\n") + "\n"
        XCTAssertGreaterThan(text.utf8.count, 512, "the fixture must exercise the buffer path")

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        let host = try await waitForHost(service) { $0.activeSession?.activeWindow?.layoutTree != nil }
        let paneId = try XCTUnwrap(host.activeSession?.activeWindow?.preferredPaneId)

        // `cat` writes stdin to the file verbatim and enables no bracketed-paste mode, so what the file
        // holds is what the pane received.
        await service.sendKeys(hostId: "local", paneId: paneId, text: "cat > \(destination.path)\r")
        try await Task.sleep(for: .milliseconds(700))

        await service.paste(hostId: "local", paneId: paneId, text: text)
        try await Task.sleep(for: .seconds(2))
        // C-d closes cat's stdin.
        await service.sendKeys(hostId: "local", paneId: paneId, bytes: [0x04])

        var written: String?
        for _ in 0..<30 {
            if let contents = try? String(contentsOf: destination, encoding: .utf8), !contents.isEmpty {
                written = contents
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        let arrived = try XCTUnwrap(written, "nothing was pasted at all")

        // The pane's tty turns the CRs paste-buffer sends back into newlines, so compare line by line
        // rather than byte for byte.
        let expectedLines = lines
        let arrivedLines = arrived.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(arrivedLines.count, expectedLines.count, "line count changed:\n\(arrived)")
        for (expected, actual) in zip(expectedLines, arrivedLines) {
            XCTAssertEqual(actual, expected)
        }
        // The specific corruptions the old encoding would have produced.
        XCTAssertFalse(arrived.contains(FileManager.default.homeDirectoryForCurrentUser.path),
                       "$HOME was expanded by tmux")
        XCTAssertTrue(arrived.contains("#{session_name}"), "a tmux format was expanded")

        await service.disconnectHost(hostId: "local")
    }

    // MARK: - Per-window geometry (F4.12)

    /// The mechanism a torn-off macOS window depends on: one client, two tmux windows, two different
    /// sizes. Control mode gives a client a single size, so without `window-size manual` plus a
    /// `resize-window` per window, the second macOS window would be stuck with the first one's grid.
    func testTwoWindowsOnOneClientTakeIndependentSizes() async throws {
        try XCTSkipIf(
            (TmuxVersion(installedTmuxVersion() ?? "") ?? TmuxVersion("0")!) < TmuxVersion("2.9")!,
            "per-window sizing needs tmux 2.9"
        )

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        _ = try await waitForHost(service) { $0.connectionState == .connected && $0.tmuxVersion != nil }

        await service.newWindow(hostId: "local", sessionId: nil)
        let host = try await waitForHost(service, timeout: 10) { host in
            (host.activeSession?.windows.count ?? 0) >= 2
                && host.activeSession?.windows.allSatisfy { $0.layoutTree != nil } == true
        }
        let session = try XCTUnwrap(host.activeSession)
        let first = session.windows[0].id
        let second = session.windows[1].id

        // Two macOS windows, each sizing the tmux window it is showing.
        let mainWindow = UUID()
        let detachedWindow = UUID()
        await service.requestWindowSize(hostId: "local", windowId: first, cols: 120, rows: 40, owner: mainWindow)
        await service.requestWindowSize(hostId: "local", windowId: second, cols: 70, rows: 20, owner: detachedWindow)

        let sized = try await waitForHost(service, timeout: 10) { host in
            guard let session = host.activeSession else { return false }
            return session.windows.first { $0.id == first }?.panes.first?.cols == 120
                && session.windows.first { $0.id == second }?.panes.first?.cols == 70
        }

        let sizedSession = try XCTUnwrap(sized.activeSession)
        let firstWindow = try XCTUnwrap(sizedSession.windows.first { $0.id == first }?.panes.first)
        let secondWindow = try XCTUnwrap(sizedSession.windows.first { $0.id == second }?.panes.first)
        XCTAssertEqual([firstWindow.cols, firstWindow.rows], [120, 40])
        XCTAssertEqual([secondWindow.cols, secondWindow.rows], [70, 20])

        await service.disconnectHost(hostId: "local")
    }

    /// One tmux window can be on screen in two macOS windows. Only the focused one may size it —
    /// otherwise each `%layout-change` prompts the other to ask for its own size back, and the window
    /// oscillates between the two forever.
    func testOnlyTheOwningViewCanSizeAWindow() async throws {
        try XCTSkipIf(
            (TmuxVersion(installedTmuxVersion() ?? "") ?? TmuxVersion("0")!) < TmuxVersion("2.9")!,
            "per-window sizing needs tmux 2.9"
        )

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        let host = try await waitForHost(service) { host in
            host.connectionState == .connected && host.tmuxVersion != nil
                && host.activeSession?.activeWindow?.layoutTree != nil
        }
        let windowId = try XCTUnwrap(host.activeSession?.activeWindow?.id)

        let focused = UUID()
        let background = UUID()
        await service.requestWindowSize(hostId: "local", windowId: windowId, cols: 100, rows: 30, owner: focused)
        _ = try await waitForHost(service, timeout: 10) { host in
            host.activeSession?.activeWindow?.panes.first?.cols == 100
        }

        // The unfocused view asking for its own size is ignored.
        await service.requestWindowSize(hostId: "local", windowId: windowId, cols: 65, rows: 18, owner: background)
        try await Task.sleep(for: .milliseconds(600))
        let latest = await service.getHost("local")
        let unchanged = try XCTUnwrap(latest?.activeSession?.activeWindow?.panes.first)
        XCTAssertEqual([unchanged.cols, unchanged.rows], [100, 30], "a background view resized the window")

        // Focus moves, and with it the right to size.
        await service.claimWindowSize(hostId: "local", windowId: windowId, owner: background)
        await service.requestWindowSize(hostId: "local", windowId: windowId, cols: 65, rows: 18, owner: background)
        let resized = try await waitForHost(service, timeout: 10) { host in
            host.activeSession?.activeWindow?.panes.first?.cols == 65
        }
        XCTAssertEqual(resized.activeSession?.activeWindow?.panes.first?.rows, 18)

        await service.disconnectHost(hostId: "local")
    }

    /// A view measures itself as soon as it appears, which is usually before the version probe has
    /// answered — and the version is what decides whether per-window sizing is available at all. The
    /// size asked for in that gap has to be remembered rather than dropped, or a freshly opened window
    /// stays at whatever size tmux gave it until the user resizes or refocuses it.
    func testASizeRequestedBeforeTheVersionIsKnownStillApplies() async throws {
        try XCTSkipIf(
            (TmuxVersion(installedTmuxVersion() ?? "") ?? TmuxVersion("0")!) < TmuxVersion("2.9")!,
            "per-window sizing needs tmux 2.9"
        )

        // The window id comes from tmux directly, so the request can go in before the channel has
        // learned anything — which is the only way to be inside the gap rather than after it.
        runTmux(["new-session", "-d", "-s", sessionName])
        let windowId = try XCTUnwrap(tmuxQuery(["list-windows", "-t", sessionName, "-F", "#{window_id}"]))
        XCTAssertTrue(windowId.hasPrefix("@"), "expected a window id with its sigil, got \(windowId)")

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        // No waiting at all: `connectHost` returns before the handshake, let alone the version probe.
        await service.requestWindowSize(
            hostId: "local", windowId: windowId, cols: 111, rows: 33, owner: UUID()
        )

        let sized = try await waitForHost(service, timeout: 10) { host in
            host.activeSession?.activeWindow?.panes.first?.cols == 111
        }
        XCTAssertEqual(sized.activeSession?.activeWindow?.panes.first?.rows, 33)

        await service.disconnectHost(hostId: "local")
    }

    /// `window-size manual` is a change to the user's own session and a manual size persists, so a
    /// deliberate disconnect has to put the option back — otherwise a later plain `tmux attach` finds
    /// windows that no longer follow the terminal.
    func testDisconnectingRestoresTheSessionWindowSizeOption() async throws {
        try XCTSkipIf(
            (TmuxVersion(installedTmuxVersion() ?? "") ?? TmuxVersion("0")!) < TmuxVersion("2.9")!,
            "per-window sizing needs tmux 2.9"
        )

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        _ = try await waitForHost(service) { $0.connectionState == .connected && $0.tmuxVersion != nil }

        // While attached, tetmux owns sizing.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(windowSizeOption(), "manual", "the policy was never applied")

        await service.disconnectHost(hostId: "local")

        // No polling: `disconnectHost` waits for tmux's `%end` before hanging the channel up, so the
        // option is already back by the time it returns. It used to write and terminate in the same
        // breath, which is a race the tmux client wins on an idle machine and loses on a loaded one —
        // so this passed locally and failed in CI, on the same commit that had passed there minutes
        // before. A poll here would hide that from the next person to break it.
        XCTAssertNotEqual(
            windowSizeOption(), "manual", "window-size was left at manual on the user's session"
        )
    }

    /// `show-options -w` inherits, so this reports the session's effective value.
    private func windowSizeOption() -> String? {
        guard let tmux = PtyTransport.resolveExecutable("tmux") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["show-options", "-t", sessionName, "window-size"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // "window-size manual", or nothing at all once the option is unset.
        return text.split(separator: " ").last.map(String.init)
    }

    /// The same tmux window shown in two macOS windows. The second view has to be painted from
    /// scrollback, because control mode will not resend anything for a pane that is merely sitting
    /// there — and that repaint must reach *only* the new view, since it begins by clearing the screen
    /// and the scrollback the first view is holding.
    func testASecondViewerOfAPaneIsPaintedWithoutDisturbingTheFirst() async throws {
        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        let host = try await waitForHost(service) { $0.activeSession?.activeWindow?.layoutTree != nil }
        let paneId = try XCTUnwrap(host.activeSession?.activeWindow?.preferredPaneId)

        // First view: subscribe and get something on screen.
        let firstStream = await service.subscribeToPane(hostId: "local", paneId: paneId).stream
        let firstView = Collector()
        let firstReader = Task { for await chunk in firstStream { await firstView.append(chunk) } }
        try await Task.sleep(for: .milliseconds(400))
        await service.sendKeys(hostId: "local", paneId: paneId, text: "echo first-viewer-marker\r")
        try await Task.sleep(for: .milliseconds(800))
        await firstView.mark()

        // Second view of the same pane, as a torn-off window is.
        let secondStream = await service.subscribeToPane(hostId: "local", paneId: paneId).stream
        let secondView = Collector()
        let secondReader = Task { for await chunk in secondStream { await secondView.append(chunk) } }
        try await Task.sleep(for: .seconds(1))

        let secondText = await secondView.text
        XCTAssertTrue(
            secondText.contains("first-viewer-marker"),
            "the second view never got its repaint; it would sit blank:\n\(secondText.debugDescription)"
        )

        let firstSinceMark = await firstView.textSinceMark
        XCTAssertFalse(
            firstSinceMark.contains("\u{1b}[3J"),
            "the second view's repaint cleared the first view's scrollback: \(firstSinceMark.debugDescription)"
        )

        firstReader.cancel()
        secondReader.cancel()
        await service.disconnectHost(hostId: "local")
    }

    // MARK: - Subscriptions (R3.8, tmux ≥ 3.2)

    /// A command started in a pane that is *not* current is reported, without any refresh.
    ///
    /// This is the gap subscriptions exist to close. `pane_current_command` is announced by nothing:
    /// it arrives only with a `list-panes`, and the refreshes that trigger one fire on renames and
    /// pane switches — so a background pane that started a long job kept its old label until
    /// something unrelated happened to refresh. The test deliberately never switches pane, renames
    /// anything, or splits after subscribing, so a `list-panes` has no reason to run.
    func testACommandInABackgroundPaneIsReportedWithoutARefresh() async throws {
        let version = try XCTUnwrap(TmuxVersion(installedTmuxVersion() ?? ""))
        try XCTSkipUnless(version.supportsSubscriptions, "subscriptions need tmux 3.2; have \(version.raw)")

        runTmux(["new-session", "-d", "-s", sessionName, "-x", "100", "-y", "30"])
        // A second pane, made before connecting so that nothing after the handshake changes topology.
        runTmux(["split-window", "-d", "-t", sessionName])

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)

        let host = try await waitForHost(service) { host in
            (host.activeSession?.activeWindow?.panes.count ?? 0) >= 2
        }
        let window = try XCTUnwrap(host.activeSession?.activeWindow)
        let current = window.activePaneId
        let background = try XCTUnwrap(window.panes.first { $0.id != current }?.id)

        // Started from outside the channel, in the pane that is not current.
        runTmux(["send-keys", "-t", background, "sleep 47", "Enter"])

        // `waitFor` plus an explicit assertion, never `waitForHost`: that one throws `XCTSkip` on
        // timeout, and a skip is exactly as green as a pass — which would retire the only test that
        // proves subscriptions are doing anything.
        let reported = try await waitFor(seconds: 10) {
            await service.getHost("local")?
                .activeSession?.activeWindow?.panes.first { $0.id == background }?.command == "sleep"
        }
        XCTAssertTrue(
            reported,
            "the background pane's command was never reported; subscriptions are not being applied"
        )

        runTmux(["send-keys", "-t", background, "C-c"])
        await service.disconnectHost(hostId: "local")
    }

    // MARK: - Stale client reconciliation (F4.17)

    /// An orphaned control-mode client is detached on attach; the user's own terminal is not.
    ///
    /// The orphan here is real rather than simulated: a second `tmux -CC` client is spawned on its
    /// own pty and then simply abandoned — never read, never closed — which is exactly the state an
    /// ssh link dropping leaves behind. tmux still counts it as attached, and below 2.9 that is what
    /// drags every window in the session down to the orphan's 80×24.
    func testAnOrphanedControlClientIsDetachedOnAttach() async throws {
        runTmux(["new-session", "-d", "-s", sessionName, "-x", "100", "-y", "30"])

        // The orphan. Held for the whole test so nothing but the reconciliation can end it.
        let orphan = PtyTransport()
        let orphanStream = try orphan.spawn(
            executable: try XCTUnwrap(PtyTransport.resolveExecutable("tmux")),
            arguments: TmuxCommand.localArguments(mode: .attach(sessionName: sessionName)),
            environment: Self.childLikeEnvironment(),
            initialSize: (cols: 80, rows: 24)
        )
        // The stream has to be held and drained. Dropping it releases the `AsyncThrowingStream`,
        // whose `onTermination` calls `terminate()` — so a discarded stream kills the very client the
        // test is about, and the test then fails saying nothing ever attached.
        let orphanDrain = Task { for try await _ in orphanStream {} }
        defer { orphanDrain.cancel(); orphan.terminate() }

        let session = sessionName
        let attached = try await waitFor(seconds: 10) {
            !Self.clientTtys(of: session).isEmpty
        }
        XCTAssertTrue(attached, "the orphan never attached, so there is nothing to reconcile")
        let orphanTtys = Set(Self.clientTtys(of: session))

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        _ = try await waitForHost(service) { $0.connectionState == .connected }

        // The orphan's tty is gone; ours is not. Asserted on the specific tty rather than on a count,
        // because "one client left" is also what detaching the wrong one looks like.
        let reconciled = try await waitFor(seconds: 10) {
            let now = Set(Self.clientTtys(of: session))
            return now.isDisjoint(with: orphanTtys) && !now.isEmpty
        }
        XCTAssertTrue(
            reconciled,
            "the orphan \(orphanTtys) was not detached; clients now \(Self.clientTtys(of: session))"
        )

        await service.disconnectHost(hostId: "local")
    }

    /// The other half: a plain `tmux attach` is not control mode and must never be touched, however
    /// stale it looks. `detachOtherClients` is still there for when the user asks for exactly that.
    func testAnOrdinaryTerminalClientIsLeftAlone() async throws {
        runTmux(["new-session", "-d", "-s", sessionName, "-x", "100", "-y", "30"])

        // A non-control client: `tmux attach` on a pty, with no `-CC`.
        let terminal = PtyTransport()
        let terminalStream = try terminal.spawn(
            executable: try XCTUnwrap(PtyTransport.resolveExecutable("tmux")),
            arguments: ["attach-session", "-t", sessionName],
            environment: Self.childLikeEnvironment(),
            initialSize: (cols: 80, rows: 24)
        )
        let terminalDrain = Task { for try await _ in terminalStream {} }
        defer { terminalDrain.cancel(); terminal.terminate() }

        let session = sessionName
        _ = try await waitFor(seconds: 10) { !Self.clientTtys(of: session).isEmpty }
        let terminalTtys = Set(Self.clientTtys(of: session))
        XCTAssertFalse(terminalTtys.isEmpty)

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        _ = try await waitForHost(service) { $0.connectionState == .connected }

        // Give reconciliation every chance to misbehave before asserting it did not.
        try await Task.sleep(for: .seconds(2))
        let survivors = Set(Self.clientTtys(of: session))
        XCTAssertTrue(
            terminalTtys.isSubset(of: survivors),
            "a plain terminal client was detached: had \(terminalTtys), now \(survivors)"
        )

        await service.disconnectHost(hostId: "local")
    }

    /// The environment the service itself would hand a channel. A hand-written minimal one is not
    /// enough — tmux inherits things from it that decide which server it even talks to.
    private static func childLikeEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        return env
    }

    /// Every client tty currently attached to `session`.
    ///
    /// Static so the polling closures in `waitFor`, which are `@Sendable`, can call it without
    /// capturing the (non-Sendable) test case.
    private static func clientTtys(of session: String) -> [String] {
        guard let tmux = PtyTransport.resolveExecutable("tmux") else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["list-clients", "-t", session, "-F", "#{client_tty}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Closing a window (F4.9)

    /// Closing a tab must never end what is running. A window linked to two sessions leaves the one
    /// it was closed in and carries on in the other — the pane keeps its pid, so this checks the
    /// process itself survived rather than merely that a window with the same name still exists.
    func testUnlinkingAWindowLeavesItRunningInItsOtherSession() async throws {
        let other = "\(sessionName)-linked"
        defer { runTmux(["kill-session", "-t", other]) }
        runTmux(["new-session", "-d", "-s", other])

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        let host = try await waitForHost(service) { $0.activeSession?.activeWindow?.layoutTree != nil }
        let windowId = try XCTUnwrap(host.activeSession?.activeWindow?.id)
        let paneId = try XCTUnwrap(host.activeSession?.activeWindow?.preferredPaneId)

        // Link the window into the second session, which is the case `unlink-window` exists for.
        runTmux(["link-window", "-s", windowId, "-t", "\(other):"])
        let pid = try XCTUnwrap(
            tmuxQuery(["display-message", "-p", "-t", paneId, "#{pane_pid}"]),
            "could not read the pane's pid"
        )

        await service.unlinkWindow(hostId: "local", windowId: windowId)

        // Gone from the session it was closed in…
        //
        // "Gone" includes the session itself going: this window was that session's only one, and tmux
        // destroys a session left with none. That is worth stating explicitly, because the predicate
        // used to be `session?.windows.contains(...) == false`, which a *missing* session fails — and
        // it passed anyway only because the recovery path used to resurrect the session under its old
        // name. When that stopped happening this test was the first thing to notice.
        let closedIn = sessionName
        let leftTheSession = try await waitFor(seconds: 10) {
            guard let host = await service.getHost("local") else { return false }
            guard let session = host.sessions.first(where: { $0.name == closedIn }) else { return true }
            return !session.windows.contains { $0.id == windowId }
        }
        XCTAssertTrue(leftTheSession, "the window is still listed in the session it was closed in")
        // …and still running in the other, with the same process behind it. Filtered rather than
        // listed: that session has a window of its own, so the first line of a plain listing is not
        // the one under test.
        let survivor = tmuxQuery([
            "list-windows", "-t", other,
            "-f", "#{==:#{window_id},\(windowId)}", "-F", "#{window_id}",
        ])
        XCTAssertEqual(survivor, windowId, "the window did not survive in its other session")
        XCTAssertEqual(
            tmuxQuery(["display-message", "-p", "-t", paneId, "#{pane_pid}"]), pid,
            "closing a tab killed the process (F4.9)"
        )

        await service.disconnectHost(hostId: "local")
    }

    /// The other half of F4.9: tmux refuses to unlink a window from its only session, which is why
    /// that case has to stop and ask rather than silently doing nothing. If this ever starts
    /// succeeding, the confirmation is no longer needed and the close path should just unlink.
    func testTmuxRefusesToUnlinkAWindowFromItsOnlySession() async throws {
        runTmux(["new-session", "-d", "-s", sessionName])
        let windowId = try XCTUnwrap(tmuxQuery(["list-windows", "-t", sessionName, "-F", "#{window_id}"]))

        let service = SessionService()
        let sink = LogSink()
        await service.setDiagnosticLogger { message in
            Task { await sink.append(message) }
        }
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        _ = try await waitForHost(service) { $0.activeSession?.activeWindow?.layoutTree != nil }

        await service.unlinkWindow(hostId: "local", windowId: windowId)

        let refused = try await waitFor(seconds: 10) { await sink.contains("only linked to one session") }
        let log = await sink.text
        XCTAssertTrue(refused, "tmux no longer refuses this; the close path can be simplified:\n\(log)")
        XCTAssertNotNil(
            tmuxQuery(["list-windows", "-t", sessionName, "-F", "#{window_id}"]),
            "the window was destroyed by a refused unlink"
        )

        await service.disconnectHost(hostId: "local")
    }

    // MARK: - Command failures (§7)

    /// A command the user asked for that tmux refused has to say so. Before this it went to the
    /// diagnostic logger, which only `--diagnose` installs — so in the app the rename simply did not
    /// happen and nothing anywhere said why.
    func testARefusedUserCommandIsReportedVerbatim() async throws {
        let taken = "\(sessionName)-taken"
        defer { runTmux(["kill-session", "-t", taken]) }
        runTmux(["new-session", "-d", "-s", taken])

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        let host = try await waitForHost(service) { $0.activeSession != nil }
        let sessionId = try XCTUnwrap(host.activeSession?.id)

        // Renaming onto a name that is already taken is the most ordinary way to meet `%error`.
        await service.renameSession(hostId: "local", sessionId: sessionId, newName: taken)

        let reported = try await waitForHost(service, timeout: 10) { $0.lastCommandFailure != nil }
        let failure = try XCTUnwrap(reported.lastCommandFailure)
        XCTAssertEqual(failure.action, "Rename session")
        XCTAssertTrue(
            failure.message.contains("duplicate session"),
            "tmux's own words should survive to the UI, got: \(failure.message.debugDescription)"
        )

        await service.dismissCommandFailure(hostId: "local")
        let dismissed = try await waitForHost(service, timeout: 5) { $0.lastCommandFailure == nil }
        XCTAssertNil(dismissed.lastCommandFailure)

        await service.disconnectHost(hostId: "local")
    }

    /// Only the user's commands. tmux refuses plenty of things we ask it on our own account, and a
    /// banner for an internal probe is noise the user can do nothing about.
    func testAnInternalCommandFailureIsNotShownToTheUser() async throws {
        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        _ = try await waitForHost(service) { $0.activeSession?.activeWindow?.layoutTree != nil }

        // A repaint of a pane that no longer exists: internal, expected, and handled by retrying.
        await service.repaintPane(hostId: "local", paneId: "%99999")
        try await Task.sleep(for: .seconds(1))

        let host = await service.getHost("local")
        let failure = host?.lastCommandFailure
        XCTAssertNil(failure, "an internal command's refusal reached the UI: \(String(describing: failure))")

        await service.disconnectHost(hostId: "local")
    }

    // MARK: - Backpressure (P6.5)

    /// A viewer that stops painting must not turn into unbounded memory.
    ///
    /// tmux keeps running a pane whether or not anyone is reading it, so `%output` for a pane whose
    /// view has stalled has nowhere to go but a queue that grows for as long as the pane keeps
    /// talking — `yes` is the one-word reproducer. The pane is paused instead, and resumed once the
    /// viewer acknowledges what it has painted.
    ///
    /// Deliberately never reads the stream: that is exactly what a stalled viewer looks like from the
    /// service's side, and reading it would make the test measure nothing.
    func testAStalledViewerPausesItsPaneAndResumingRepaintsIt() async throws {
        try XCTSkipIf(
            (TmuxVersion(installedTmuxVersion() ?? "") ?? TmuxVersion("0")!) < TmuxVersion("3.2")!,
            "control-mode flow control needs tmux 3.2"
        )

        let service = SessionService()
        let sink = LogSink()
        await service.setDiagnosticLogger { message in
            Task { await sink.append(message) }
        }
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)

        let host = try await waitForHost(service) { $0.activeSession?.activeWindow?.layoutTree != nil }
        let paneId = try XCTUnwrap(host.activeSession?.activeWindow?.preferredPaneId)

        let subscription = await service.subscribeToPane(hostId: "local", paneId: paneId)
        try await Task.sleep(for: .milliseconds(400))

        // Comfortably past the high-water mark, and fast enough that it is all in flight before any
        // of it could be drained by a reader that does not exist.
        await service.sendKeys(hostId: "local", paneId: paneId, text: "yes tetmux-backpressure | head -n 400000\r")

        let paused = try await waitFor(seconds: 20) { await sink.contains("pausing \(paneId)") }
        let logAfterPause = await sink.text
        XCTAssertTrue(
            paused,
            "a pane nobody is reading was never paused; it would queue without bound:\n\(logAfterPause)"
        )

        // The viewer catches up. Acknowledging more than is outstanding is the honest way to say
        // "everything painted" — the service clamps at zero.
        await service.acknowledge(hostId: "local", paneId: paneId, subscriber: subscription.id, bytes: 1 << 30)

        let resumed = try await waitFor(seconds: 20) { await sink.contains("resuming \(paneId)") }
        let logAfterResume = await sink.text
        XCTAssertTrue(
            resumed,
            "the pane stayed paused after its viewer caught up; it would never move again:\n\(logAfterResume)"
        )

        await service.disconnectHost(hostId: "local")
    }

    /// The pane keeps working after all of that. A pause that is not cleanly undone leaves a pane
    /// that takes keystrokes and answers nothing, which is the failure this whole mechanism would
    /// otherwise introduce.
    func testAPanePausedAndResumedStillDeliversOutput() async throws {
        try XCTSkipIf(
            (TmuxVersion(installedTmuxVersion() ?? "") ?? TmuxVersion("0")!) < TmuxVersion("3.2")!,
            "control-mode flow control needs tmux 3.2"
        )

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)

        let host = try await waitForHost(service) { $0.activeSession?.activeWindow?.layoutTree != nil }
        let paneId = try XCTUnwrap(host.activeSession?.activeWindow?.preferredPaneId)

        let subscription = await service.subscribeToPane(hostId: "local", paneId: paneId)
        let collected = Collector()
        try await Task.sleep(for: .milliseconds(400))

        // Stall, overrun, then start reading again — the sequence a window that was occluded and then
        // brought back to the front produces.
        await service.sendKeys(hostId: "local", paneId: paneId, text: "yes tetmux-backpressure | head -n 400000\r")
        try await Task.sleep(for: .seconds(3))

        let reader = Task {
            for await chunk in subscription.stream {
                await collected.append(chunk)
                await service.acknowledge(
                    hostId: "local", paneId: paneId, subscriber: subscription.id, bytes: chunk.count
                )
            }
        }
        // Everything the stalled period left behind, plus the clamp, so nothing stays outstanding.
        await service.acknowledge(hostId: "local", paneId: paneId, subscriber: subscription.id, bytes: 1 << 30)

        try await Task.sleep(for: .seconds(2))
        await service.sendKeys(hostId: "local", paneId: paneId, text: "echo after-pause-marker\r")

        let arrived = try await waitFor(seconds: 20) { await collected.text.contains("after-pause-marker") }
        let tail = String(await collected.text.suffix(2000))
        XCTAssertTrue(arrived, "the pane never came back after being paused:\n\(tail)")

        reader.cancel()
        await service.disconnectHost(hostId: "local")
    }

    // MARK: - Authentication prompts

    /// Stands in for an ssh that authenticates with a password: prompts on the pty, reads one line,
    /// and only then execs the tmux command it was handed. Exercises the real path — prompt detected
    /// in the pre-handshake stream, published on `HostState`, answered on the raw channel, protocol
    /// starts — without needing a remote host that accepts passwords.
    private func writeFakePasswordSshScript(accepting secret: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tetmux-fake-ssh-\(UUID().uuidString.prefix(8)).sh")
        let script = """
        #!/bin/sh
        # No trailing newline: ssh blocks on the prompt, and that is exactly the signal the
        # detector keys on.
        printf "tester@fake-host's password: "
        read -r answer
        if [ "$answer" != "\(secret)" ]; then
          echo 'Permission denied, please try again.' >&2
          exit 5
        fi
        exec /bin/sh -c "$1"
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testAPasswordPromptIsPublishedAndAnsweringItStartsTheProtocol() async throws {
        let script = try writeFakePasswordSshScript(accepting: "s3cret")
        defer { try? FileManager.default.removeItem(at: script) }

        let service = SessionService()
        await service.addHost(HostConfig(
            id: "pw", name: "fake-host", isLocal: false,
            customCommand: "/bin/sh \(script.path)",
            usesPassword: true
        ))
        try await service.connectHost(hostId: "pw", targetSession: sessionName)

        let prompting = try await waitForHost(service, id: "pw", timeout: 10) {
            $0.authenticationPrompt != nil
        }
        let prompt = try XCTUnwrap(prompting.authenticationPrompt)
        XCTAssertEqual(prompt.kind, .password)
        // §7 — the account and host ssh named, not a paraphrase of them.
        XCTAssertEqual(prompt.text, "tester@fake-host's password:")

        await service.answerAuthenticationPrompt(hostId: "pw", secret: "s3cret")

        let connected = try await waitForHost(service, id: "pw", timeout: 15) { host in
            host.connectionState == .connected && host.activeSession?.activeWindow?.layoutTree != nil
        }
        XCTAssertNil(connected.authenticationPrompt, "the prompt must clear once the protocol speaks")
        XCTAssertEqual(connected.activeSession?.name, sessionName)

        await service.disconnectHost(hostId: "pw")
    }

    /// F4.14 — a rejected password is not retried, and the reason the user sees is what the far end
    /// said. Retrying an authentication failure is how accounts get locked out.
    func testARejectedPasswordFailsWithoutRetrying() async throws {
        let script = try writeFakePasswordSshScript(accepting: "s3cret")
        defer { try? FileManager.default.removeItem(at: script) }

        let service = SessionService()
        await service.addHost(HostConfig(
            id: "pw-bad", name: "fake-host", isLocal: false,
            customCommand: "/bin/sh \(script.path)",
            usesPassword: true
        ))
        try await service.connectHost(hostId: "pw-bad", targetSession: sessionName)

        _ = try await waitForHost(service, id: "pw-bad", timeout: 10) { $0.authenticationPrompt != nil }
        await service.answerAuthenticationPrompt(hostId: "pw-bad", secret: "wrong")

        let failed = try await waitForHost(service, id: "pw-bad", timeout: 10) { host in
            if case .failed = host.connectionState { return true }
            return false
        }
        XCTAssertTrue(
            try XCTUnwrap(failed.connectionState.reason).contains("Permission denied"),
            "got: \(String(describing: failed.connectionState.reason))"
        )

        // A failure, not a retry: `.reconnecting` would mean the backoff took it.
        try await Task.sleep(for: .seconds(2))
        let latest = await service.getHost("pw-bad")
        let after = try XCTUnwrap(latest)
        guard case .failed = after.connectionState else {
            return XCTFail("expected the host to stay failed, got \(after.connectionState)")
        }
        XCTAssertNil(after.authenticationPrompt)
    }

    /// One answer per channel. A second write would be a second password attempt on a prompt ssh has
    /// already consumed, which at best does nothing and at worst types the secret into a shell.
    func testASecondAnswerOnTheSameChannelIsIgnored() async throws {
        let script = try writeFakePasswordSshScript(accepting: "s3cret")
        defer { try? FileManager.default.removeItem(at: script) }

        let service = SessionService()
        await service.addHost(HostConfig(
            id: "pw-twice", name: "fake-host", isLocal: false,
            customCommand: "/bin/sh \(script.path)",
            usesPassword: true
        ))
        try await service.connectHost(hostId: "pw-twice", targetSession: sessionName)
        _ = try await waitForHost(service, id: "pw-twice", timeout: 10) { $0.authenticationPrompt != nil }

        await service.answerAuthenticationPrompt(hostId: "pw-twice", secret: "s3cret")
        // Would be typed into the shell tmux is about to start, if it were written at all.
        await service.answerAuthenticationPrompt(hostId: "pw-twice", secret: "echo leaked-secret")

        let connected = try await waitForHost(service, id: "pw-twice", timeout: 15) { host in
            host.connectionState == .connected && host.activeSession?.activeWindow?.preferredPaneId != nil
        }
        let paneId = try XCTUnwrap(connected.activeSession?.activeWindow?.preferredPaneId)

        let stream = await service.subscribeToPane(hostId: "pw-twice", paneId: paneId).stream
        let collected = Task { () -> String in
            var text = ""
            for await chunk in stream {
                text += String(decoding: chunk, as: UTF8.self)
                if text.contains("marker-after-auth") { break }
            }
            return text
        }
        try await Task.sleep(for: .milliseconds(500))
        await service.sendKeys(hostId: "pw-twice", paneId: paneId, text: "echo marker-after-auth\r")
        let output = try await withTimeout(seconds: 10) { await collected.value }

        XCTAssertFalse(output.contains("leaked-secret"), "the second answer reached the pane:\n\(output)")

        await service.disconnectHost(hostId: "pw-twice")
    }

    /// F4.15/§7 — a connection that cannot be established surfaces the underlying message rather
    /// than a paraphrase, and does not retry an authentication failure.
    func testUnreachableHostSurfacesTheUnderlyingError() async throws {
        let service = SessionService()
        await service.addHost(HostConfig(
            id: "broken",
            name: "broken",
            isLocal: false,
            // Stands in for ssh: fails the way a real host-key or auth problem does.
            customCommand: "echo 'Permission denied (publickey).' >&2; exit 255; :"
        ))
        try? await service.connectHost(hostId: "broken", targetSession: "whatever")

        let host = try await waitForHost(service, id: "broken", timeout: 10) { host in
            if case .failed = host.connectionState { return true }
            return false
        }
        let reason = try XCTUnwrap(host.connectionState.reason)
        XCTAssertTrue(reason.contains("Permission denied"), "got: \(reason)")
    }

    // MARK: - Helpers

    /// Collects one pane subscription's bytes, with a mark so a test can ask what arrived *after* some
    /// point — which is how "the other view was left alone" is expressed.
    /// Collects the diagnostic log, which is the only place the flow-control decisions are visible:
    /// pausing a pane changes nothing about `HostState`, deliberately — it is a property of the
    /// channel, not of the model the UI renders.
    private actor LogSink {
        private var lines: [String] = []

        func append(_ line: String) { lines.append(line) }
        func contains(_ needle: String) -> Bool { lines.contains { $0.contains(needle) } }
        var text: String { lines.joined(separator: "\n") }
    }

    /// Polls a condition to a deadline. The state being waited on here is not in `HostState`, so
    /// `waitForHost` cannot express it.
    private func waitFor(
        seconds: TimeInterval,
        until condition: @escaping @Sendable () async -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private actor Collector {
        private var bytes = Data()
        private var markOffset = 0

        func append(_ chunk: Data) { bytes.append(chunk) }
        func mark() { markOffset = bytes.count }
        var text: String { String(decoding: bytes, as: UTF8.self) }
        var textSinceMark: String { String(decoding: bytes.dropFirst(markOffset), as: UTF8.self) }
    }

    /// Runs a tmux command outside the channel and returns its first line of output.
    private func tmuxQuery(_ arguments: [String]) -> String? {
        guard let tmux = PtyTransport.resolveExecutable("tmux") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text.components(separatedBy: .newlines).first
    }

    /// "tmux 3.7b" — `TmuxVersion` skips the leading non-digits itself.
    private func installedTmuxVersion() -> String? {
        tmuxQuery(["-V"])
    }

    /// Every session on the server, as exact names.
    ///
    /// `tmuxQuery` returns only the first line, and substring matching over a joined list is a trap:
    /// a session named `foo-survivor` contains `foo`, so "is `foo` gone?" answers itself wrongly.
    private func tmuxSessionNames() -> [String] {
        guard let tmux = PtyTransport.resolveExecutable("tmux") else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["list-sessions", "-F", "#{session_name}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    private func waitForHost(
        _ service: SessionService,
        id: String = "local",
        timeout: TimeInterval = 15,
        until predicate: @escaping (HostState) -> Bool
    ) async throws -> HostState {
        let deadline = Date().addingTimeInterval(timeout)
        var last: HostState?
        while Date() < deadline {
            if let host = await service.getHost(id) {
                last = host
                if predicate(host) { return host }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw XCTSkip("timed out waiting for host \(id); last state: \(String(describing: last))")
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let result = try await group.next()
            group.cancelAll()
            guard let value = result ?? nil else {
                throw XCTSkip("operation timed out after \(seconds)s")
            }
            return value
        }
    }
}

/// Accumulates a pane's output so a test can watch it arrive rather than block on it.
///
/// Needed because the interesting question here is what shows up *after* the first match — a reader
/// that returns at the marker can never see a duplicate.
private actor OutputCollector {
    private(set) var text = ""
    func append(_ chunk: String) { text += chunk }
}
