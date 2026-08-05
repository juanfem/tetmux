import XCTest
@testable import tetmuxCore

/// R3.6 — the codec replayed against real byte streams from **every** tmux version the SRD names.
///
/// Everything else in the suite is captured from 3.7b, which meant the version-conditional paths
/// were all untested on the versions they exist for: the integration tests self-skip on an old
/// server rather than exercising the fallback, and `TmuxVersion`'s own tests cover the predicate
/// rather than what is behind it. These fixtures were recorded by driving each of tmux 3.0, 3.2a,
/// 3.3a, 3.4 and 3.5 under a pty — see `Scripts/build-tmux-matrix.sh` and
/// `Scripts/capture-fixtures.py`, which are how anyone can rebuild and re-record them.
///
/// **What is asserted is structure, not bytes.** A capture carries wall-clock timestamps and
/// server-wide command numbers, so two recordings of the same version are never byte-identical and
/// a golden-file comparison would fail for reasons that mean nothing. What must hold is that the
/// same user actions yield the same *model* on every version — which is the whole promise the
/// version-conditional code is making — and that the handful of genuine protocol differences are
/// where the code believes they are.
final class ControlCodecMatrixTests: XCTestCase {

    /// The versions R3.6 names, in order.
    static let versions = ["3.0", "3.2a", "3.3a", "3.4", "3.5"]

    // MARK: - Loading

    private func fixture(_ version: String, _ scenario: String) throws -> [UInt8] {
        let name = "tmux-\(version).\(scenario)"
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "stream", subdirectory: "Fixtures"
        ) else {
            throw XCTSkip("missing fixture \(name).stream — run Scripts/capture-fixtures.py")
        }
        return Array(try Data(contentsOf: url))
    }

    /// Feeds a fixture through a fresh codec in one go.
    private func events(_ version: String, _ scenario: String) throws -> [ControlEvent] {
        var codec = ControlCodec()
        return codec.feed(try fixture(version, scenario))
    }

    /// The same fixture fed one byte at a time.
    ///
    /// The codec is a `mutating func feed(_:) -> [ControlEvent]` with no I/O precisely so this is
    /// possible, and it is the property that matters on a real channel: bytes arrive in whatever
    /// chunks the pty hands over, and a line — or a `%begin` block — can be split anywhere.
    private func eventsByteByByte(_ version: String, _ scenario: String) throws -> [ControlEvent] {
        var codec = ControlCodec()
        var collected: [ControlEvent] = []
        for byte in try fixture(version, scenario) {
            collected.append(contentsOf: codec.feed([byte]))
        }
        return collected
    }

    // MARK: - Every version, every scenario

    /// Chunking must not change the event stream, on any version.
    ///
    /// This is the cheapest test here and the one most likely to catch a real bug: every fixture,
    /// fed whole and fed one byte at a time, must yield exactly the same events. A codec that keeps
    /// any state outside its buffer fails it, and on a live channel that failure looks like an
    /// occasional lost notification under load rather than anything reproducible.
    func testEveryFixtureParsesIdenticallyWhateverTheChunking() throws {
        for version in Self.versions {
            for scenario in Self.scenarios {
                let whole = try events(version, scenario)
                let dribbled = try eventsByteByByte(version, scenario)
                XCTAssertEqual(whole, dribbled, "tmux \(version), \(scenario)")
                XCTAssertFalse(whole.isEmpty, "tmux \(version), \(scenario): no events at all")
            }
        }
    }

    /// Command blocks are balanced on every version: every `%begin` is closed by an `%end` or
    /// `%error` carrying its own number, and nothing closes a block that was never opened.
    ///
    /// This is the invariant `SessionService` stakes its correlation on. It matches responses to
    /// commands by *order*, because tmux's numbers are server-wide and unpredictable at send time,
    /// so one unmatched block shifts the queue for the life of the channel — silently.
    func testCommandBlocksAreBalancedOnEveryVersion() throws {
        for version in Self.versions {
            for scenario in Self.scenarios {
                var open: Int?
                for event in try events(version, scenario) {
                    switch event {
                    case .begin(_, let number, _):
                        XCTAssertNil(open, "tmux \(version), \(scenario): %begin \(number) inside \(open!)")
                        open = number
                    case .end(_, let number, _), .error(_, let number, _):
                        XCTAssertEqual(open, number, "tmux \(version), \(scenario): terminator mismatch")
                        open = nil
                    case .commandResultLine(let number, _, _):
                        XCTAssertEqual(open, number, "tmux \(version), \(scenario): body outside its block")
                    default:
                        break
                    }
                }
                XCTAssertNil(open, "tmux \(version), \(scenario): block \(open ?? -1) never closed")
            }
        }
    }

    /// tmux ≥ 2.5 sends `%layout-change` with **three** fields, and all five of these are ≥ 2.5.
    ///
    /// The bug this pins cost every pane on screen: folding the three into one layout string makes
    /// it unparseable, so the window gets no pane tree and renders nothing. Asserted on every
    /// version because the *number of fields* is the thing that varied historically, and a fixture
    /// is the only way to know rather than assume.
    func testLayoutChangeCarriesThreeFieldsOnEveryVersion() throws {
        for version in Self.versions {
            var seen = 0
            for event in try events(version, "split") {
                guard case .layoutChange(let windowId, let layout, let visible, let flags) = event else {
                    continue
                }
                seen += 1
                XCTAssertTrue(windowId.hasPrefix("@"), "tmux \(version): id lost its sigil")
                XCTAssertNotNil(visible, "tmux \(version): no visible layout — the fields were folded")
                XCTAssertNotNil(flags, "tmux \(version): no flags field")
                XCTAssertNoThrow(
                    try LayoutParser.parse(layout, verifyChecksum: true),
                    "tmux \(version): layout did not parse — \(layout)"
                )
                XCTAssertNoThrow(
                    try LayoutParser.parse(XCTUnwrap(visible), verifyChecksum: true),
                    "tmux \(version): visible layout did not parse"
                )
            }
            XCTAssertGreaterThan(seen, 0, "tmux \(version): splitting produced no %layout-change")
        }
    }

    /// Two splits produce a three-pane window, and the same one, on every version.
    ///
    /// The point is not that the layout string is identical — it happens to be, at a fixed 80x24 —
    /// but that the model built from the stream does not depend on which tmux produced it.
    func testTheSameSplitsBuildTheSameWindowOnEveryVersion() throws {
        var perVersion: [String: [String]] = [:]
        for version in Self.versions {
            var window = TmuxWindow(id: "@0", name: "fixture")
            for event in try events(version, "split") {
                if case .layoutChange(_, let layout, let visible, let flags) = event {
                    window.apply(layoutString: layout, visibleLayout: visible, flags: flags)
                }
            }
            XCTAssertEqual(window.paneCount, 3, "tmux \(version)")
            perVersion[version] = window.layoutTree?.paneIds ?? []
        }
        let distinct = Set(perVersion.values.map(\.description))
        XCTAssertEqual(distinct.count, 1, "the versions disagreed about the panes: \(perVersion)")
    }

    /// Zoom, on every version: `window_layout` stays what the window *would* be unzoomed, and only
    /// the visible layout and the `Z` flag say what is on screen.
    ///
    /// Rendering the wrong one forces every surface to its unzoomed cell size while tmux emits
    /// output sized to the whole window — wrapped and truncated, and unrecoverable without
    /// unzooming from somewhere else. This is the fixture that says the rule holds back to 3.0.
    func testZoomIsCarriedByTheVisibleLayoutOnEveryVersion() throws {
        for version in Self.versions {
            var window = TmuxWindow(id: "@0", name: "fixture")
            var sawZoom = false

            for event in try events(version, "zoom") {
                guard case .layoutChange(_, let layout, let visible, let flags) = event else { continue }
                window.apply(layoutString: layout, visibleLayout: visible, flags: flags)

                guard flags?.contains("Z") == true else { continue }
                sawZoom = true
                XCTAssertTrue(window.isZoomed, "tmux \(version)")
                XCTAssertNotEqual(
                    visible, layout,
                    "tmux \(version): a zoomed window whose two layouts match tells a client nothing"
                )
                // What is drawn is the single full-size pane…
                XCTAssertEqual(window.renderTree?.paneIds.count, 1, "tmux \(version)")
                // …while the window still *holds* both, or a zoomed split relabels itself as one pane.
                XCTAssertEqual(window.paneCount, 2, "tmux \(version)")
            }

            XCTAssertTrue(sawZoom, "tmux \(version): no zoomed %layout-change in the fixture")
            // And unzooming puts it back, on every version.
            XCTAssertFalse(window.isZoomed, "tmux \(version): still zoomed after the second toggle")
            XCTAssertEqual(window.renderTree?.paneIds.count, 2, "tmux \(version)")
        }
    }

    /// `%output` payloads are octal-escaped and arbitrary binary, and the escaping is identical
    /// across the matrix. Decoding must happen on **bytes** — a `String` round trip loses anything
    /// that is not valid UTF-8, which pane output routinely is not.
    ///
    /// The fixture sends four things through `cat`: plain text, an ESC sequence, a backslash that is
    /// data rather than an escape, and multi-byte UTF-8.
    func testOutputEscapingDecodesTheSameOnEveryVersion() throws {
        for version in Self.versions {
            var decoded = Data()
            for event in try events(version, "output") {
                if case .output(let paneId, let data) = event {
                    XCTAssertTrue(paneId.hasPrefix("%"), "tmux \(version): pane id lost its sigil")
                    decoded.append(data)
                }
            }
            let text = String(decoding: decoded, as: UTF8.self)
            XCTAssertTrue(text.contains("hello"), "tmux \(version)")
            // `\134` is a backslash, so this must come back as data and not as an escape.
            XCTAssertTrue(text.contains(#"\not-an-escape"#), "tmux \(version): backslash mis-decoded")
            XCTAssertTrue(text.contains("éü€"), "tmux \(version): UTF-8 did not survive")
            // The ESC of the echoed `\033[1m`, as a byte rather than as the four characters.
            XCTAssertTrue(decoded.contains(0x1b), "tmux \(version): no raw ESC in the decoded output")
        }
    }

    /// Renaming reports the same way on every version, and the id keeps its sigil.
    ///
    /// `%session-renamed` is the interesting one: it carries `$id name` on tmux ≥ 2.4 and the name
    /// alone before that. All five here are ≥ 2.4, so all five must carry the id — and
    /// `reconnectTarget` depends on it, since it is a session *name* and a stale one makes the
    /// reconnect path create an empty session under it.
    func testRenamesReportTheSameWayOnEveryVersion() throws {
        for version in Self.versions {
            var windowNames: [String] = []
            var sessionRenames: [(String?, String)] = []

            for event in try events(version, "rename") {
                switch event {
                case .windowRenamed(let windowId, let name):
                    XCTAssertTrue(windowId.hasPrefix("@"), "tmux \(version)")
                    windowNames.append(name)
                case .sessionRenamed(let sessionId, let name):
                    sessionRenames.append((sessionId, name))
                default:
                    break
                }
            }

            XCTAssertEqual(windowNames, ["fixture-window", "back"], "tmux \(version)")
            XCTAssertEqual(sessionRenames.count, 1, "tmux \(version)")
            XCTAssertEqual(sessionRenames.first?.1, "fixture-session", "tmux \(version)")
            XCTAssertEqual(
                sessionRenames.first?.0, "$0",
                "tmux \(version): %session-renamed dropped the id — reconnectTarget depends on it"
            )
        }
    }

    /// A deliberate `detach-client` ends with a bare `%exit` on every version.
    ///
    /// This is the single thing separating "the session ended" from "the link died": a dropped ssh
    /// connection produces EOF and nothing else, while tmux ending a client always announces it
    /// first. Without the distinction the recovery path treats a deliberate close as a blip and
    /// reconnects with `new-session -A`, recreating the session the user just closed.
    func testDetachEndsWithExitOnEveryVersion() throws {
        for version in Self.versions {
            let stream = try events(version, "detach")
            let exits = stream.filter { if case .exit = $0 { return true } else { return false } }
            XCTAssertEqual(exits.count, 1, "tmux \(version): expected exactly one %exit")
            guard case .exit = stream.last else {
                return XCTFail("tmux \(version): %exit was not the last event — got \(String(describing: stream.last))")
            }
        }
    }

    /// Killing a window out of a session that has another one announces the window's death.
    func testKillingAWindowIsAnnouncedOnEveryVersion() throws {
        for version in Self.versions {
            let closed = try events(version, "kill").contains {
                if case .windowClose = $0 { return true }
                if case .unlinkedWindowClose = $0 { return true }
                return false
            }
            XCTAssertTrue(closed, "tmux \(version): no %window-close after kill-window")
        }
    }

    /// Ending the session the client is attached to announces itself with a bare `%exit`, on every
    /// version — the same shape a deliberate `detach-client` produces.
    ///
    /// That the two are indistinguishable is the point, not a shortcoming: both mean "tmux ended
    /// this client on purpose", and what they are both distinguished *from* is a dropped link, which
    /// produces EOF and nothing at all. Getting it wrong means reconnecting with `new-session -A`
    /// after a deliberate close and recreating the session the user just ended — which is what made
    /// Ctrl-D look like it opened a new shell.
    ///
    /// This was written the other way round first, expecting `%window-close` from killing the only
    /// window. The fixtures said otherwise on all five versions: a session with no windows is
    /// destroyed, so the client is ended rather than told about a window.
    func testEndingTheSessionAnnouncesItselfOnEveryVersion() throws {
        for version in Self.versions {
            let stream = try events(version, "kill-session")
            guard case .exit = stream.last else {
                return XCTFail("tmux \(version): expected a trailing %exit, got \(String(describing: stream.last))")
            }
            XCTAssertTrue(
                stream.contains { if case .sessionsChanged = $0 { return true } else { return false } },
                "tmux \(version): no %sessions-changed before the %exit"
            )
        }
    }

    /// Nothing in any fixture parses as an event the codec cannot name.
    ///
    /// Unknown `%` notifications are logged and ignored rather than being fatal — tmux adds them
    /// between versions — but a notification that *all five* of these versions send and this codec
    /// does not understand is a gap worth failing on rather than shrugging at.
    func testNoScenarioProducesUnparsedProtocolLines() throws {
        for version in Self.versions {
            for scenario in Self.scenarios {
                for event in try events(version, scenario) {
                    if case .unknownNotification(let line) = event {
                        XCTFail("tmux \(version), \(scenario): unhandled notification — \(line)")
                    }
                }
            }
        }
    }

    static let scenarios = [
        "attach", "split", "zoom", "resize", "rename", "copy-mode",
        "kill", "kill-session", "detach", "output",
    ]
}
