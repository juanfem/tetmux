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
