import XCTest
@testable import tetmux_relay

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
