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

    private func runTmux(_ arguments: [String], tmuxDirectory: URL? = nil) {
        guard let tmux = PtyTransport.resolveExecutable("tmux") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = arguments
        if let tmuxDirectory {
            var environment = ProcessInfo.processInfo.environment
            environment["TMUX_TMPDIR"] = tmuxDirectory.path
            process.environment = environment
        }
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

    /// F4.11 — a host's start directory reaches `new-session -c`, and tmux resolves it on its side.
    ///
    /// End to end rather than as a string assertion, because the interesting part is not the command
    /// text: it is that tmux accepts the directory and the pane really opens there, which is the only
    /// thing the setting promises. `pane_current_path` is what reports it back.
    func testANewSessionOpensInTheHostsStartDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tetmux-start-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let created = "\(sessionName)-started"
        defer { runTmux(["kill-session", "-t", created]) }

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        let attached = sessionName
        _ = try await waitForHost(service) { $0.sessions.contains { $0.name == attached } }

        await service.newSession(hostId: "local", name: created, startDirectory: directory.path)

        // `waitFor` plus an explicit assertion, not `waitForHost`: that one throws `XCTSkip` on
        // timeout, which is exactly as green as a pass — and this test exists to fail if the start
        // directory never arrives.
        let arrived = try await waitFor(seconds: 15) {
            let path = await service.getHost("local")?
                .sessions.first { $0.name == created }?
                .activeWindow?.panes.first?.currentPath
            return path?.isEmpty == false
        }
        XCTAssertTrue(arrived, "the new session's pane never reported a working directory")

        let finalHost = await service.getHost("local")
        let path = try XCTUnwrap(
            finalHost?.sessions.first { $0.name == created }?.activeWindow?.panes.first?.currentPath
        )
        // Compared through `resolvingSymlinksInPath`: /var is a symlink to /private/var on macOS, so
        // the path handed to tmux and the path tmux reports back are the same directory spelled two
        // ways, and comparing the strings fails for a reason that has nothing to do with the feature.
        XCTAssertEqual(
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
            directory.resolvingSymlinksInPath().path
        )
    }

    /// F4.11 — a host's initial command is what the new session's first pane runs.
    ///
    /// Asserted through `pane_current_command` rather than against the command string, for the same
    /// reason the start directory is: what the setting promises is that the pane is running that
    /// program, and the only thing that can say so is tmux. `cat` because it is the shortest command
    /// that stays alive with no output — one that exits would take the window and then the session
    /// with it, which is tmux's behaviour for any `new-session <command>` and not this feature
    /// misbehaving.
    func testANewSessionRunsTheHostsInitialCommand() async throws {
        let created = "\(sessionName)-runs"
        defer { runTmux(["kill-session", "-t", created]) }

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        let attached = sessionName
        _ = try await waitForHost(service) { $0.sessions.contains { $0.name == attached } }

        await service.newSession(hostId: "local", name: created, initialCommand: "cat")

        // `waitFor` and an explicit assertion: `waitForHost` skips on timeout, and a skip is as green
        // as a pass for the one thing this test exists to catch.
        let arrived = try await waitFor(seconds: 15) {
            let command = await service.getHost("local")?
                .sessions.first { $0.name == created }?
                .activeWindow?.panes.first?.command
            return command == "cat"
        }
        let host = await service.getHost("local")
        let pane = host?.sessions.first { $0.name == created }?.activeWindow?.panes.first
        XCTAssertTrue(
            arrived,
            "the pane ran \(pane?.command ?? "nothing") rather than the host's initial command"
        )

        await service.disconnectHost(hostId: "local")
    }

    /// Both of F4.11's optional parameters at once, and in the right order on the command line.
    ///
    /// `shell-command` is `new-session`'s trailing positional argument, so a `-c` written after it
    /// is not an option at all — tmux stops reading flags at the first word that is not one. With
    /// the two swapped the session is still created and still runs the command, and only the
    /// directory quietly does nothing, which is exactly the kind of failure that survives a review.
    func testAStartDirectoryAndAnInitialCommandBothApply() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tetmux-both-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let created = "\(sessionName)-both"
        defer { runTmux(["kill-session", "-t", created]) }

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        let attached = sessionName
        _ = try await waitForHost(service) { $0.sessions.contains { $0.name == attached } }

        await service.newSession(
            hostId: "local", name: created,
            startDirectory: directory.path, initialCommand: "cat"
        )

        let arrived = try await waitFor(seconds: 15) {
            let pane = await service.getHost("local")?
                .sessions.first { $0.name == created }?
                .activeWindow?.panes.first
            return pane?.command == "cat" && pane?.currentPath.isEmpty == false
        }
        XCTAssertTrue(arrived, "the new session never reported both a command and a path")

        let host = await service.getHost("local")
        let pane = try XCTUnwrap(
            host?.sessions.first { $0.name == created }?.activeWindow?.panes.first
        )
        XCTAssertEqual(pane.command, "cat")
        // /var is a symlink to /private/var on macOS, so the two spellings are one directory.
        XCTAssertEqual(
            URL(fileURLWithPath: pane.currentPath).resolvingSymlinksInPath().path,
            directory.resolvingSymlinksInPath().path
        )

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

        // Its own Application Support directory: the model persists the workspace as a side effect
        // of a window registering, and a test must not write the user's `workspace.json`.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tetmux-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = await AppModel(directory: scratch)
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

    /// F4.15's second half: a session that ends leaves its *name* behind, and asking for it back by
    /// name is a thing the user can do.
    ///
    /// The distinction this pins is the one the machinery half already made and the model could not
    /// express: `.disconnected` after a session ends and `.disconnected` after a link drops are the
    /// same state and different news. The name is the whole of the difference — recreation from it is
    /// legitimate here precisely because the user is reading it on screen and pressing the button
    /// beside it, which is the case F4.15's own text carves out.
    func testAnEndedSessionLeavesItsNameBehindAndCanBeRecreated() async throws {
        try await withPrivateTmuxServer {
            let service = SessionService()
            await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
            try await service.connectHost(hostId: "local", targetSession: sessionName)

            let attached = sessionName
            _ = try await waitForHost(service) { $0.activeSession?.name == attached }

            runTmux(["send-keys", "-t", sessionName, "exit", "Enter"])

            // Wait for the state to *settle*, not merely for the field to appear. A session ending
            // is followed by one attempt at whatever the server has left, so there is a `.connecting`
            // in the middle — and the name is already set by then. Recreating during it would be
            // refused by `connectHost`'s idempotence guard, which is the same race a user cannot hit
            // because the offer is only drawn once the placeholder says disconnected.
            let disconnected = try await waitFor(seconds: 20) {
                await service.getHost("local")?.connectionState == .disconnected
            }
            XCTAssertTrue(disconnected, "the host never settled after its session ended")

            let ended = await service.getHost("local")
            let gone = try XCTUnwrap(ended)
            // A timeout must fail rather than skip: an absent field is exactly this bug.
            XCTAssertEqual(
                gone.endedSessionName, attached,
                "the ended session's name was not recorded, so nothing can offer it back"
            )
            XCTAssertTrue(gone.sessions.isEmpty)

            await service.recreateEndedSession(hostId: "local")

            let back = try await waitFor(seconds: 20) {
                await service.getHost("local")?.activeSession?.name == attached
            }
            XCTAssertTrue(back, "recreating by name did not land on a session of that name")
            // …and the offer is spent: it must not still be on screen over a live session.
            let recreated = await service.getHost("local")
            XCTAssertNil(
                recreated?.endedSessionName,
                "a session that is back must not still be announced as ended"
            )
            XCTAssertEqual(tmuxSessionNames(), [attached])

            await service.disconnectHost(hostId: "local")
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

    /// F4.10 — the model knows who else is attached, and knows which of them is us.
    ///
    /// This is what the destructive confirmations report: `kill-session` ends the session for every
    /// client attached to it, so a dialog that names only the panes is describing a smaller act than
    /// the one it is asking for. Against a real server rather than a parsed fixture, because the two
    /// facts that can be wrong are both about reality — that `#{session_id}` in `list-clients` is the
    /// *client's* session, and that our own channel is recognised by tty rather than counted as a
    /// stranger. Get the second wrong and the dialog warns the user about themselves, every time.
    func testAttachedClientsAreListedAndOurOwnChannelIsNotCountedAsAStranger() async throws {
        runTmux(["new-session", "-d", "-s", sessionName, "-x", "100", "-y", "30"])

        // A colleague in another terminal, which is exactly a plain `tmux attach` on a pty.
        let bystander = PtyTransport()
        let bystanderStream = try bystander.spawn(
            executable: try XCTUnwrap(PtyTransport.resolveExecutable("tmux")),
            arguments: ["attach-session", "-t", sessionName],
            environment: Self.childLikeEnvironment(),
            initialSize: (cols: 80, rows: 24)
        )
        let drain = Task { for try await _ in bystanderStream {} }
        defer { drain.cancel(); bystander.terminate() }

        let session = sessionName
        _ = try await waitFor(seconds: 10) { !Self.clientTtys(of: session).isEmpty }
        let bystanderTty = try XCTUnwrap(Self.clientTtys(of: session).first)

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        let connected = try await waitForHost(service) { $0.sessions.contains { $0.name == session } }
        let sessionId = try XCTUnwrap(connected.sessions.first { $0.name == session }).id

        // `waitFor` and an explicit assertion rather than `waitForHost`, which skips on timeout —
        // and a skip is exactly as green as a pass for a test whose whole subject is a warning that
        // must appear.
        let listed = try await waitFor(seconds: 10) {
            await service.getHost("local")?.otherClients(attachedTo: sessionId)
                .contains { $0.tty == bystanderTty } ?? false
        }
        XCTAssertTrue(listed, "the attached terminal never reached the model as another client")

        let snapshot = await service.getHost("local")
        let host = try XCTUnwrap(snapshot)
        let stranger = try XCTUnwrap(host.clients.first { $0.tty == bystanderTty })
        XCTAssertFalse(stranger.isOurs)
        XCTAssertFalse(stranger.isControlMode, "a plain `tmux attach` is not a control-mode client")
        XCTAssertEqual(stranger.sessionId, sessionId, "the client was attributed to the wrong session")
        XCTAssertNotNil(stranger.lastActivity)

        // Our own channel is in the list too, and marked. It is the reason `otherClients` exists:
        // telling somebody that killing a session will detach the window they are killing it from is
        // not information.
        let ours = host.clients.filter(\.isOurs)
        XCTAssertEqual(ours.count, 1, "expected exactly this channel's client to be marked as ours")
        XCTAssertTrue(try XCTUnwrap(ours.first).isControlMode)
        XCTAssertFalse(
            host.otherClients(attachedTo: sessionId).contains { $0.isOurs },
            "our own client was reported as somebody else's"
        )

        // Unwrapped rather than `if let`: a nil version would silently skip both checks below, and a
        // check that skips itself is the failure mode the whole suite is written against.
        let version = try XCTUnwrap(host.tmuxVersion.flatMap(TmuxVersion.init))

        // `client_user` arrived in tmux 3.3; below it tmux has no answer and the row keeps the tty.
        if version >= TmuxVersion("3.3")! {
            XCTAssertFalse(stranger.user.isEmpty, "tmux \(version.raw) reports client_user")
        }

        // And the list keeps up on its own: nothing polls it, so a client leaving has to arrive as
        // `%client-detached` (tmux 3.2) and be re-read. Without that the confirmation would warn
        // about somebody who left an hour ago.
        if version >= TmuxVersion("3.2")! {
            drain.cancel()
            bystander.terminate()
            let departed = try await waitFor(seconds: 10) {
                await service.getHost("local")?.otherClients(attachedTo: sessionId).isEmpty ?? false
            }
            XCTAssertTrue(departed, "the client list did not notice a client detaching")
        }

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

    /// Dragging a tab reorders the session's windows, and the order the strip shows is the order
    /// `list-windows` reports — so this is the assertion the whole feature reduces to.
    ///
    /// Against whatever tmux is on PATH, which is 3.2 or newer on any machine this runs on, so it
    /// exercises the `move-window -b` branch. The `swap-window` fallback below 3.2 is asserted from
    /// the fixture matrix's own probing rather than here; there is one tmux on the box.
    func testDraggingATabReordersTheSession() async throws {
        runTmux(["new-session", "-d", "-s", sessionName, "-n", "one"])
        runTmux(["new-window", "-t", sessionName, "-n", "two"])
        runTmux(["new-window", "-t", sessionName, "-n", "three"])

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        let host = try await waitForHost(service) { host in
            host.sessions.first { $0.name == self.sessionName }?.windows.count == 3
        }
        let session = try XCTUnwrap(host.sessions.first { $0.name == sessionName })
        let ids = session.windows.map(\.id)

        // The last window onto the first: it lands in front of it, and the other two shift up.
        await service.moveWindow(
            hostId: "local", sessionId: session.id, windowId: ids[2], before: ids[0]
        )

        let name = sessionName
        let expected = [ids[2], ids[0], ids[1]]
        let reordered = try await waitFor(seconds: 10) {
            guard let host = await service.getHost("local"),
                  let session = host.sessions.first(where: { $0.name == name }) else { return false }
            return session.windows.map(\.id) == expected
        }
        XCTAssertTrue(reordered, "the windows did not end up in the dropped order")
        // …and tmux agrees, rather than only our model having moved them.
        XCTAssertEqual(
            tmuxQuery(["list-windows", "-t", sessionName, "-F", "#{window_id}"])?
                .components(separatedBy: "\n").first,
            ids[2]
        )

        await service.disconnectHost(hostId: "local")
    }

    /// Moving a window to another session is not a close and not a kill: the same window, with the
    /// same process behind it, one level of the tree over.
    func testMovingAWindowToAnotherSessionKeepsWhatIsRunningInIt() async throws {
        let other = "\(sessionName)-target"
        defer { runTmux(["kill-session", "-t", other]) }
        runTmux(["new-session", "-d", "-s", sessionName, "-n", "one"])
        runTmux(["new-window", "-t", sessionName, "-n", "movable"])
        runTmux(["new-session", "-d", "-s", other])

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        let host = try await waitForHost(service) { host in
            host.sessions.first { $0.name == self.sessionName }?.windows.count == 2
        }
        let source = try XCTUnwrap(host.sessions.first { $0.name == sessionName })
        let moving = try XCTUnwrap(source.windows.first { $0.name == "movable" })
        let paneId = try XCTUnwrap(
            tmuxQuery(["list-panes", "-t", moving.id, "-F", "#{pane_id}"])?
                .components(separatedBy: "\n").first
        )
        let pid = try XCTUnwrap(tmuxQuery(["display-message", "-p", "-t", paneId, "#{pane_pid}"]))
        let targetId = try XCTUnwrap(
            tmuxQuery(["list-sessions", "-f", "#{==:#{session_name},\(other)}", "-F", "#{session_id}"])
        )

        await service.moveWindow(
            hostId: "local", windowId: moving.id, fromSession: source.id, toSession: targetId
        )

        // Waited for through the model, which is what a `@Sendable` predicate can reach; tmux's own
        // answer is asserted below, once.
        let sourceId = source.id
        let movedId = moving.id
        let arrived = try await waitFor(seconds: 10) {
            guard let host = await service.getHost("local") else { return false }
            let stillInSource = host.sessions.first { $0.id == sourceId }?
                .windows.contains { $0.id == movedId } ?? false
            let inTarget = host.sessions.first { $0.id == targetId }?
                .windows.contains { $0.id == movedId } ?? false
            return inTarget && !stillInSource
        }
        XCTAssertTrue(arrived, "the window never moved to the target session")
        XCTAssertEqual(
            tmuxQuery([
                "list-windows", "-t", other,
                "-f", "#{==:#{window_id},\(moving.id)}", "-F", "#{window_id}",
            ]),
            moving.id,
            "the model says it moved and tmux does not"
        )
        XCTAssertNil(
            tmuxQuery([
                "list-windows", "-t", self.sessionName,
                "-f", "#{==:#{window_id},\(moving.id)}", "-F", "#{window_id}",
            ]),
            "the window is still linked into the session it was moved out of"
        )
        XCTAssertEqual(
            tmuxQuery(["display-message", "-p", "-t", paneId, "#{pane_pid}"]), pid,
            "moving a window killed the process in it"
        )

        await service.disconnectHost(hostId: "local")
    }

    /// `link-window` is the inverse of F4.9's unlink, and the thing that makes the unlink path
    /// reachable at all: a window in one session cannot be closed without being killed.
    func testLinkingAWindowPutsItInBothSessions() async throws {
        let other = "\(sessionName)-target"
        defer { runTmux(["kill-session", "-t", other]) }
        runTmux(["new-session", "-d", "-s", sessionName, "-n", "shared"])
        runTmux(["new-session", "-d", "-s", other])

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        try await service.connectHost(hostId: "local", targetSession: sessionName)
        let host = try await waitForHost(service) { $0.activeSession?.activeWindow?.layoutTree != nil }
        let windowId = try XCTUnwrap(
            host.sessions.first { $0.name == sessionName }?.windows.first?.id
        )
        let targetId = try XCTUnwrap(
            tmuxQuery(["list-sessions", "-f", "#{==:#{session_name},\(other)}", "-F", "#{session_id}"])
        )

        await service.linkWindow(hostId: "local", windowId: windowId, toSession: targetId)

        let linked = try await waitFor(seconds: 10) {
            guard let host = await service.getHost("local") else { return false }
            return host.sessions.first { $0.id == targetId }?
                .windows.contains { $0.id == windowId } ?? false
        }
        XCTAssertTrue(linked, "the window was never linked into the second session")
        XCTAssertEqual(
            tmuxQuery([
                "list-windows", "-t", other,
                "-f", "#{==:#{window_id},\(windowId)}", "-F", "#{window_id}",
            ]),
            windowId,
            "the model says it is linked and tmux does not"
        )
        XCTAssertEqual(
            tmuxQuery([
                "list-windows", "-t", self.sessionName,
                "-f", "#{==:#{window_id},\(windowId)}", "-F", "#{window_id}",
            ]),
            windowId,
            "linking took the window out of its original session — that would be a move"
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
    // MARK: - Opening a host

    /// Clicking a host attaches to the session that is there — it does not insist on a name.
    ///
    /// The bug this pins made the app look broken, and it was invisible on the machine it was
    /// developed on: local tmux always has `tetmux-main` because tetmux itself made it, so the
    /// hard-coded name always resolved. On any *other* server it does not, and clicking the host ran
    /// `attach-session -t tetmux-main`, got `can't find session: tetmux-main` and `%exit`, and the
    /// `%exit` handler read that as "the server has nothing left" — `.disconnected`, no retry, no
    /// message. A host with three sessions on it did nothing at all when clicked.
    func testOpeningAHostAttachesToAnExistingSessionRatherThanAName() async throws {
        let server = try isolatedServer()
        defer { killServer(server) }
        runTmux(["new-session", "-d", "-s", "already-here"], tmuxDirectory: server.directory)
        XCTAssertEqual(sessionNames(on: server), ["already-here"])

        let service = SessionService()
        await service.addHost(isolatedHost(id: "opened", server: server))
        await service.openHost(hostId: "opened")

        let host = try await waitForHost(service, id: "opened", timeout: 15) { host in
            host.connectionState == .connected && !host.sessions.isEmpty
        }
        XCTAssertEqual(host.sessions.map(\.name), ["already-here"])
        // …and nothing was invented alongside it. `tetmux-main` appearing here is the whole failure.
        XCTAssertEqual(sessionNames(on: server), ["already-here"])

        await service.disconnectHost(hostId: "opened")
    }

    /// …and the other half of the same click: with nothing to attach to, make one.
    ///
    /// Both shapes of "nothing" are covered by the same expectation — a server with no sessions, and
    /// no server at all. The second is what a host that has never run tmux answers, and it dies
    /// before the handshake rather than through `%exit`.
    func testOpeningAHostWithNoServerCreatesASession() async throws {
        let server = try isolatedServer()
        defer { killServer(server) }
        // Deliberately not started: there is no server on this socket at all.
        XCTAssertEqual(sessionNames(on: server), [])

        let service = SessionService()
        await service.addHost(isolatedHost(id: "empty", server: server))
        await service.openHost(hostId: "empty")

        let host = try await waitForHost(service, id: "empty", timeout: 20) { host in
            host.connectionState == .connected && !host.sessions.isEmpty
        }
        XCTAssertEqual(host.sessions.count, 1, "expected exactly the one session it had to create")
        XCTAssertFalse(sessionNames(on: server).isEmpty, "nothing was created on the server")

        await service.disconnectHost(hostId: "empty")
    }

    /// A connect the user asked for that fails is reported, not retried.
    ///
    /// The backoff is for a link that *dropped*: the session is still on the server and getting back
    /// to it should not need a click. A host that never connected has lost nobody anything, and
    /// eight silent attempts over ninety seconds neither fix a wrong hostname nor say that is what it
    /// is. The reason goes on screen with the Retry that is already beside it.
    func testAManualConnectThatFailsIsNotRetried() async throws {
        let script = try writeFailingSshScript()
        defer { try? FileManager.default.removeItem(at: script) }

        let service = SessionService()
        await service.addHost(HostConfig(
            id: "unreachable", name: "unreachable", isLocal: false,
            customCommand: "/bin/sh \(script.path)"
        ))
        await service.openHost(hostId: "unreachable")

        let failed = try await waitForHost(service, id: "unreachable", timeout: 10) { host in
            if case .failed = host.connectionState { return true }
            return false
        }
        XCTAssertTrue(
            try XCTUnwrap(failed.connectionState.reason).contains("Connection refused"),
            "the user must be told what ssh said: \(String(describing: failed.connectionState.reason))"
        )

        // …and it stays failed. `.reconnecting` here would be the backoff taking it.
        try await Task.sleep(for: .seconds(3))
        let latest = await service.getHost("unreachable")
        let after = try XCTUnwrap(latest)
        guard case .failed = after.connectionState else {
            return XCTFail("a manual connect was retried: \(after.connectionState)")
        }
    }

    /// …while a *dropped* link is exactly what the backoff is for, and still gets it.
    func testARecoveryAttemptThatFailsKeepsTrying() async throws {
        let script = try writeFailingSshScript()
        defer { try? FileManager.default.removeItem(at: script) }

        let service = SessionService()
        await service.addHost(HostConfig(
            id: "dropped", name: "dropped", isLocal: false,
            customCommand: "/bin/sh \(script.path)"
        ))
        // The call the backoff itself makes, and the one `probeAllConnections` makes on wake.
        try? await service.connectHost(hostId: "dropped", isRecovery: true)

        let retrying = try await waitForHost(service, id: "dropped", timeout: 10) { host in
            if case .reconnecting = host.connectionState { return true }
            return false
        }
        guard case .reconnecting(let attempt, _) = retrying.connectionState else {
            return XCTFail("expected the backoff to take it")
        }
        XCTAssertGreaterThanOrEqual(attempt, 1)

        await service.disconnectHost(hostId: "dropped")
    }

    /// A host-key question reaches the user and can be answered, instead of hanging for 45 seconds.
    ///
    /// End to end through the real machinery — detect, publish, answer, handshake — with a script in
    /// place of ssh, because a genuine first contact needs a server whose key nobody here has. What
    /// the script emits is the byte-for-byte capture from OpenSSH against a real host, including the
    /// detail that made this a bug: the question ends in `? `, not a colon, so the old detector
    /// returned nil, nothing was ever published, and the channel sat until the watchdog killed it.
    func testAHostKeyQuestionIsAskedAndCanBeAnswered() async throws {
        let script = try writeFakeHostKeySshScript()
        defer { try? FileManager.default.removeItem(at: script) }

        let service = SessionService()
        await service.addHost(HostConfig(
            id: "newkey", name: "newkey", isLocal: false, customCommand: "/bin/sh \(script.path)"
        ))
        try await service.connectHost(hostId: "newkey", targetSession: sessionName)

        let asking = try await waitForHost(service, id: "newkey", timeout: 10) {
            $0.authenticationPrompt != nil
        }
        let prompt = try XCTUnwrap(asking.authenticationPrompt)
        XCTAssertEqual(prompt.kind, .hostKey)
        XCTAssertFalse(prompt.answerIsSecret, "a host key is a decision, not a secret")
        XCTAssertEqual(prompt.text, "Are you sure you want to continue connecting (yes/no/[fingerprint])?")
        // The fingerprint is the whole content of the decision, and it is on another line.
        XCTAssertEqual(
            prompt.context?.contains("SHA256:Qk9zR2xhY2VEb2NFeGFtcGxlS2V5MDAwMDAwMDAwMDA"), true,
            "got: \(String(describing: prompt.context))"
        )

        // Answering `yes` is what the sheet's Continue button sends — ssh's own word, not ours.
        await service.answerAuthenticationPrompt(hostId: "newkey", secret: "yes")

        let connected = try await waitForHost(service, id: "newkey", timeout: 15) { host in
            host.connectionState == .connected && host.activeSession?.activeWindow?.layoutTree != nil
        }
        XCTAssertNil(connected.authenticationPrompt, "the prompt must clear once the protocol speaks")

        await service.disconnectHost(hostId: "newkey")
    }

    /// An ssh whose host key is unknown: the OpenSSH first-contact block, verbatim, and then the
    /// command it was given once the answer arrives.
    private func writeFakeHostKeySshScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tetmux-fake-hostkey-\(UUID().uuidString.prefix(8)).sh")
        // No trailing newline after the question — that is the signal that ssh is *sitting* on it,
        // and the thing a hand-written approximation gets wrong.
        let script = """
        #!/bin/sh
        printf "The authenticity of host '[devbox]:2222 ([10.0.0.9]:2222)' can't be established.\\r\\n"
        printf "ED25519 key fingerprint is: SHA256:Qk9zR2xhY2VEb2NFeGFtcGxlS2V5MDAwMDAwMDAwMDA\\r\\n"
        printf "This key is not known by any other names.\\r\\n"
        printf "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
        read -r answer
        if [ "$answer" != "yes" ]; then
          echo 'Host key verification failed.' >&2
          exit 255
        fi
        printf "\\r\\nWarning: Permanently added '[devbox]:2222' to the list of known hosts.\\r\\n"
        exec /bin/sh -c "$1"
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// An ssh that fails the way an unreachable host does: a message on stderr and a non-zero exit,
    /// with nothing that looks like an authentication failure or an empty tmux server.
    private func writeFailingSshScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tetmux-fake-down-\(UUID().uuidString.prefix(8)).sh")
        try """
        #!/bin/sh
        echo 'ssh: connect to host unreachable port 22: Connection refused' >&2
        exit 255
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// F4.15 is untouched: *automatic* recovery still never creates. Only the click does.
    func testAutomaticRecoveryStillRefusesToCreate() async throws {
        let server = try isolatedServer()
        defer { killServer(server) }
        XCTAssertEqual(sessionNames(on: server), [])

        let service = SessionService()
        await service.addHost(isolatedHost(id: "recovering", server: server))
        // The backoff's own call: a recovery, with no permission to create.
        try? await service.connectHost(hostId: "recovering", isRecovery: true)

        // Give it longer than the connect would need, then insist nothing was made.
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(
            sessionNames(on: server), [],
            "a reconnect manufactured a session, which is exactly what F4.15 forbids"
        )
    }

    /// A tmux server of this test's own.
    ///
    /// Necessary rather than tidy: these tests assert things like "the server had nothing on it" and
    /// "nothing was created", which against the machine's own tmux would be assertions about whoever
    /// is running them. `TMUX_TMPDIR` puts the socket somewhere private, and the host below reaches
    /// it through `customCommand` — the remote code path with the remoteness taken out, which is the
    /// only way a test can own the server it is making claims about.
    private func isolatedServer() throws -> (directory: URL, script: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tetmux-iso-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("ssh.sh")
        try """
        #!/bin/sh
        export TMUX_TMPDIR=\(directory.path)
        exec /bin/sh -c "$1"
        """.write(to: script, atomically: true, encoding: .utf8)
        return (directory, script)
    }

    private func killServer(_ server: (directory: URL, script: URL)) {
        runTmux(["kill-server"], tmuxDirectory: server.directory)
        try? FileManager.default.removeItem(at: server.directory)
    }

    private func sessionNames(on server: (directory: URL, script: URL)) -> [String] {
        guard let tmux = PtyTransport.resolveExecutable("tmux") else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["list-sessions", "-F", "#{session_name}"]
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX_TMPDIR"] = server.directory.path
        process.environment = environment
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

    private func isolatedHost(id: String, server: (directory: URL, script: URL)) -> HostConfig {
        HostConfig(id: id, name: id, isLocal: false, customCommand: "/bin/sh \(server.script.path)")
    }

    // MARK: - Discovery (F4.4)

    /// F4.4 — what is on a host, asked without attaching to it and without creating anything.
    ///
    /// The three assertions are the whole requirement. It has to *find* the session; it has to leave
    /// `session_attached` at zero, since a discovery that attaches is just a connection with extra
    /// steps; and it must not bring `tetmux-main` into existence, which is what clicking the host
    /// does today and the reason this exists at all.
    func testSessionsAreDiscoveredWithoutAttachingOrCreating() async throws {
        let existing = "\(sessionName)-discoverable"
        runTmux(["new-session", "-d", "-s", existing])
        defer { runTmux(["kill-session", "-t", existing]) }

        let before = tmuxSessionNames()
        XCTAssertTrue(before.contains(existing), "the fixture session was not created")

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        await service.discoverSessions(hostId: "local")

        let host = await service.getHost("local")
        let discovered = try XCTUnwrap(host?.discoveredSessions, "the probe recorded no answer at all")
        XCTAssertTrue(
            discovered.contains { $0.name == existing },
            "discovered \(discovered.map(\.name)) — not the session that is really there"
        )

        // Nothing was attached: this session is exactly as unattached as it was.
        XCTAssertEqual(
            tmuxQuery(["display-message", "-p", "-t", existing, "#{session_attached}"]), "0",
            "the probe attached a client, which is the one thing it must not do"
        )
        // …and nothing was created. `connectHost` would have made `tetmux-main` here.
        XCTAssertEqual(tmuxSessionNames(), before, "the probe changed what is on the server")

        // The host is still disconnected, and stayed that way — a probe is not a connection and must
        // not report itself as one.
        XCTAssertEqual(host?.connectionState, .disconnected)
        XCTAssertTrue(host?.sessions.isEmpty == true, "a probe must not fill the channel's own list")
    }

    /// The answer is offered whichever way it was learned, and a channel's answer wins.
    func testAConnectedHostPrefersItsChannelOverAProbe() async throws {
        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        await service.discoverSessions(hostId: "local")

        let latest = await service.getHost("local")
        let probed = try XCTUnwrap(latest)
        XCTAssertFalse(probed.browsableSessions.isEmpty, "nothing to browse before connecting")
        XCTAssertTrue(probed.sessions.isEmpty)

        try await service.connectHost(hostId: "local", targetSession: sessionName)
        let attached = sessionName
        let connected = try await waitForHost(service) { host in
            host.sessions.contains { $0.name == attached }
        }
        XCTAssertNil(connected.discoveredSessions, "the channel supersedes the probe")
        XCTAssertEqual(
            connected.browsableSessions.map(\.id), connected.sessions.map(\.id),
            "a live channel's list is the one to offer"
        )

        await service.disconnectHost(hostId: "local")
    }

    // MARK: - Passthrough (§4.6, F4.27)

    /// The mode itself, against the real tmux on this machine: one client, one pty, no protocol.
    ///
    /// Driven with an explicit reason rather than by a version probe, because the version that
    /// triggers it in production is one no machine here has — the trigger is covered separately with
    /// a server that claims to be 2.3. What this asserts is the part that must work whatever caused
    /// it: a real tmux client attaches, paints itself into the stream, and takes a keystroke.
    func testPassthroughRunsARealTmuxClientAndStreamsWhatItDraws() async throws {
        let attached = "\(sessionName)-passthrough"
        defer { runTmux(["kill-session", "-t", attached]) }

        let service = SessionService()
        await service.addHost(HostConfig(id: "local", name: "localhost", isLocal: true))
        await service.startPassthrough(
            hostId: "local",
            reason: .belowControlModeFloor(version: "2.3"),
            sessionName: attached
        )

        let collector = Collector()
        let subscription = await service.subscribeToPassthrough(hostId: "local")
        let reader = Task {
            for await chunk in subscription.stream { await collector.append(chunk) }
        }
        defer { reader.cancel() }

        // `.running` is set by the first byte off the pty, so reaching it *is* "tmux drew something".
        let running = try await waitFor(seconds: 15) {
            await service.getHost("local")?.passthrough?.phase == .running
        }
        XCTAssertTrue(running, "the passthrough client never produced any output")

        // Deliberately *not* asserted on tmux's own status bar, which is the visible difference this
        // mode makes: it is drawn from the user's `~/.tmux.conf`, and this test runs against whatever
        // tmux is on the machine with whatever configuration it has. The run that found this had
        // `status off`, so the assertion was about the developer's dotfiles rather than about the
        // feature. What follows is the same claim without that dependency.

        // The session is really there, which is what separates this from a terminal painting itself.
        XCTAssertTrue(tmuxSessionNames().contains(attached))

        // Keystrokes are raw bytes on the pty, not `send-keys`: there is no command plane to use.
        await collector.mark()
        await service.sendPassthrough(hostId: "local", bytes: Array("echo 90210\n".utf8))
        let echoed = try await waitFor(seconds: 10) {
            await collector.textSinceMark.contains("90210")
        }
        XCTAssertTrue(echoed, "the keystrokes never reached the shell")

        await service.stopPassthrough(hostId: "local")
        let stopped = await service.getHost("local")
        XCTAssertEqual(stopped?.passthrough?.phase, .offered, "stopping must leave the mode offered")
        // Stopping the client must not kill what it was attached to. That is the whole point of tmux
        // being in the loop for this half of §4.6.
        XCTAssertTrue(tmuxSessionNames().contains(attached))
    }

    /// R3.8's `< 2.4` row, end to end: control mode answers, says it is too old, and the channel is
    /// replaced rather than continued.
    ///
    /// The server is a script, because no tmux on this machine is old enough to be the subject. It
    /// speaks exactly as much of the protocol as the handshake and the version probe need, and its
    /// other half — the invocation without `-CC` — stands in for the tmux client passthrough would
    /// attach. What is asserted is ours: the fallback triggers, the control channel goes away rather
    /// than applying policies this server does not have, and the passthrough stream is live.
    func testAServerBelowTheControlModeFloorFallsBackToPassthrough() async throws {
        let script = try writeFakeOldTmuxScript(reporting: "2.3")
        defer { try? FileManager.default.removeItem(at: script) }

        let service = SessionService()
        await service.addHost(HostConfig(
            id: "old", name: "fake-old", isLocal: false,
            customCommand: "/bin/sh \(script.path)"
        ))
        try await service.connectHost(hostId: "old", targetSession: sessionName)

        let fellBack = try await waitFor(seconds: 15) {
            await service.getHost("old")?.passthrough?.isRunning == true
        }
        let latest = await service.getHost("old")
        let host = try XCTUnwrap(latest)
        XCTAssertTrue(fellBack, "never fell back; state was \(String(describing: host.passthrough))")
        XCTAssertEqual(
            host.passthrough?.reason, .belowControlModeFloor(version: "2.3"),
            "the fallback has to name the version it was told, since that is the whole explanation"
        )
        XCTAssertTrue(host.passthrough?.usesTmux == true)
        // §4.6 is a different channel, not control mode with features off: the tree is empty because
        // there is nothing behind it to fill it with.
        XCTAssertTrue(host.sessions.isEmpty)
        guard case .degraded = host.connectionState else {
            return XCTFail("expected .degraded, got \(host.connectionState)")
        }

        let collector = Collector()
        let subscription = await service.subscribeToPassthrough(hostId: "old")
        let reader = Task {
            for await chunk in subscription.stream { await collector.append(chunk) }
        }
        defer { reader.cancel() }
        let spoke = try await waitFor(seconds: 10) {
            await collector.text.contains("fake-passthrough-ready")
        }
        XCTAssertTrue(spoke, "the passthrough channel never spawned the non-control-mode invocation")

        await service.disconnectHost(hostId: "old")
        let after = await service.getHost("old")
        XCTAssertNil(after?.passthrough, "a deliberate disconnect leaves no mode behind")
    }

    /// R3.8's last row: no tmux on the far side is an error with something to offer, and what it
    /// offers is a plain shell — offered, never started, because nothing there persists.
    func testAHostWithNoTmuxOffersAPlainShellAndOpensOneOnRequest() async throws {
        let script = try writeFakeMissingTmuxScript()
        defer { try? FileManager.default.removeItem(at: script) }

        let service = SessionService()
        await service.addHost(HostConfig(
            id: "no-tmux", name: "fake-bare", isLocal: false,
            customCommand: "/bin/sh \(script.path)"
        ))
        try? await service.connectHost(hostId: "no-tmux", targetSession: sessionName)

        let offered = try await waitFor(seconds: 15) {
            await service.getHost("no-tmux")?.passthrough?.phase == .offered
        }
        let latest = await service.getHost("no-tmux")
        let host = try XCTUnwrap(latest)
        XCTAssertTrue(offered, "no offer was made; state was \(String(describing: host.passthrough))")
        XCTAssertEqual(host.passthrough?.reason, .tmuxUnavailable)
        XCTAssertFalse(host.passthrough?.usesTmux == true, "there is no tmux to be passing through to")
        // §7 — what the far end said, kept for the placeholder to show.
        XCTAssertTrue(
            host.passthrough?.detail.contains("tmux not found") == true,
            "got: \(String(describing: host.passthrough?.detail))"
        )
        guard case .failed = host.connectionState else {
            return XCTFail("expected .failed, got \(host.connectionState)")
        }

        // The offer being taken up: this is the one path that spawns a shell rather than tmux.
        let collector = Collector()
        await service.startPassthrough(hostId: "no-tmux")
        let subscription = await service.subscribeToPassthrough(hostId: "no-tmux")
        let reader = Task {
            for await chunk in subscription.stream { await collector.append(chunk) }
        }
        defer { reader.cancel() }

        let running = try await waitFor(seconds: 15) {
            await service.getHost("no-tmux")?.passthrough?.phase == .running
        }
        XCTAssertTrue(running, "the plain shell never produced any output")

        // Something the shell computes, so its own echo of the line cannot be mistaken for a result.
        await collector.mark()
        await service.sendPassthrough(hostId: "no-tmux", bytes: Array("expr 111111 + 222222\n".utf8))
        let answered = try await waitFor(seconds: 10) {
            await collector.textSinceMark.contains("333333")
        }
        XCTAssertTrue(answered, "the shell never ran what was typed into it")

        await service.disconnectHost(hostId: "no-tmux")
    }

    /// A control-mode server that answers the handshake and the version probe, and nothing else.
    ///
    /// The passthrough half is the same script invoked without `-CC` — which is exactly how the two
    /// invocations differ in production, so the branch here is the assertion that they do.
    private func writeFakeOldTmuxScript(reporting version: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tetmux-fake-old-\(UUID().uuidString.prefix(8)).sh")
        let script = """
        #!/bin/sh
        case "$1" in
          *-CC*)
            # The DCS preamble glued to the first %begin, exactly as tmux -CC opens.
            printf '\\033P1000p'
            printf '%%begin 1000 1 1\\r\\n%%end 1000 1 1\\r\\n'
            n=2
            while IFS= read -r line; do
              printf '%%begin 1000 %s 1\\r\\n' "$n"
              case "$line" in
                *version*) printf '\(version)\\r\\n' ;;
              esac
              printf '%%end 1000 %s 1\\r\\n' "$n"
              n=$((n + 1))
            done
            ;;
          *)
            printf 'fake-passthrough-ready\\r\\n'
            # Hold the pty open; a process that exits here would look like the mode ending.
            cat > /dev/null
            ;;
        esac
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A host with no tmux, which is `remoteCommand`'s own `command -v` message and exit 127. Any
    /// other command — the login shell the offer runs — is executed normally.
    private func writeFakeMissingTmuxScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tetmux-fake-bare-\(UUID().uuidString.prefix(8)).sh")
        let script = """
        #!/bin/sh
        case "$1" in
          *tmux*)
            echo 'tetmux: tmux not found on remote host' >&2
            exit 127
            ;;
        esac
        exec /bin/sh -c "$1"
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

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

    /// A clock a test can move, for the rules that are about elapsed time.
    ///
    /// `ContinuousClock` based, like the code it stands in for: the outbox's age limit exists
    /// precisely for the sleep/wake boundary, and a `Date`-based stand-in would not be testing the
    /// same arithmetic. Waiting ten real seconds to assert a ten-second rule is a test nobody runs.
    private final class MovableClock: @unchecked Sendable {
        private let lock = NSLock()
        private let base = ContinuousClock.now
        private var offset = Duration.zero

        var now: ContinuousClock.Instant {
            lock.lock()
            defer { lock.unlock() }
            return base + offset
        }

        func advance(by amount: Duration) {
            lock.lock()
            offset += amount
            lock.unlock()
        }
    }

    /// The pre-handshake outbox is bounded by *age* as well as by size.
    ///
    /// The size cap says how much may wait and nothing about how long, so a host that came back after
    /// an outage replayed whatever survived — keystrokes typed at a shell that had long moved on,
    /// delivered in one burst and executed rather than read. The password prompt is the seam: the
    /// channel is spawned and ssh is blocked on `read`, which is exactly "connected enough to queue
    /// against, not yet handshaken", and answering it is what makes the flush happen on cue.
    func testCommandsThatWaitedTooLongForTheHandshakeAreDropped() async throws {
        let script = try writeFakePasswordSshScript(accepting: "s3cret")
        defer { try? FileManager.default.removeItem(at: script) }

        let clock = MovableClock()
        let service = SessionService(now: { clock.now })
        let sink = LogSink()
        await service.setDiagnosticLogger { message in
            Task { await sink.append(message) }
        }
        await service.addHost(HostConfig(
            id: "stale", name: "fake-host", isLocal: false,
            customCommand: "/bin/sh \(script.path)",
            usesPassword: true
        ))
        try await service.connectHost(hostId: "stale", targetSession: sessionName)
        _ = try await waitForHost(service, id: "stale", timeout: 10) { $0.authenticationPrompt != nil }

        // Typed into a surface that still has focus while its host is coming back.
        await service.newWindow(hostId: "stale")
        await service.newWindow(hostId: "stale")

        // The outage. Long enough that nothing queued before it is still what anyone meant.
        clock.advance(by: .seconds(120))

        await service.newWindow(hostId: "stale")
        await service.answerAuthenticationPrompt(hostId: "stale", secret: "s3cret")

        let connected = try await waitForHost(service, id: "stale", timeout: 15) { host in
            host.connectionState == .connected && host.activeSession?.activeWindow?.layoutTree != nil
        }
        XCTAssertEqual(connected.activeSession?.name, sessionName)

        let dropped = try await waitFor(seconds: 10) { await sink.contains("dropped 2 command(s) that waited") }
        let log = await sink.text
        XCTAssertTrue(dropped, "the stale commands were replayed:\n\(log)")

        // The decisive half: the fresh one still arrived. An age limit that dropped everything would
        // pass the assertion above and silently lose the command the user just issued.
        let windows = try await waitFor(seconds: 10) {
            await service.getHost("stale")?.activeSession?.windows.count == 2
        }
        let after = await service.getHost("stale")
        XCTAssertTrue(
            windows,
            "expected the session's original window plus one, got \(after?.activeSession?.windows.count ?? -1)"
        )

        await service.disconnectHost(hostId: "stale")
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
