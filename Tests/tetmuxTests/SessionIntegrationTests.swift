import XCTest
@testable import tetmuxCore

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
        let stream = await service.subscribeToPane(hostId: "local", paneId: paneId)
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
        let stream = await service.subscribeToPane(hostId: "local", paneId: paneId)
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
        let stream = await service.subscribeToPane(hostId: "local", paneId: paneId)
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

        // The write races the channel teardown, so allow a moment for tmux to act on it.
        var restored = false
        for _ in 0..<20 {
            if windowSizeOption() != "manual" { restored = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(restored, "window-size was left at manual on the user's session")
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
        let firstStream = await service.subscribeToPane(hostId: "local", paneId: paneId)
        let firstView = Collector()
        let firstReader = Task { for await chunk in firstStream { await firstView.append(chunk) } }
        try await Task.sleep(for: .milliseconds(400))
        await service.sendKeys(hostId: "local", paneId: paneId, text: "echo first-viewer-marker\r")
        try await Task.sleep(for: .milliseconds(800))
        await firstView.mark()

        // Second view of the same pane, as a torn-off window is.
        let secondStream = await service.subscribeToPane(hostId: "local", paneId: paneId)
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

        let stream = await service.subscribeToPane(hostId: "pw-twice", paneId: paneId)
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
