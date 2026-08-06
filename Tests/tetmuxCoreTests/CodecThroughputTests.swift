import XCTest
@testable import tetmuxCore

/// P6.3 — sustained `%output` throughput, measured on the parser.
///
/// P6.3 asks for 50 MB/s on one pane without reordering or blocking the main thread. That is a
/// property of the whole pipeline — pty read, codec, delivery, emulator — and most of it cannot be
/// measured without a machine, a window server and a person not typing. The codec can: it is a pure
/// value type with no I/O, so what it costs is the same here as it is in the app, and it is the one
/// part of the chain that is *guaranteed* to touch every byte.
///
/// So this asserts a **necessary condition**, not the requirement: if the parser cannot clear the
/// bar on its own it certainly cannot while sharing a machine with everything else. The floor is set
/// far enough below what the parser does that it fails for a regression rather than for a busy
/// runner — see `docs/measurements.md`, which records what it actually measured and on what.
///
/// The fixtures are recordings (`Scripts/capture-throughput.py`). The escaping is the whole cost —
/// `\033` is four bytes on the wire for one in the pane — and its density is exactly what a
/// hand-written stream would get wrong.
final class CodecThroughputTests: XCTestCase {

    /// How much wire traffic each measurement parses.
    ///
    /// Large enough that the timer is measuring the parser rather than its own resolution, and that
    /// one scheduling hiccup cannot move the answer much; small enough that the whole suite stays a
    /// suite. At the rates below this is a fraction of a second.
    private let measuredBytes = 16 * 1024 * 1024

    /// What the app hands the codec in one call: `PtyTransport` reads into a 64 KiB buffer and feeds
    /// whatever it got. Feeding the whole stream in one call would measure a case that never happens
    /// and would skip the line-buffer boundary handling entirely — every chunk boundary here falls
    /// mid-`%output`, which is the realistic and more expensive case.
    private let readSize = 64 * 1024

    /// P6.3's floor, and the reason there are two of them.
    ///
    /// 50 MB/s is a promise about the binary that ships, which is the optimised one. A debug build
    /// of this parser measures **17× slower** — no optimisation, a retain/release around every
    /// array, bounds checks on every subscript — so asserting 50 against it would fail on a correct
    /// codec, and lowering the real floor to suit it would assert nothing about the release build
    /// anybody runs.
    ///
    /// So the debug floor is a different kind of claim: an order-of-magnitude tripwire, set well
    /// under the measured debug rate so a slower runner does not trip it, and well over the rate a
    /// complexity regression produces. It is calibrated against a real one — the first version of
    /// this test held the codec in its pre-handshake state, where a substring search allocates at
    /// every position, and that measured 2 MB/s in debug against 18 for the same bytes parsed
    /// properly. That is the shape of mistake this catches. A 20% slowdown it will not, and it does
    /// not pretend to; `Scripts/measure-throughput.sh` is where a number worth comparing comes from.
    private var floorMegabytesPerSecond: Double {
        #if DEBUG
        return 5
        #else
        return 50
        #endif
    }

    func testPlainOutputParsesAboveTheFloor() throws {
        let result = try measureThroughput(fixture: "throughput-text")
        report("text", result)
        XCTAssertGreaterThan(result.paneMegabytesPerSecond, floorMegabytesPerSecond)
    }

    /// The one that decides. Colourised output is roughly one escaped byte in eight, so the fast
    /// path in `unescapeOctal` — no backslash, return the input — never fires and every line is
    /// walked byte by byte into a fresh array.
    func testEscapeHeavyOutputParsesAboveTheFloor() throws {
        let result = try measureThroughput(fixture: "throughput-escapes")
        report("escapes", result)
        XCTAssertGreaterThan(result.paneMegabytesPerSecond, floorMegabytesPerSecond)
    }

    /// The measurement is worth nothing if the parser is fast because it is dropping the payload, so
    /// this pins what the fixtures decode to. Both are one pane, and every byte of every `%output`
    /// has to arrive in order.
    func testTheMeasuredStreamIsFullyDecoded() throws {
        let recorded = try recording("throughput-escapes")
        let body = recorded.handshake + recorded.output
        var codec = ControlCodec()
        var paneBytes = 0
        var panes: Set<String> = []
        for event in codec.feed(body) {
            guard case let .output(paneId, data) = event else { continue }
            panes.insert(paneId)
            paneBytes += data.count
        }
        XCTAssertEqual(panes, ["%0"])
        // Every line is `%output %0 ` plus a payload that only shrinks, so the decoded total lands
        // strictly between "nothing" and the wire size. A codec that silently dropped a chunk, or
        // one that stopped escaping, would leave this range.
        XCTAssertGreaterThan(paneBytes, body.count / 2)
        XCTAssertLessThan(paneBytes, body.count)
    }

    // MARK: - Harness

    private struct Result {
        let wireBytes: Int
        let paneBytes: Int
        let seconds: Double

        /// What the parser consumed, which is what a link delivers.
        var wireMegabytesPerSecond: Double { Double(wireBytes) / seconds / 1_048_576 }
        /// What reached the pane, which is what P6.3 is a promise about. Always the smaller of the
        /// two, and the one worth asserting for that reason.
        var paneMegabytesPerSecond: Double { Double(paneBytes) / seconds / 1_048_576 }
    }

    private func measureThroughput(fixture: String) throws -> Result {
        let stream = try repeated(try recording(fixture), toAtLeast: measuredBytes)
        var codec = ControlCodec()
        var paneBytes = 0

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            var offset = 0
            while offset < stream.count {
                let end = min(offset + readSize, stream.count)
                for event in codec.feed(stream[offset..<end]) {
                    if case let .output(_, data) = event { paneBytes += data.count }
                }
                offset = end
            }
        }

        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        XCTAssertGreaterThan(paneBytes, 0, "nothing was decoded, so nothing was measured")
        return Result(wireBytes: stream.count, paneBytes: paneBytes, seconds: seconds)
    }

    /// A recording split where the handshake ends and the output begins.
    ///
    /// Both halves are load-bearing and for opposite reasons, which the first version of this got
    /// wrong in both directions at once. The handshake must be **kept**, once: `ControlCodec` skips
    /// anything before the first `%begin` — an ssh banner, the DCS introducer — and while it is
    /// still looking, every line goes through a substring search that allocates at each position.
    /// Dropped, the codec never leaves that state and the measurement is of a startup path the app
    /// runs a handful of lines through. It measured 23 MB/s, and the parser was not the slow part.
    ///
    /// And the handshake must not be **repeated**: it opens a `%begin` block, so a copy every 190 KB
    /// would make every `%output` after it response *content* rather than a notification — framing
    /// outranks dispatch — which is a thing the app never asks of the parser either.
    private func recording(_ fixture: String) throws -> (handshake: [UInt8], output: [UInt8]) {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: fixture, withExtension: "stream", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: fixture, withExtension: "stream"),
            "missing fixture \(fixture).stream — run Scripts/capture-throughput.py"
        )
        let bytes = [UInt8](try Data(contentsOf: url))
        let marker = Array("%output ".utf8)
        let start = try XCTUnwrap(
            (0...(bytes.count - marker.count)).first { index in
                (index == 0 || bytes[index - 1] == UInt8(ascii: "\n"))
                    && Array(bytes[index..<index + marker.count]) == marker
            },
            "fixture carries no %output line"
        )
        return (Array(bytes[..<start]), Array(bytes[start...]))
    }

    /// The handshake once, then the output over and over until it is big enough.
    ///
    /// Repetition rather than a bigger fixture, because the quantity being measured is a *rate*: a
    /// megabyte in git buys nothing over a repeat, and a fixture of any size anyone would commit
    /// fits in L2 either way, so the bigger file would not take back the cache advantage. What it
    /// would take is the ability to read the fixture in a diff.
    private func repeated(
        _ recording: (handshake: [UInt8], output: [UInt8]),
        toAtLeast target: Int
    ) throws -> [UInt8] {
        try XCTSkipIf(recording.output.isEmpty, "empty fixture")
        var stream = recording.handshake
        stream.reserveCapacity(target + recording.output.count)
        while stream.count < target { stream.append(contentsOf: recording.output) }
        return stream
    }

    /// Printed rather than only asserted: the number is the point, and `docs/measurements.md` is
    /// where a run gets written down. A pass that says only "above 50" tells nobody whether the
    /// margin is ten times or ten percent.
    private func report(_ label: String, _ result: Result) {
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let line = String(
            format: "P6.3 %@ (%@): %.0f MB/s pane, %.0f MB/s wire (%.1f MB wire in %.3f s)",
            label, configuration, result.paneMegabytesPerSecond, result.wireMegabytesPerSecond,
            Double(result.wireBytes) / 1_048_576, result.seconds
        )
        print(line)
    }
}
