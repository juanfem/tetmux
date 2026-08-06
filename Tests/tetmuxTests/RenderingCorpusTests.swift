import AppKit
import SwiftTerm
import XCTest
@testable import tetmuxCore
@testable import tetmuxUI

/// T5.7 — the grid the emulator builds from real Unicode, which under control mode is a geometry
/// question rather than an appearance one.
///
/// This is why it is worth testing something SwiftTerm implements. tetmux asks tmux for
/// `frame.width / cellWidth` columns and then lays panes out on the answer, so the emulator and tmux
/// have to agree about *how many cells a string occupies*. A width bug does not smudge a glyph: it
/// puts the two of them one column apart, and from there every line wraps in the wrong place and the
/// grid stays wrong until something resizes it. The only Unicode assertion in the tree before this
/// was byte delivery through the paste path, which says nothing about width.
///
/// Asserted at the emulator boundary and on the **grid**, never on pixels. Cursor column after a
/// string, and what landed in which cell. A screenshot comparison would be a test of the font
/// installed on the machine.
///
/// The corpus is real bytes in files rather than string literals in this source, for the reason the
/// protocol fixtures are: a literal is what someone believed the bytes were, and normalisation,
/// editors and copy-paste all quietly rewrite this particular kind of text.
@MainActor
final class RenderingCorpusTests: XCTestCase {

    private func corpus(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Corpus"),
            "the corpus file \(name).txt is not in the bundle"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func terminal(cols: Int = 40, rows: Int = 5) -> Terminal {
        Terminal(delegate: NullDelegate(), options: TerminalOptions(cols: cols, rows: rows))
    }

    /// A double-width character occupies two cells, and the second one is a continuation.
    ///
    /// This is the property tmux and the emulator have to share. tmux does its own width accounting
    /// with utf8proc — the matrix build passes `--enable-utf8proc` precisely so its answers match a
    /// real installation — and if the two disagree by one cell per CJK character, a line of Japanese
    /// wraps in a different place on each side.
    func testCjkTextTakesTwoCellsPerCharacter() throws {
        let text = try corpus("cjk")
        let terminal = terminal()
        terminal.feed(text: text)

        // Seven characters, fourteen columns.
        XCTAssertEqual(text.count, 7, "the corpus file changed; the expectation below is about its length")
        XCTAssertEqual(
            terminal.buffer.x, 14,
            "the cursor is not where fourteen columns of CJK would leave it — tmux and the emulator "
                + "would disagree about where this line wraps"
        )

        let line = try XCTUnwrap(terminal.getLine(row: 0))
        XCTAssertEqual(line[0].width, 2, "the first character did not claim two cells")
        // The cell after a wide character is its continuation: empty, and not a character of its own.
        XCTAssertEqual(line[1].getCharacter(), "\0", "the continuation cell holds a character of its own")
    }

    /// Combining marks attach to the character before them rather than taking a cell.
    ///
    /// `é` written as `e` + U+0301 is two scalars and one column. Counted as two, a full-width line
    /// of accented text would wrap a column early for every accent on it.
    func testCombiningMarksDoNotTakeTheirOwnCell() throws {
        let text = try corpus("combining")
        let terminal = terminal()
        terminal.feed(text: text)

        XCTAssertEqual(
            terminal.buffer.x, text.count,
            "accented characters did not occupy one cell each: \(text.unicodeScalars.count) scalars, "
                + "\(text.count) graphemes, cursor at \(terminal.buffer.x)"
        )
    }

    /// An emoji ZWJ sequence is one grapheme and — importantly — is not counted per scalar.
    ///
    /// A family emoji is five scalars joined by zero-width joiners. Counted scalar by scalar it
    /// would claim ten columns for something drawn in two, which is the most dramatic version of the
    /// disagreement this whole test exists for.
    func testAZwjSequenceIsNotCountedPerScalar() throws {
        let text = try corpus("emoji-zwj")
        let terminal = terminal(cols: 80)
        terminal.feed(text: text)

        XCTAssertGreaterThan(text.unicodeScalars.count, text.count, "the corpus is not actually joined")
        XCTAssertLessThanOrEqual(
            terminal.buffer.x, text.unicodeScalars.count,
            "the emulator charged a cell per scalar — a joined emoji would claim ten columns"
        )
        XCTAssertGreaterThan(terminal.buffer.x, 0, "nothing was written at all")
    }

    /// Box drawing is single width, which is what makes `tree`, `htop` and every TUI frame line up.
    ///
    /// The failure mode is specific and familiar: treat these as ambiguous-width and every box on
    /// screen gains a column per character, so the right-hand edge marches off the pane.
    func testBoxDrawingIsSingleWidth() throws {
        let text = try corpus("box-drawing")
        let terminal = terminal()
        terminal.feed(text: text)

        XCTAssertEqual(
            terminal.buffer.x, text.count,
            "box-drawing characters are not one cell each; every TUI frame would be wider than it draws"
        )
        let line = try XCTUnwrap(terminal.getLine(row: 0))
        for column in 0..<text.count {
            XCTAssertEqual(line[column].width, 1, "column \(column) is not single width")
        }
    }

    /// The ambiguous-width block, pinned as *whatever the emulator currently does* — because the one
    /// thing that must not happen is for it to change silently.
    ///
    /// These characters (arrows, §, ¶, ±) are the ones East Asian Width calls ambiguous, and there is
    /// no right answer: it depends on a locale setting neither side here has. What matters is that
    /// tmux and the emulator make the *same* choice, so this records the choice. If a SwiftTerm bump
    /// moves it, this test is the notification — and the fix is a conversation about tmux's own
    /// setting, not a number changed here to match.
    func testAmbiguousWidthCharactersKeepTheWidthTheyHaveToday() throws {
        let text = try corpus("ambiguous-width")
        let terminal = terminal()
        terminal.feed(text: text)

        XCTAssertEqual(
            terminal.buffer.x, text.count,
            "the emulator changed its mind about ambiguous-width characters. This is not necessarily "
                + "a bug, but tmux has to agree with it — check tmux's own width handling before "
                + "changing this number"
        )
    }

    /// Wrapping is where a width disagreement actually shows up, so it gets its own case.
    ///
    /// A grid exactly wide enough for four CJK characters takes four and puts the fifth on the next
    /// row. Off by one cell, the fifth would be split across the boundary or land a column early —
    /// which is what "the output looks shifted" means when someone reports it.
    func testWideCharactersWrapOnTheCellBoundary() throws {
        let terminal = terminal(cols: 8, rows: 4)
        terminal.feed(text: "日本語表現")

        XCTAssertEqual(terminal.buffer.y, 1, "five wide characters did not spill onto a second row")
        XCTAssertEqual(terminal.buffer.x, 2, "the fifth character is not at the start of the new row")

        let first = try XCTUnwrap(terminal.getLine(row: 0))
        XCTAssertEqual(first[6].width, 2, "the fourth character did not fit in a grid sized for it")
    }
}

/// §8's rendering acceptance, the program-level half: `vim`, `less`, a program that redraws on a
/// timer, and a Powerline prompt, each replayed into the emulator and checked against a reference
/// terminal's grid.
///
/// **The reference terminal is tmux**, and that is the point rather than a convenience. tetmux asks
/// tmux for a column count derived from the font, and then renders the layout tmux computes from
/// that answer — so the property the app depends on is not "SwiftTerm is a correct terminal" in the
/// abstract, it is that *these two emulators build the same grid from the same bytes*. A grid they
/// agree on is a pane that lines up; a grid they do not is a pane that wraps in a different place
/// from the one tmux thinks it wrapped in, and no amount of correctness against a third emulator
/// would say anything about that.
///
/// Both sides of each case come out of one recorded run of one pane (`Scripts/capture-programs.py`):
/// the `.stream` is the `%output` payload, unescaped — byte for byte what `SessionService` hands a
/// pane surface — and the `.grid` is `capture-pane -p` on that same pane with its process stopped,
/// so the reference cannot be a frame ahead of the bytes. Recorded once and committed, never
/// regenerated: a fixture rebuilt on every run asserts that the emulator agrees with whatever just
/// happened, which is true by construction.
///
/// Asserted on characters, not attributes. Colour has its own tests (`TrueColorTests`) and
/// `capture-pane` without `-e` says nothing about it; what these cases are for is cell *occupancy*,
/// which is where a disagreement costs the user their layout.
@MainActor
final class ProgramRenderingTests: XCTestCase {

    /// Replays a recorded stream and returns the emulator's grid, one string per row, trailing
    /// blanks trimmed the way `capture-pane` trims them.
    private func render(_ name: String, columns: Int = 80, rows: Int = 24) throws -> [String] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "stream", subdirectory: "Corpus/Programs"),
            "the recorded stream \(name).stream is not in the bundle"
        )
        let terminal = Terminal(
            delegate: NullDelegate(), options: TerminalOptions(cols: columns, rows: rows)
        )
        terminal.feed(byteArray: Array(try Data(contentsOf: url)))

        var grid: [String] = []
        for row in 0..<rows {
            guard let line = terminal.getLine(row: row) else { break }
            var text = ""
            for column in 0..<columns {
                let cell = line[column]
                // Two different cells hold `\0` and they must not be treated alike. The cell after a
                // wide character is its continuation — width 0, and tmux's capture has one glyph
                // for the pair, so it contributes nothing here. A cell nothing has been written to
                // is width 1 and is a *space*: dropping those instead collapses every run of
                // untouched cells, which showed up as `top`'s header losing the gap between its
                // columns while every other row matched.
                if cell.width == 0 { continue }
                let character = cell.getCharacter()
                text.append(character == "\0" ? " " : character)
            }
            grid.append(String(text.reversed().drop(while: { $0 == " " }).reversed()))
        }
        return grid
    }

    /// The reference grid, with the provenance header stripped.
    private func reference(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "grid", subdirectory: "Corpus/Programs"),
            "the reference grid \(name).grid is not in the bundle"
        )
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        var body = Array(lines.drop(while: { $0.hasPrefix("#") }))
        while let last = body.last, last.isEmpty { body.removeLast() }
        XCTAssertFalse(body.isEmpty, "\(name).grid has a header and no grid")
        return body
    }

    /// Replays one case and compares row by row, reporting the first row that differs rather than
    /// a whole screen — a 24-row diff in an assertion message is unreadable, and the first
    /// divergence is where the two emulators actually parted company.
    private func assertAgreesWithReference(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try reference(name)
        let actual = try render(name)
        XCTAssertGreaterThanOrEqual(
            actual.count, expected.count,
            "the emulator produced fewer rows than tmux rendered", file: file, line: line
        )
        for (index, row) in expected.enumerated() {
            let mine = index < actual.count ? actual[index] : ""
            XCTAssertEqual(
                mine, row,
                "row \(index) of \(name) differs from what tmux rendered from the same bytes\n"
                    + "  tmux: \(row.debugDescription)\n"
                    + "  here: \(mine.debugDescription)",
                file: file, line: line
            )
            if mine != row { return }
        }
    }

    /// An editor on the alternate screen: `smcup`, absolute cursor addressing, a status line, and a
    /// left margin drawn under text that was already there (`:set number`), which is a redraw rather
    /// than a repaint and is where a cursor-addressing bug shows up as text in the wrong column.
    func testVimRendersTheSameGridAsTmux() throws {
        try assertAgreesWithReference("vim")
    }

    /// A pager: a full screen of text, a reverse-video prompt, and `G`, which repaints the screen
    /// from the end of the file rather than scrolling to it.
    func testLessRendersTheSameGridAsTmux() throws {
        try assertAgreesWithReference("less")
    }

    /// §8's own example: meter bars built from `|` runs, a sorted process table, a reverse-video
    /// header and a function-key footer, all repainted on a timer. Recorded against pid 1 alone, so
    /// the fixture is a record of `htop` and not of one desktop's process list.
    func testHtopRendersTheSameGridAsTmux() throws {
        try assertAgreesWithReference("htop")
    }

    /// The same shape of program from the other implementation, and the one that is on every Mac —
    /// so the timed-repaint case is still covered on a machine where `htop` was never installed.
    func testATimedRepaintRendersTheSameGridAsTmux() throws {
        try assertAgreesWithReference("top")
    }

    /// A Powerline prompt, which is on §8's list for one specific reason: its separator is U+E0B0,
    /// in the Private Use Area, where there is no width anybody can look up. If tmux and the
    /// emulator make different guesses, every segment after the first is a column out — and the
    /// prompt is the one line on screen that is redrawn after everything else, so it smears.
    func testAPowerlinePromptRendersTheSameGridAsTmux() throws {
        try assertAgreesWithReference("powerline")
    }
}

/// T5.2 — 24-bit colour, asserted on the two paths a pane's bytes actually arrive by.
///
/// Truecolor is supposed to work by architecture rather than by feature: `%output` carries the
/// pane's own bytes and SwiftTerm renders 24-bit SGR, so nobody wrote any code for it and nothing
/// mentions it. That is exactly why it needs an assertion — §5 promises "exact, testable
/// commitments", and a requirement met by accident is one a later change can break without
/// anything saying so. Two things could break it and neither would look like a colour bug.
/// `ControlCodec.unescapeOctal` is what turns tmux's `\033` back into an ESC byte, so a regression
/// there deletes the introducer and leaves `[38;2;…m` printed as text; and `capture-pane -e`'s
/// answer travels as *result lines*, not as `%output`, which is a different route through the codec
/// with its own claim about raw bytes (`commandResultLine.bytes` beside the lossy `line`).
///
/// Asserted on the cell's `Attribute.Color`, which distinguishes `.trueColor` from `.ansi256`: a
/// build that downsampled 24-bit colour to the 256-colour palette would still show something
/// plausible on screen and would fail here.
@MainActor
final class TrueColorTests: XCTestCase {

    /// A colour deliberately off the xterm-256 palette, so a downsample cannot land on it by luck.
    private static let fg = (r: UInt8(17), g: UInt8(183), b: UInt8(201))
    private static let bg = (r: UInt8(43), g: UInt8(7), b: UInt8(99))

    private func terminal() -> Terminal {
        Terminal(delegate: NullDelegate(), options: TerminalOptions(cols: 40, rows: 5))
    }

    /// Replays `data` and returns the attribute of the cell at column 0 of row 0.
    private func attributeOfFirstCell(after data: Data) throws -> Attribute {
        let terminal = terminal()
        terminal.feed(byteArray: Array(data))
        let line = try XCTUnwrap(terminal.getLine(row: 0))
        return line[0].attribute
    }

    /// The ordinary path: a pane writes 24-bit SGR, tmux octal-escapes it into `%output`, and the
    /// cell that comes out the other end holds the same three components it started with.
    ///
    /// The escaping is the interesting half. tmux writes the introducer as `\033`, so the codec's
    /// unescaping is what decides whether the emulator sees an escape sequence or four printable
    /// characters — and the failure is silent, because the text still arrives.
    func testTrueColorSurvivesTheWireIntoTheCell() throws {
        let fg = Self.fg
        let bg = Self.bg
        let payload = #"\033[38;2;\#(fg.r);\#(fg.g);\#(fg.b);48;2;\#(bg.r);\#(bg.g);\#(bg.b)mX\033[0m"#

        var codec = ControlCodec()
        let events = codec.feed(Array(("%output %7 " + payload + "\r\n").utf8))

        guard case .output(let paneId, let data)? = events.first else {
            return XCTFail("the line did not parse as pane output: \(events)")
        }
        XCTAssertEqual(paneId, "%7")
        XCTAssertEqual(
            data.first, 0x1b,
            "the octal-escaped introducer did not come back as an ESC byte — the sequence would be "
                + "printed as text rather than setting a colour"
        )

        let attribute = try attributeOfFirstCell(after: data)
        XCTAssertEqual(
            attribute.fg, .trueColor(red: fg.r, green: fg.g, blue: fg.b),
            "the foreground is not the 24-bit colour that was sent; .ansi256 here means it was "
                + "downsampled to the palette"
        )
        XCTAssertEqual(attribute.bg, .trueColor(red: bg.r, green: bg.g, blue: bg.b))
    }

    /// The repaint path (F4.16), which is how every pane gets its contents on reattach and how a
    /// second window is filled — and which is *not* `%output`.
    ///
    /// `capture-pane -p -e -J` replays the screen as the result lines of a command block, and those
    /// bodies are not escaped at all: the ESC bytes are raw on the wire. That is why
    /// `commandResultLine` carries `bytes` beside its lossy `line`, and this is the assertion that
    /// the raw half is what reaches the emulator. Decoded through the `String`, a colour would
    /// survive and other things would not, so the cheap version of this test would pass while the
    /// property it is about had gone.
    func testTrueColorSurvivesACapturePaneRepaint() throws {
        let fg = Self.fg
        // Raw ESC, exactly as `capture-pane -e` puts it in a response body.
        let captured = "\u{1b}[38;2;\(fg.r);\(fg.g);\(fg.b)mX\u{1b}[0m"

        var codec = ControlCodec()
        let events = codec.feed(Array("%begin 1 42 1\r\n\(captured)\r\n%end 1 42 1\r\n".utf8))

        let body = events.compactMap { event -> Data? in
            if case .commandResultLine(_, _, let bytes) = event { return bytes }
            return nil
        }
        XCTAssertEqual(body.count, 1, "the captured line did not arrive as one result line: \(events)")
        let data = try XCTUnwrap(body.first)
        XCTAssertEqual(data.first, 0x1b, "the raw introducer was lost between the wire and the block body")

        let attribute = try attributeOfFirstCell(after: data)
        XCTAssertEqual(
            attribute.fg, .trueColor(red: fg.r, green: fg.g, blue: fg.b),
            "a reattached pane would repaint its scrollback in the wrong colours"
        )
    }

    /// The negative half, so the assertions above are known to be able to fail.
    ///
    /// `ESC[38;5;N m` is the 256-colour form and must arrive as `.ansi256`. Without this, a build
    /// that reported every colour as `.trueColor` — the mirror image of downsampling — would pass
    /// both tests above and be just as wrong.
    func testPaletteColoursAreStillPaletteColours() throws {
        let data = Data(Array("\u{1b}[38;5;208mX\u{1b}[0m".utf8))
        let attribute = try attributeOfFirstCell(after: data)
        XCTAssertEqual(attribute.fg, .ansi256(code: 208))
    }
}

private final class NullDelegate: TerminalDelegate, @unchecked Sendable {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
    func showCursor(source: Terminal) {}
    func hideCursor(source: Terminal) {}
    func setTerminalTitle(source: Terminal, title: String) {}
    func setTerminalIconTitle(source: Terminal, title: String) {}
    func sizeChanged(source: Terminal) {}
    func scrolled(source: Terminal, yDisp: Int) {}
    func linefeed(source: Terminal) {}
    func bufferActivated(source: Terminal) {}
    func bell(source: Terminal) {}
    func isProcessTrusted(source: Terminal) -> Bool { false }
    func mouseModeChanged(source: Terminal) {}
    func hostCurrentDirectoryUpdated(source: Terminal, directory: String?) {}
    func hostCurrentDocumentUpdated(source: Terminal, document: String?) {}
    func colorChanged(source: Terminal, idx: Int?) {}
    func setBackgroundColor(source: Terminal, color: Color) {}
    func setForegroundColor(source: Terminal, color: Color) {}
    func setCursorColor(source: Terminal, color: Color?) {}
    func getColors(source: Terminal) -> (foreground: Color, background: Color) {
        (Color(red: 0xffff, green: 0xffff, blue: 0xffff), Color(red: 0, green: 0, blue: 0))
    }
    func setCursorStyle(source: Terminal, style: CursorStyle) {}
    func selectionChanged(source: Terminal) {}
    func clipboardCopy(source: Terminal, content: Data) {}
    func notify(source: Terminal, title: String, body: String) {}
    func iTermContent(source: Terminal, content: ArraySlice<UInt8>) {}
    func createImage(source: Terminal, bytes: inout [UInt8], width: ImageSizeRequest, height: ImageSizeRequest, preserveAspectRatio: Bool) {}
    func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {}
}
