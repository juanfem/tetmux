import XCTest
@testable import tetmuxCore

/// R3.5 and the geometry regression suite from §8: layout strings with expected view trees.
/// Every fixture here is a real string emitted by tmux 3.7b.
final class LayoutParserTests: XCTestCase {

    func testSinglePane() throws {
        let node = try LayoutParser.parse("5967,80x24,0,0,18")
        XCTAssertEqual(node, .leaf(paneId: "%18", width: 80, height: 24, x: 0, y: 0))
        XCTAssertEqual(node.paneIds, ["%18"])
    }

    func testLayoutWithoutChecksumPrefix() throws {
        let node = try LayoutParser.parse("80x24,0,0,1")
        XCTAssertEqual(node.paneIds, ["%1"])
    }

    func testSideBySideSplit() throws {
        let node = try LayoutParser.parse("bb11,80x24,0,0{40x24,0,0,20,39x24,41,0,21}")
        guard case .container(let direction, let width, let height, _, _, let children) = node else {
            return XCTFail("expected a container")
        }
        XCTAssertEqual(direction, .leftRight, "tmux uses {} for panes side by side")
        XCTAssertEqual(width, 80)
        XCTAssertEqual(height, 24)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(node.paneIds, ["%20", "%21"])
        XCTAssertEqual(children[0].width, 40)
        XCTAssertEqual(children[1].x, 41)
    }

    func testStackedSplit() throws {
        let node = try LayoutParser.parse("abcd,80x24,0,0[80x12,0,0,1,80x11,0,13,2]")
        guard case .container(let direction, _, _, _, _, let children) = node else {
            return XCTFail("expected a container")
        }
        XCTAssertEqual(direction, .topBottom, "tmux uses [] for stacked panes")
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(node.paneIds, ["%1", "%2"])
    }

    /// A real three-pane nested layout: one full-height pane on the left, two stacked on the right.
    func testNestedLayout() throws {
        let layout = "273c,200x50,0,0{100x50,0,0,23,99x50,101,0[99x25,101,0,24,99x24,101,26,25]}"
        let node = try LayoutParser.parse(layout)

        XCTAssertEqual(node.paneIds, ["%23", "%24", "%25"])
        XCTAssertEqual(node.cellSize(ofPane: "%23")?.cols, 100)
        XCTAssertEqual(node.cellSize(ofPane: "%23")?.rows, 50)
        XCTAssertEqual(node.cellSize(ofPane: "%24")?.rows, 25)
        XCTAssertEqual(node.cellSize(ofPane: "%25")?.rows, 24)
        XCTAssertNil(node.cellSize(ofPane: "%99"))

        guard case .container(_, _, _, _, _, let children) = node,
              case .container(let innerDirection, _, _, _, _, let inner) = children[1] else {
            return XCTFail("expected a nested container on the right")
        }
        XCTAssertEqual(innerDirection, .topBottom)
        XCTAssertEqual(inner.count, 2)
    }

    func testChecksumMatchesTmuxsAlgorithm() {
        // Verified against the prefixes tmux itself emitted for these bodies.
        XCTAssertEqual(LayoutParser.computeChecksum("80x24,0,0,18"), UInt16(0x5967))
        XCTAssertEqual(
            LayoutParser.computeChecksum("200x50,0,0{100x50,0,0,23,99x50,101,0[99x25,101,0,24,99x24,101,26,25]}"),
            UInt16(0x273c)
        )
    }

    func testChecksumVerificationIsOptOut() throws {
        // Body is valid, checksum prefix is not.
        XCTAssertNoThrow(try LayoutParser.parse("0000,80x24,0,0,1"))
        XCTAssertThrowsError(try LayoutParser.parse("0000,80x24,0,0,1", verifyChecksum: true)) { error in
            guard case LayoutParseError.checksumMismatch = error else {
                return XCTFail("expected .checksumMismatch, got \(error)")
            }
        }
    }

    // MARK: - Malformed input must fail, not hang

    func testMalformedLayoutsThrowRatherThanLoop() {
        let bad = [
            "",
            "   ",
            "notalayout",
            "80x24",
            "80x24,0",
            "80x24,0,0",
            "80x24,0,0{",
            "80x24,0,0{40x24,0,0,1",
            "80x24,0,0{40x24,0,0,1;39x24,41,0,2}",
            "80x24,0,0[]",
            "80x24,0,0,1,trailing",
            // The pre-fix failure: three space-separated fields fed in as one layout string.
            "bb11,80x24,0,0{40x24,0,0,20,39x24,41,0,21} bb11,80x24,0,0{40x24,0,0,20,39x24,41,0,21} *",
        ]
        for layout in bad {
            XCTAssertThrowsError(try LayoutParser.parse(layout), "should have rejected: \(layout)")
        }
    }

    func testDeeplyNestedLayoutDoesNotBlowUp() throws {
        // Eight nested splits — deeper than anyone builds by hand, shallow enough to be legal.
        var layout = "80x24,0,0,1"
        for _ in 0..<8 {
            layout = "80x24,0,0{\(layout),80x24,0,0,1}"
        }
        XCTAssertEqual(try LayoutParser.parse(layout).paneIds.count, 9)
    }

    /// Both of these used to take the whole application down rather than fail the parse, and neither
    /// could be contained by the `try?` at the call sites: Swift traps on arithmetic overflow, and a
    /// stack overflow is not catchable either. The input is bytes off the wire — a `%layout-change`
    /// garbled by a noisy link is enough.
    func testAbsurdNumbersAreRejectedRatherThanTrapping() {
        // Twenty digits: past Int64 before the parser has finished the first field.
        XCTAssertThrowsError(try LayoutParser.parse("99999999999999999999x24,0,0,1"))
        XCTAssertThrowsError(try LayoutParser.parse("80x24,0,0,99999999999999999999"))
        // The boundary is still parsed, so the guard cannot be rejecting ordinary geometry.
        XCTAssertNoThrow(try LayoutParser.parse("\(Int.max)x24,0,0,1"))
    }

    func testNestingDeeperThanTheCapIsRejectedRatherThanOverflowingTheStack() {
        var layout = "80x24,0,0,1"
        for _ in 0..<5000 {
            layout = "80x24,0,0{\(layout),80x24,0,0,1}"
        }
        XCTAssertThrowsError(try LayoutParser.parse(layout))
    }
}
