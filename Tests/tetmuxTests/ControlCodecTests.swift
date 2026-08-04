import XCTest
@testable import tetmuxCore

/// R3.6 — developed against recorded fixtures, not by manual testing. The byte strings below are
/// verbatim captures from tmux 3.7b over a real control-mode channel.
final class ControlCodecTests: XCTestCase {

    // MARK: - Octal payloads (R3.4)

    func testUnescapeOctalLeavesPlainBytesAlone() {
        let plain = Array("hello world".utf8)
        XCTAssertEqual(ControlCodec.unescapeOctal(plain), plain)
    }

    func testUnescapeOctalDecodesControlBytes() {
        XCTAssertEqual(
            ControlCodec.unescapeOctal(Array(#"line1\012line2"#.utf8)),
            Array("line1\nline2".utf8)
        )
        // ESC, the single most common byte in real output.
        XCTAssertEqual(ControlCodec.unescapeOctal(Array(#"\033[1m"#.utf8)), [0x1b, 0x5b, 0x31, 0x6d])
    }

    func testUnescapeOctalHandlesNulAndHighBytes() {
        XCTAssertEqual(ControlCodec.unescapeOctal(Array(#"a\000b"#.utf8)), [0x61, 0x00, 0x62])
        XCTAssertEqual(ControlCodec.unescapeOctal(Array(#"\377"#.utf8)), [0xff])
    }

    func testUnescapeOctalHandlesLiteralBackslash() {
        XCTAssertEqual(ControlCodec.unescapeOctal(Array(#"path\\dir"#.utf8)), Array(#"path\dir"#.utf8))
        // A backslash with too few digits after it is data, not an escape.
        XCTAssertEqual(ControlCodec.unescapeOctal(Array(#"end\01"#.utf8)), Array(#"end\01"#.utf8))
        XCTAssertEqual(ControlCodec.unescapeOctal(Array(#"\9"#.utf8)), Array(#"\9"#.utf8))
    }

    // MARK: - Block framing (R3.2)

    func testCommandBlockFraming() {
        var codec = ControlCodec()
        let events = codec.feed(Array("%begin 1785760385 13768 1\r\n@13|zsh|layout\r\n%end 1785760385 13768 1\r\n".utf8))

        XCTAssertEqual(events.count, 3)
        guard case .begin(let ts, let number, let flags) = events[0] else { return XCTFail("expected .begin") }
        XCTAssertEqual(ts, 1_785_760_385)
        XCTAssertEqual(number, 13768)
        XCTAssertEqual(flags, "1")

        guard case .commandResultLine(let resultNumber, let line, let bytes) = events[1] else {
            return XCTFail("expected .commandResultLine")
        }
        XCTAssertEqual(resultNumber, 13768)
        XCTAssertEqual(line, "@13|zsh|layout")
        XCTAssertEqual(bytes, Data("@13|zsh|layout".utf8))

        guard case .end(_, let endNumber, _) = events[2] else { return XCTFail("expected .end") }
        XCTAssertEqual(endNumber, 13768)
    }

    func testErrorBlockIsReportedAndClosesTheBlock() {
        var codec = ControlCodec()
        let events = codec.feed(Array("%begin 1 7 1\r\ncan't find pane: %0\r\n%error 1 7 1\r\nnoise\r\n".utf8))
        XCTAssertEqual(events.count, 3, "the line after %error is outside any block and is dropped")
        guard case .error(_, let number, _) = events[2] else { return XCTFail("expected .error") }
        XCTAssertEqual(number, 7)
    }

    /// Framing outranks dispatch: inside a block, a line starting with `%` is content.
    ///
    /// `capture-pane -p -e -J` replays scrollback as result lines, so this is not a contrived input —
    /// tcsh and zsh's classic prompt is `%`, and every such line used to be parsed as an unknown
    /// notification and dropped from the repaint.
    func testResultLinesStartingWithPercentAreContentNotNotifications() {
        var codec = ControlCodec()
        let events = codec.feed(Array(
            "%begin 1 4237 1\r\n%148 80x24 padpadpadpadpad\r\n%9 136x55 padpadpadpadpad\r\n%end 1 4237 1\r\n".utf8
        ))

        XCTAssertEqual(events.count, 4)
        guard case .commandResultLine(_, let first, _) = events[1] else {
            return XCTFail("expected .commandResultLine, got \(events[1])")
        }
        guard case .commandResultLine(_, let second, _) = events[2] else {
            return XCTFail("expected .commandResultLine, got \(events[2])")
        }
        XCTAssertEqual(first, "%148 80x24 padpadpadpadpad")
        XCTAssertEqual(second, "%9 136x55 padpadpadpadpad")
    }

    /// The severe half of the same bug. A scrollback holding a line like `%exit` used to be parsed as
    /// the server announcing the session had ended — which sets `serverEnded`, so the next close was
    /// treated as deliberate and no reconnect was attempted. Captured `%output` could likewise inject
    /// bytes into a pane nobody wrote to.
    func testCapturedContentCannotForgeNotifications() {
        var codec = ControlCodec()
        let events = codec.feed(Array(
            "%begin 1 20 1\r\n%exit\r\n%output %3 forged\r\n%session-changed $9 evil\r\n%end 1 20 1\r\n".utf8
        ))

        XCTAssertEqual(events.count, 5)
        for event in events[1...3] {
            guard case .commandResultLine = event else {
                return XCTFail("captured content parsed as protocol: \(event)")
            }
        }
        guard case .end = events[4] else { return XCTFail("expected .end") }
    }

    /// Only the matching number closes the block. A terminator for some other command is text that
    /// happens to look like framing — which is exactly what a captured tmux transcript contains.
    func testTerminatorWithAnotherCommandNumberDoesNotCloseTheBlock() {
        var codec = ControlCodec()
        let events = codec.feed(Array(
            "%begin 1 100 1\r\n%end 1 99 1\r\nstill inside\r\n%end 1 100 1\r\n".utf8
        ))

        XCTAssertEqual(events.count, 4)
        guard case .commandResultLine(_, let impostor, _) = events[1] else {
            return XCTFail("expected the mismatched terminator to be content, got \(events[1])")
        }
        XCTAssertEqual(impostor, "%end 1 99 1")
        guard case .commandResultLine(_, let after, _) = events[2] else {
            return XCTFail("expected .commandResultLine, got \(events[2])")
        }
        XCTAssertEqual(after, "still inside")
        guard case .end(_, let number, _) = events[3] else { return XCTFail("expected .end") }
        XCTAssertEqual(number, 100)
    }

    /// Notifications outside a block still dispatch — the fix must not cost the ordinary path.
    func testNotificationsOutsideABlockAreStillParsed() {
        var codec = ControlCodec()
        let events = codec.feed(Array(
            "%begin 1 5 1\r\n%end 1 5 1\r\n%output %3 hi\r\n%exit\r\n".utf8
        ))
        XCTAssertEqual(events.count, 4)
        guard case .output(let paneId, let data) = events[2] else { return XCTFail("expected .output") }
        XCTAssertEqual(paneId, "%3")
        XCTAssertEqual(data, Data("hi".utf8))
        guard case .exit = events[3] else { return XCTFail("expected .exit") }
    }

    /// tmux command numbers are server-wide and start wherever the server happens to be — never
    /// at zero. Anything that predicts them is wrong.
    func testCommandNumbersAreTakenFromTheStreamNotAssumed() {
        var codec = ControlCodec()
        let events = codec.feed(Array("%begin 1785760704 13776 0\r\n%end 1785760704 13776 0\r\n".utf8))
        guard case .begin(_, let number, _) = events[0] else { return XCTFail("expected .begin") }
        XCTAssertEqual(number, 13776)
    }

    // MARK: - Attach preamble

    func testDcsPreambleBeforeFirstBeginIsSkipped() {
        var codec = ControlCodec()
        // The literal first bytes of every `tmux -CC` session.
        let events = codec.feed(Array("\u{1b}P1000p%begin 1785760384 13759 0\r\n".utf8))
        XCTAssertEqual(events.count, 1)
        guard case .begin(_, let number, _) = events[0] else { return XCTFail("expected .begin") }
        XCTAssertEqual(number, 13759)
    }

    func testShellNoiseBeforeTheProtocolIsIgnored() {
        var codec = ControlCodec()
        let events = codec.feed(Array("Last login: Mon Aug  3\r\nsome banner text\r\n\u{1b}P1000p%begin 1 2 0\r\n".utf8))
        XCTAssertEqual(events.count, 1, "banner lines must not become events")
    }

    // MARK: - Notifications (R3.3)

    /// The regression that stopped every pane from rendering: tmux ≥ 2.5 sends
    /// `%layout-change @w <layout> <visible-layout> <flags>`. Folding all three into the layout
    /// string makes it unparseable, so the window ends up with no pane tree and nothing to draw.
    func testLayoutChangeSeparatesItsThreeFields() {
        var codec = ControlCodec()
        let line = "%layout-change @14 bb11,80x24,0,0{40x24,0,0,20,39x24,41,0,21} "
            + "bb11,80x24,0,0{40x24,0,0,20,39x24,41,0,21} *\r\n"
        let events = codec.feed(Array(line.utf8))

        guard case .layoutChange(let windowId, let layout, let visible, let flags) = events[0] else {
            return XCTFail("expected .layoutChange")
        }
        XCTAssertEqual(windowId, "@14")
        XCTAssertEqual(layout, "bb11,80x24,0,0{40x24,0,0,20,39x24,41,0,21}")
        XCTAssertEqual(visible, "bb11,80x24,0,0{40x24,0,0,20,39x24,41,0,21}")
        XCTAssertEqual(flags, "*")
        XCTAssertNoThrow(try LayoutParser.parse(layout), "the captured layout must actually parse")
    }

    func testLayoutChangeWithOnlyTwoFieldsStillParses() {
        var codec = ControlCodec()
        let events = codec.feed(Array("%layout-change @1 bc62,80x24,0,0,1\r\n".utf8))
        guard case .layoutChange(let windowId, let layout, let visible, _) = events[0] else {
            return XCTFail("expected .layoutChange")
        }
        XCTAssertEqual(windowId, "@1")
        XCTAssertEqual(layout, "bc62,80x24,0,0,1")
        XCTAssertNil(visible)
    }

    func testIdentifiersKeepTheirSigils() {
        var codec = ControlCodec()
        let events = codec.feed(Array("""
        %window-add @13\r
        %session-changed $7 captest\r
        %window-pane-changed @14 %21\r
        %window-close @13\r

        """.utf8))

        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0], .windowAdd(windowId: "@13"))
        XCTAssertEqual(events[1], .sessionChanged(sessionId: "$7", name: "captest"))
        XCTAssertEqual(events[2], .windowPaneChanged(windowId: "@14", paneId: "%21"))
        XCTAssertEqual(events[3], .windowClose(windowId: "@13"))
    }

    func testNamesContainingSpacesSurviveIntact() {
        var codec = ControlCodec()
        let events = codec.feed(Array("%window-renamed @3 my long window name\r\n".utf8))
        XCTAssertEqual(events[0], .windowRenamed(windowId: "@3", name: "my long window name"))
    }

    func testSessionRenamedAcceptsBothOldAndNewForms() {
        var codec = ControlCodec()
        XCTAssertEqual(
            codec.feed(Array("%session-renamed $4 build\r\n".utf8))[0],
            .sessionRenamed(sessionId: "$4", name: "build")
        )
        XCTAssertEqual(
            codec.feed(Array("%session-renamed build\r\n".utf8))[0],
            .sessionRenamed(sessionId: nil, name: "build")
        )
    }

    func testOutputPayloadIsDecodedToRawBytes() {
        var codec = ControlCodec()
        let events = codec.feed(Array((#"%output %19 \033[1mbold\033[0m\015"# + "\r\n").utf8))
        guard case .output(let paneId, let data) = events[0] else { return XCTFail("expected .output") }
        XCTAssertEqual(paneId, "%19")
        XCTAssertEqual(data, Data([0x1b, 0x5b, 0x31, 0x6d] + Array("bold".utf8) + [0x1b, 0x5b, 0x30, 0x6d, 0x0d]))
    }

    /// tmux writes `%extended-output %p <age> : <data>`; the colon is a reserved field, and letting
    /// it through puts ": " at the head of every chunk of terminal output.
    func testExtendedOutputSkipsTheReservedColonField() {
        var codec = ControlCodec()
        let events = codec.feed(Array((#"%extended-output %5 120 : hello"# + "\r\n").utf8))
        guard case .extendedOutput(let paneId, let age, let data) = events[0] else {
            return XCTFail("expected .extendedOutput")
        }
        XCTAssertEqual(paneId, "%5")
        XCTAssertEqual(age, 120)
        XCTAssertEqual(data, Data("hello".utf8))
    }

    func testUnknownNotificationsAreNonFatal() {
        var codec = ControlCodec()
        let events = codec.feed(Array("%some-future-notification a b c\r\n%window-add @1\r\n".utf8))
        XCTAssertEqual(events.count, 2)
        guard case .unknownNotification = events[0] else { return XCTFail("expected .unknownNotification") }
        XCTAssertEqual(events[1], .windowAdd(windowId: "@1"))
    }

    func testExitCarriesItsReason() {
        var codec = ControlCodec()
        XCTAssertEqual(codec.feed(Array("%exit server exited\r\n".utf8))[0], .exit(reason: "server exited"))
        XCTAssertEqual(codec.feed(Array("%exit\r\n".utf8))[0], .exit(reason: nil))
    }

    // MARK: - Chunking

    /// The transport hands over whatever a read returned; a notification split across two reads
    /// must produce exactly one event, once.
    func testEventsSplitAcrossReadsAreReassembled() {
        var codec = ControlCodec()
        XCTAssertTrue(codec.feed(Array("%window-ren".utf8)).isEmpty)
        XCTAssertTrue(codec.feed(Array("amed @2 edi".utf8)).isEmpty)
        let events = codec.feed(Array("tor\r\n".utf8))
        XCTAssertEqual(events, [.windowRenamed(windowId: "@2", name: "editor")])
    }

    func testFeedingOneByteAtATimeProducesTheSameEvents() {
        let stream = Array(Self.recordedAttach.utf8)
        var whole = ControlCodec()
        let expected = whole.feed(stream)

        var drip = ControlCodec()
        var actual: [ControlEvent] = []
        for byte in stream {
            actual.append(contentsOf: drip.feed([byte]))
        }
        XCTAssertEqual(actual, expected)
        XCTAssertFalse(expected.isEmpty)
    }

    // MARK: - Fixture replay

    /// A complete recorded attach: DCS preamble, handshake block, window and session
    /// notifications, real pane output, a command response, and an error block.
    static let recordedAttach = """
        \u{1b}P1000p%begin 1785760704 13776 0\r
        %end 1785760704 13776 0\r
        %window-add @14\r
        %sessions-changed\r
        %session-changed $8 captest2\r
        %window-renamed @14 tmux\r
        %output %20 \\033[1m\\033[7m%\\033[27m\\033[1m\\033[0m \\015 \\015\r
        %begin 1785760705 13784 1\r
        3.7b\r
        %end 1785760705 13784 1\r
        %window-pane-changed @14 %21\r
        %layout-change @14 bb11,80x24,0,0{40x24,0,0,20,39x24,41,0,21} bb11,80x24,0,0{40x24,0,0,20,39x24,41,0,21} *\r
        %begin 1785760707 13791 1\r
        can't find pane: %0\r
        %error 1785760707 13791 1\r

        """

    func testRecordedAttachReplaysToTheExpectedEventShape() {
        var codec = ControlCodec()
        let events = codec.feed(Array(Self.recordedAttach.utf8))

        XCTAssertEqual(events.count, 15)
        XCTAssertEqual(events[2], .windowAdd(windowId: "@14"))
        XCTAssertEqual(events[3], .sessionsChanged)
        XCTAssertEqual(events[4], .sessionChanged(sessionId: "$8", name: "captest2"))

        guard case .output(let paneId, _) = events[6] else { return XCTFail("expected .output") }
        XCTAssertEqual(paneId, "%20")

        guard case .commandResultLine(_, let version, _) = events[8] else {
            return XCTFail("expected the version response line")
        }
        XCTAssertEqual(version, "3.7b")

        XCTAssertEqual(events[10], .windowPaneChanged(windowId: "@14", paneId: "%21"))
        guard case .layoutChange(_, let layout, _, _) = events[11] else {
            return XCTFail("expected .layoutChange")
        }
        let tree = try? LayoutParser.parse(layout)
        XCTAssertEqual(tree?.paneIds, ["%20", "%21"])

        guard case .error = events[14] else { return XCTFail("expected .error") }
    }
}
