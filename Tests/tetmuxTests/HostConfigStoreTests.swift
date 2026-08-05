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

    /// Writes an `~/.ssh/config` for the store to discover, so the rules below are asserted against a
    /// known file rather than whatever the machine running the tests happens to have.
    private func writeSSHConfig(_ contents: String) throws -> URL {
        let url = directory.appendingPathComponent("ssh_config")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A discovered host that the user *edited* has to survive a relaunch.
    ///
    /// It keeps its `ssh-` id through the editor, and that prefix was the whole persistence filter —
    /// so a port forward or an extra ssh option added to a host from `~/.ssh/config` worked for the
    /// rest of the session and was silently gone on the next launch, while the Keychain item the same
    /// edit wrote survived it. The flag and the secret then disagreed.
    func testEditsToADiscoveredHostSurviveARelaunch() async throws {
        let config = try writeSSHConfig("Host devbox\n  HostName devbox.internal\n  User me\n")
        let store = HostConfigStore(directory: directory, sshConfigURL: config)

        var hosts = await store.loadHosts()
        var devbox = try XCTUnwrap(hosts.first { $0.name == "devbox" })
        XCTAssertTrue(devbox.id.hasPrefix("ssh-"), "expected a discovered host, got \(devbox.id)")

        devbox.forwards = [PortForward(
            kind: .local, bindAddress: "127.0.0.1", listenPort: 5432,
            destinationHost: "db.internal", destinationPort: 5432
        )]
        devbox.extraSshArguments = "-C"
        devbox.storesPasswordInKeychain = true
        hosts = hosts.map { $0.id == devbox.id ? devbox : $0 }
        try await store.saveHosts(hosts)

        let relaunched = HostConfigStore(directory: directory, sshConfigURL: config)
        let afterRelaunch = await relaunched.loadHosts()
        let reloaded = try XCTUnwrap(afterRelaunch.first { $0.name == "devbox" })
        XCTAssertEqual(reloaded, devbox, "the user's edits did not survive the relaunch")
    }

    /// The other half: `~/.ssh/config` stays authoritative. Only the difference is stored, so a host
    /// nobody touched is re-derived, and one whose stanza is deleted goes away.
    func testUneditedDiscoveredHostsAreNotPersistedAndDeletedStanzasDisappear() async throws {
        let config = try writeSSHConfig("Host devbox\n  HostName devbox.internal\n")
        let store = HostConfigStore(directory: directory, sshConfigURL: config)

        let hosts = await store.loadHosts()
        try await store.saveHosts(hosts)
        let written = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertFalse(written.contains("ssh-"), "an untouched discovered host was persisted: \(written)")

        // Edit it, then take its stanza away.
        var devbox = try XCTUnwrap(hosts.first { $0.name == "devbox" })
        devbox.extraSshArguments = "-C"
        try await store.saveHosts(hosts.map { $0.id == devbox.id ? devbox : $0 })

        let emptied = try writeSSHConfig("# nothing here now\n")
        let relaunched = HostConfigStore(directory: directory, sshConfigURL: emptied)
        let reloaded = await relaunched.loadHosts()
        XCTAssertNil(reloaded.first { $0.name == "devbox" }, "a deleted stanza came back from hosts.json")
    }

    /// A corrupt `hosts.json` must not read as "the user has no hosts" and must not be overwritten.
    ///
    /// Both the read and the decode were `try?` with no fallback, so a truncated or hand-mangled file
    /// silently produced an empty list — and then the first edit did load-modify-save and wrote a
    /// single host over the file that still had all the others.
    func testCorruptHostsFileIsPreservedRatherThanOverwritten() async throws {
        let original = "[{\"id\":\"custom-devbox\",\"name\":\"devbox\",\"isLocal\":fal"
        try original.write(to: storeURL, atomically: true, encoding: .utf8)

        let store = HostConfigStore(directory: directory, sshConfigURL: directory.appendingPathComponent("absent"))
        let loaded = await store.loadHosts()
        XCTAssertEqual(loaded.map(\.id), ["local"], "a corrupt file must not yield half a host list")

        let failure = await store.loadFailure
        XCTAssertNotNil(failure, "the failure has to be reportable; silence is what made this invisible")

        // The bad file is kept under another name, so the data is recoverable by hand.
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("hosts.json.corrupt-") }
        XCTAssertEqual(kept.count, 1, "expected the unreadable file to be moved aside, found \(kept)")
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent(kept[0]), encoding: .utf8),
            original
        )

        // And the ordinary save that follows writes a fresh file rather than destroying the old one.
        try await store.saveHosts(loaded + [StoredHost(id: "custom-new", name: "new")])
        XCTAssertTrue(try String(contentsOf: storeURL, encoding: .utf8).contains("custom-new"))
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent(kept[0]), encoding: .utf8),
            original,
            "the preserved copy was clobbered by the next save"
        )
    }

    func testEmptyHostsFileIsNotTreatedAsCorruption() async throws {
        try Data().write(to: storeURL)
        let store = HostConfigStore(directory: directory, sshConfigURL: directory.appendingPathComponent("absent"))
        _ = await store.loadHosts()

        let failure = await store.loadFailure
        XCTAssertNil(failure, "a zero-length file is an interrupted write, not something to preserve")
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix("hosts.json.corrupt-") }
        )
    }

    // MARK: - F4.2, `ssh -G`

    /// Captured verbatim from OpenSSH on this machine, for a stanza with everything set. The point of
    /// a real capture rather than a plausible one is the `identityfile` run below: nothing about the
    /// format suggests a key may repeat, and getting that wrong is silent.
    func testEffectiveConfigIsParsedFromRealSshOutput() {
        let output = """
        host devbox
        user deploy
        hostname 10.0.0.7
        port 2222
        identityfile ~/.ssh/id_deploy
        proxyjump bastion.example.com
        """
        let config = HostConfigStore.parseEffectiveConfig(output)
        XCTAssertEqual(config["user"], "deploy")
        XCTAssertEqual(config["hostname"], "10.0.0.7")
        XCTAssertEqual(config["port"], "2222")
        XCTAssertEqual(config["proxyjump"], "bastion.example.com")
    }

    /// `ssh -G` prints one `identityfile` line per candidate key, and with no `IdentityFile` set that
    /// is every default it would try. A last-wins map reported the last of those — `id_ed25519_sk` on
    /// this machine — as though someone had chosen it. First wins instead, which is also ssh's own
    /// precedence for the scalar options that make up the rest of the output.
    func testARepeatedKeyKeepsItsFirstValue() {
        let output = """
        user me
        hostname localhost
        port 22
        identitiesonly no
        identityfile ~/.ssh/id_rsa
        identityfile ~/.ssh/id_ecdsa
        identityfile ~/.ssh/id_ecdsa_sk
        identityfile ~/.ssh/id_ed25519
        identityfile ~/.ssh/id_ed25519_sk
        """
        XCTAssertEqual(HostConfigStore.parseEffectiveConfig(output)["identityfile"], "~/.ssh/id_rsa")
    }

    /// Values containing spaces are one value, not a key and a fragment: `ProxyCommand` is the case
    /// that matters, and truncating it would show the user a command that is not the one ssh runs.
    func testAValueKeepsItsSpaces() {
        let config = HostConfigStore.parseEffectiveConfig("proxycommand /usr/bin/nc -X 5 -x host:1080 %h %p")
        XCTAssertEqual(config["proxycommand"], "/usr/bin/nc -X 5 -x host:1080 %h %p")
    }

    /// The empty map is what a caller falls back from, so it has to be reachable: ssh writes nothing
    /// to stdout when it cannot make sense of a name, and its complaint goes to stderr, which this
    /// never reads. A line with no value is not a setting either.
    func testNothingUsableYieldsAnEmptyMap() {
        XCTAssertTrue(HostConfigStore.parseEffectiveConfig("").isEmpty)
        XCTAssertTrue(HostConfigStore.parseEffectiveConfig("\n\n  \n").isEmpty)
        XCTAssertTrue(HostConfigStore.parseEffectiveConfig("compression").isEmpty)
    }

    /// The real subprocess, against a name ssh always understands. Asserts only that the three fields
    /// the editor reads come back — everything else is this machine's `~/.ssh/config` and not
    /// something a test may have an opinion about.
    func testSshResolvesLocalhost() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh"),
            "no ssh to ask"
        )
        let config = await HostConfigStore.resolveEffectiveConfig(for: "localhost")
        XCTAssertEqual(config["hostname"], "localhost")
        XCTAssertEqual(config["port"], "22")
        XCTAssertNotNil(config["user"])
    }
}
