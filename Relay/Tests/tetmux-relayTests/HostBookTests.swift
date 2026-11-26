import XCTest
@testable import tetmux_relay
import tetmuxCore

/// A destination typed on a phone becomes an argument to `ssh` on the server, so what is let through
/// is narrow: anything that could be read as an option, or split into two arguments, is refused.
final class HostBookTests: XCTestCase {
    func testUserAtHostSplits() throws {
        let parsed = try HostBook.parse("me@build.example.org")
        XCTAssertEqual(parsed.user, "me")
        XCTAssertEqual(parsed.host, "build.example.org")
    }

    func testAHostAloneHasNoUser() throws {
        let parsed = try HostBook.parse("  10.0.0.4 ")
        XCTAssertNil(parsed.user)
        XCTAssertEqual(parsed.host, "10.0.0.4")
    }

    func testAnIPv6AddressIsAccepted() throws {
        XCTAssertEqual(try HostBook.parse("fe80::1").host, "fe80::1")
    }

    func testAnythingThatReadsAsAnSshOptionIsRefused() {
        XCTAssertThrowsError(try HostBook.parse("-oProxyCommand=touch /tmp/x"))
        XCTAssertThrowsError(try HostBook.parse("-p"))
        XCTAssertThrowsError(try HostBook.parse("-oUser@box"))
    }

    func testWhitespaceAndShellCharactersAreRefused() {
        XCTAssertThrowsError(try HostBook.parse("box extra"))
        XCTAssertThrowsError(try HostBook.parse("box;reboot"))
        XCTAssertThrowsError(try HostBook.parse("me@box\nrm"))
        XCTAssertThrowsError(try HostBook.parse("$(id)@box"))
    }

    func testEmptyPartsAndExtraAtsAreRefused() {
        XCTAssertThrowsError(try HostBook.parse(""))
        XCTAssertThrowsError(try HostBook.parse("me@"))
        XCTAssertThrowsError(try HostBook.parse("@box"))
        XCTAssertThrowsError(try HostBook.parse("a@b@c"))
    }

    /// Letters from other scripts look like ASCII ones and are not what a hostname field should take.
    func testNonASCIIIsRefused() {
        XCTAssertThrowsError(try HostBook.parse("exаmple.com"))  // Cyrillic а
    }
}

/// Editing and removing go through `hosts.json`, against a store in a scratch directory and an ssh
/// config that does not exist, so nothing here reads or writes the machine's own files.
final class HostBookEditTests: XCTestCase {
    private var directory: URL!
    private var store: HostConfigStore!
    private var service: SessionService!
    private var book: HostBook!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = HostConfigStore(directory: directory, sshConfigURL: directory.appendingPathComponent("no-config"))
        service = SessionService()
        book = HostBook(store: store, service: service, saved: [])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAnEditChangesTheDestinationAndKeepsEverythingElse() async throws {
        let id = try await book.add(destination: "me@old.example.org", port: nil, name: "box")
        var hosts = await store.loadHosts()
        let index = try XCTUnwrap(hosts.firstIndex { $0.id == id })
        hosts[index].extraSshArguments = "-o ServerAliveInterval=30"
        try await store.saveHosts(hosts)

        let moved = try await book.edit(id: id, destination: "you@new.example.org", port: 2222, name: "box")
        XCTAssertTrue(moved)
        let editable = await book.editableIds
        XCTAssertEqual(editable, [id])
        let reloaded = await store.loadHosts()
        let saved = try XCTUnwrap(reloaded.first { $0.id == id })
        XCTAssertEqual(saved.user, "you")
        XCTAssertEqual(saved.hostname, "new.example.org")
        XCTAssertEqual(saved.port, 2222)
        XCTAssertEqual(saved.extraSshArguments, "-o ServerAliveInterval=30")
        let live = await service.getHost(id)?.config
        XCTAssertEqual(live?.hostname, "new.example.org")
        XCTAssertEqual(live?.port, 2222)
    }

    func testARenameAloneDoesNotReconnect() async throws {
        let id = try await book.add(destination: "me@box.example.org", port: 22, name: "box")
        let moved = try await book.edit(id: id, destination: "me@box.example.org", port: 22, name: "build")
        XCTAssertFalse(moved)
        let name = await service.getHost(id)?.config.name
        XCTAssertEqual(name, "build")
    }

    func testAnEditIsCheckedLikeAnAdd() async throws {
        let id = try await book.add(destination: "me@box", port: nil, name: "box")
        _ = try await book.add(destination: "me@other", port: nil, name: "other")
        await assertThrows { try await self.book.edit(id: id, destination: "-oProxyCommand=x", port: nil, name: nil) }
        await assertThrows { try await self.book.edit(id: id, destination: "me@box", port: 70000, name: nil) }
        await assertThrows { try await self.book.edit(id: id, destination: "me@box", port: nil, name: "other") }
    }

    func testTheLocalHostCannotBeEditedOrRemoved() async {
        await assertThrows { try await self.book.edit(id: "local", destination: "me@box", port: nil, name: nil) }
        await assertThrows { try await self.book.remove(id: "local") }
        await assertThrows { try await self.book.remove(id: "nowhere") }
    }

    func testRemovingTakesTheHostOffTheFileAndTheService() async throws {
        let id = try await book.add(destination: "me@box", port: nil, name: "box")
        try await book.remove(id: id)
        let saved = await store.loadHosts()
        XCTAssertFalse(saved.contains { $0.id == id })
        let gone = await service.getHost(id)
        XCTAssertNil(gone)
        let editable = await book.editableIds
        XCTAssertEqual(editable, [])
    }

    private func assertThrows(_ body: () async throws -> some Any, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("did not throw", line: line)
        } catch {}
    }
}

final class RelayKeyTests: XCTestCase {
    private var home: URL!

    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    func testNoKeysIsEmpty() {
        XCTAssertEqual(RelayKey.find(home: home), [])
    }

    /// A `.pub` whose private half is gone is not a key ssh can offer.
    func testAPublicHalfAloneIsNotListed() throws {
        let ssh = RelayKey.sshDirectory(home: home)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try "ssh-ed25519 AAAA orphan\n".write(to: ssh.appendingPathComponent("id_ed25519.pub"), atomically: true, encoding: .utf8)
        XCTAssertEqual(RelayKey.find(home: home), [])
    }

    func testGeneratingMakesAnEd25519KeyAndWillNotReplaceIt() throws {
        let key = try RelayKey.generate(home: home, comment: "tetmux-relay@test")
        XCTAssertEqual(key.path, "~/.ssh/id_ed25519.pub")
        XCTAssertTrue(key.key.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(key.key.hasSuffix(" tetmux-relay@test"))
        XCTAssertEqual(RelayKey.find(home: home), [key])
        XCTAssertThrowsError(try RelayKey.generate(home: home, comment: "again"))
        XCTAssertEqual(RelayKey.find(home: home), [key])
    }
}
