import AppKit
import SwiftTerm
import XCTest
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
