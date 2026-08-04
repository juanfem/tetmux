import XCTest
@testable import tetmuxCore

final class HostConfigStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tetmux-store-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent("hosts.json") }

    /// A `hosts.json` written before password and tunnel settings existed has to keep loading. The
    /// synthesised `Codable` conformance treats a missing non-optional key as a decoding failure, and
    /// the failure is not per-host: one old entry would discard the user's entire host list.
    func testHostsFileFromAnEarlierVersionStillDecodes() throws {
        let json = """
        [
          {"id":"custom-devbox","name":"devbox","isLocal":false,"port":2222,"user":"me"},
          {"id":"custom-minimal","name":"minimal","isLocal":false}
        ]
        """
        let decoded = try JSONDecoder().decode([StoredHost].self, from: Data(json.utf8))

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].name, "devbox")
        XCTAssertEqual(decoded[0].port, 2222)
        XCTAssertEqual(decoded[0].user, "me")
        // Absent settings take their conservative defaults rather than failing the decode.
        XCTAssertFalse(decoded[0].usesPassword)
        XCTAssertFalse(decoded[0].storesPasswordInKeychain)
        XCTAssertEqual(decoded[0].forwards, [])
        XCTAssertEqual(decoded[0].extraSshArguments, "")
        XCTAssertFalse(decoded[0].forwardsX11)
        XCTAssertEqual(decoded[1].name, "minimal")
    }

    /// The ssh escape hatch survives a round trip, and reaches ssh as argv rather than as a string
    /// somebody has to re-parse.
    func testExtraSshOptionsRoundTripAndReachTheInvocation() async throws {
        let store = HostConfigStore(directory: directory)
        let host = StoredHost(
            id: "custom-devbox", name: "devbox", user: "me",
            extraSshArguments: "-o \"ProxyCommand=nc %h %p\" -C", forwardsX11: true
        )

        try await store.saveHosts([host])
        let loaded = await store.loadHosts()
        let reloaded = try XCTUnwrap(loaded.first { $0.id == "custom-devbox" })
        XCTAssertEqual(reloaded, host)

        let config = reloaded.asConfig
        let args = TmuxCommand.sshArguments(
            destination: config.sshDestination, port: config.port,
            controlPath: "/tmp/cm-%C", remoteCommand: "true",
            extraArguments: TmuxCommand.splitArguments(config.extraSshArguments),
            forwardsX11: config.forwardsX11
        )
        XCTAssertEqual(args.first, "-o")
        XCTAssertEqual(args[1], "ProxyCommand=nc %h %p", "the quotes must not survive into argv")
        XCTAssertTrue(args.contains("-C"))
        XCTAssertTrue(args.contains("-X"))
    }

    func testSettingsRoundTripThroughDisk() async throws {
        let store = HostConfigStore(directory: directory)
        let forward = PortForward(
            kind: .local, bindAddress: "127.0.0.1", listenPort: 5432,
            destinationHost: "db.internal", destinationPort: 5432
        )
        let host = StoredHost(
            id: "custom-devbox", name: "devbox", user: "me", port: 2222,
            usesPassword: true, storesPasswordInKeychain: true, forwards: [forward]
        )

        try await store.saveHosts([host])
        let loaded = await store.loadHosts()

        let reloaded = try XCTUnwrap(loaded.first { $0.id == "custom-devbox" })
        XCTAssertEqual(reloaded, host, "the host came back changed")
        XCTAssertEqual(reloaded.forwards.first?.specification, "127.0.0.1:5432:db.internal:5432")
    }

    /// §2.5 — credentials are the Keychain's job. `hosts.json` is plain text the user is invited to
    /// read, and there is deliberately no field in it that could hold a secret.
    func testNoSecretIsEverWrittenToDisk() async throws {
        let store = HostConfigStore(directory: directory)
        try await store.saveHosts([
            StoredHost(
                id: "custom-devbox", name: "devbox", user: "me",
                usesPassword: true, storesPasswordInKeychain: true
            )
        ])

        let written = try String(contentsOf: storeURL, encoding: .utf8)
        // The flags say a password is expected; the password itself has nowhere to live here.
        XCTAssertTrue(written.contains("\"usesPassword\" : true"), written)
        XCTAssertTrue(written.contains("\"storesPasswordInKeychain\" : true"), written)

        let decoded = try JSONSerialization.jsonObject(with: Data(written.utf8)) as? [[String: Any]]
        let keys = Set((decoded ?? []).flatMap(\.keys))
        XCTAssertEqual(
            keys.filter { $0.localizedCaseInsensitiveContains("password") }.sorted(),
            ["storesPasswordInKeychain", "usesPassword"],
            "a new password-ish field appeared in hosts.json: \(keys.sorted())"
        )
    }

    /// The local host is implicit and `ssh-` entries are re-derived from `~/.ssh/config` on each
    /// launch; persisting either leaves stale entries behind when the config changes.
    func testDiscoveredAndLocalHostsAreNotPersisted() async throws {
        let store = HostConfigStore(directory: directory)
        try await store.saveHosts([
            StoredHost(id: "local", name: "localhost", isLocal: true),
            StoredHost(id: "ssh-devbox", name: "devbox"),
            StoredHost(id: "custom-keeper", name: "keeper"),
        ])

        let written = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertTrue(written.contains("custom-keeper"))
        XCTAssertFalse(written.contains("\"local\""))
        XCTAssertFalse(written.contains("ssh-devbox"))
    }
}
