import AppKit
import SwiftTerm
import XCTest
@testable import tetmuxUI

/// F4.23 and F4.24 — mouse reporting and input-method composition, which tetmux does not implement.
///
/// Both are delegated wholesale to SwiftTerm, which is exactly the position the plain-text URL
/// matcher was in before a test went under it: already true, believed rather than known, and free to
/// stop being true on a dependency bump with nothing in the application to notice. So these are
/// contracts with the dependency rather than tests of our own logic, and they assert at the seam
/// tetmux actually depends on: `TerminalViewDelegate.send`, which is the one place bytes leave the
/// emulator for the channel.
///
/// The keystroke path is what makes F4.24 the likelier silent break. Keys reach a pane through an
/// `NSEvent` monitor that runs ahead of menu dispatch and a per-frame coalescing buffer, neither of
/// which was written with composition in mind — and a break there does not look like a bug, it looks
/// like the user's own input method behaving oddly.
@MainActor
final class PaneInputTests: XCTestCase {

    /// A terminal view with somewhere for its bytes to go.
    ///
    /// Sized and given a real grid, because both behaviours under test depend on one: mouse
    /// reporting encodes a cell coordinate, and there is nothing to compose into a terminal with no
    /// columns.
    private func makeView() -> (PaneTerminalView, RecordingDelegate) {
        let recorder = RecordingDelegate()
        let view = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400),
            font: TerminalTheme.default.resolvedFont()
        )
        view.terminalDelegate = recorder
        view.allowMouseReporting = true
        return (view, recorder)
    }

    // MARK: - F4.23, mouse modes

    /// A program that turns mouse reporting on is *heard*, and the emulator says so.
    ///
    /// This is the whole of F4.23 from tetmux's side. `allowMouseReporting` is ours — set once when
    /// the pane is made — and everything after it is the emulator's: parsing `?1000h`, deciding a
    /// click now belongs to the program rather than to the selection, and encoding it. What is
    /// pinned here is the public signal that any of it is still happening, because a dependency that
    /// silently stopped would present as "the mouse does not work in vim" and nothing else.
    ///
    /// `mouseModeChanged` rather than the mode itself: SwiftTerm keeps `mouseMode`'s predicates
    /// internal, and a test that reached past an access level would be pinning an implementation
    /// detail the library is free to move.
    func testTheEmulatorActsOnTheMouseModesAProgramSets() {
        let recorder = RecordingTerminalDelegate()
        let terminal = Terminal(delegate: recorder, options: TerminalOptions(cols: 80, rows: 24))
        // A baseline rather than zero: constructing a terminal settles its modes and notifies once,
        // which is the emulator's business and not something to pin.
        let baseline = recorder.mouseModeChanges

        // `?1000h` is "report button presses" — the mode every full-screen program sets.
        terminal.feed(text: "\u{1b}[?1000h")
        XCTAssertGreaterThan(
            recorder.mouseModeChanges, baseline,
            "the emulator did not act on ?1000h — mouse reporting is not reaching the terminal"
        )
        let afterPress = recorder.mouseModeChanges

        // …and off again, which is the state ordinary text selection depends on: a mode left set
        // after a program exits is a pane whose text can no longer be selected.
        terminal.feed(text: "\u{1b}[?1000l")
        XCTAssertGreaterThan(recorder.mouseModeChanges, afterPress, "the mode never cleared")

        // `?1006h` (the SGR encoding) is deliberately not asserted here. It changes how a click is
        // *encoded* rather than whether one is reported, and SwiftTerm does not announce it — the
        // predicates that would show it are internal, and a test reaching past an access level would
        // pin an implementation detail the library is free to move.

        // None of it should have written anything back. A mode change is a statement, not a
        // question, and a terminal that answered one would be typing into the user's shell.
        XCTAssertTrue(recorder.sent.isEmpty, "feeding mode changes produced output: \(recorder.sent)")
    }

    /// tetmux's own half: the pane permits reporting at all.
    ///
    /// One line in `TerminalPaneView.makeNSView`, and the only part of F4.23 that is ours to get
    /// wrong. With it false every mode above would be parsed and then ignored.
    func testAPanePermitsMouseReporting() {
        let (view, _) = makeView()
        XCTAssertTrue(view.allowMouseReporting, "T5.3 — the pane refuses to report the mouse at all")
    }

    // MARK: - F4.24, input methods

    /// Nothing reaches the channel until the composition commits.
    ///
    /// This is the property that matters, and the one a change to the keystroke path would break
    /// without looking like a break: marked text is *provisional*: the ‘n’ of a Japanese ん, the
    /// vowel not yet chosen in a Korean syllable, the accent waiting for its letter. Sent as it is
    /// typed it would arrive at the shell as literal characters, and the user would see their input
    /// method's own preview appear in the pane as text.
    func testMarkedTextIsNotSentUntilItIsCommitted() {
        let (view, recorder) = makeView()

        view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(recorder.bytes.isEmpty, "a first composition keystroke reached the channel: \(recorder.text)")

        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(recorder.bytes.isEmpty, "a revised composition reached the channel: \(recorder.text)")
        XCTAssertTrue(view.hasMarkedText(), "the view is not tracking a composition at all")

        view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(recorder.text, "日本", "the committed string is not what arrived")
        XCTAssertFalse(view.hasMarkedText(), "the composition was not cleared by the commit")
    }

    /// A dead key — ⌥e then e — is the same contract in the shape almost everyone meets.
    ///
    /// It is one keystroke's worth of latency in the ordinary case and it is the case that breaks
    /// first, because the accent is marked text with a single character in it and looks exactly like
    /// an ordinary keypress to anything counting bytes.
    func testADeadKeySequenceArrivesOnlyOnceComposed() {
        let (view, recorder) = makeView()

        view.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(recorder.bytes.isEmpty, "the bare accent was sent: \(recorder.text)")

        view.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(recorder.text, "é")
        // One committed string, one write. A composition that arrived as its parts would put the
        // accent and the letter through as two keystrokes, which is what a shell's line editor sees
        // as two characters.
        XCTAssertEqual(recorder.bytes.count, 1, "the commit was split across writes: \(recorder.bytes)")
    }

    /// Press-and-hold — holding `n` for `ñ` — replaces the base character instead of following it.
    ///
    /// The two tests above are the composition contract, and press-and-hold is deliberately *not*
    /// that: nothing is ever marked. The base character is committed at once, and the accent picked
    /// from the popup arrives as a second `insertText` whose `replacementRange` covers the first —
    /// captured from a logging `NSTextInputClient` as `{NSNotFound, 0}` then `{0, 1}`. SwiftTerm
    /// discards that range, which is what put `nñ` in the pane.
    ///
    /// The range's *length* is what is honoured and its location is deliberately ignored: it is an
    /// offset into whatever the client reported as its selection, and SwiftTerm's is a terminal
    /// coordinate (`row × cols + col`) rather than an index into anything we hold.
    func testPressAndHoldReplacesTheBaseCharacterRatherThanFollowingIt() {
        let (view, recorder) = makeView()

        view.insertText("n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(recorder.text, "n", "the base character of a long press did not reach the pane")

        view.insertText("ñ", replacementRange: NSRange(location: 0, length: 1))
        XCTAssertEqual(
            recorder.text, "n\u{7f}ñ",
            "the accent did not take back the base character — this is the pane receiving `nñ`"
        )
    }

    // MARK: - Who the bytes came from

    /// A query the program asks its terminal is answered, and is not input.
    ///
    /// `TerminalViewDelegate.send` carries the user's keystrokes and the emulator's own replies
    /// through one method, and tetmux focuses the pane for the former. Reading a reply as input is
    /// what let a program take the keyboard by asking a question: split a window with Claude Code in
    /// a background pane and the resize makes it re-query, so the pane the split just created lost
    /// the keyboard to a pane nobody had touched.
    ///
    /// `CSI 6n` is the ordinary one — a cursor position report, which every full-screen program uses
    /// to find out where it is. What is pinned is that the answer still goes out (the program is
    /// waiting for it) and that it is marked as the emulator's.
    func testTheAnswerToAProgramsQueryIsMarkedAsTheEmulatorsOwn() {
        let (view, recorder) = makeView()

        view.getTerminal().feed(text: "\u{1b}[6n")

        XCTAssertEqual(recorder.bytes.count, 1, "the cursor position report was never answered")
        XCTAssertTrue(
            recorder.text.hasSuffix("R"),
            "the answer is not a cursor position report: \(recorder.text.debugDescription)"
        )
        XCTAssertEqual(
            recorder.answeringQuery, [true],
            "a terminal reply reached the delegate looking like something the user typed — this is a "
                + "background pane stealing the keyboard from the one the user is in"
        )
    }

    /// …and what the user types is not marked, which is the half that keeps focus working.
    ///
    /// The failure this exists for is the opposite one and is silent: a flag that was set for
    /// everything would leave the pane the keyboard is already in unable to say so, and nothing on
    /// screen would look wrong until a command acted on the wrong pane.
    func testWhatTheUserTypesIsNotMarkedAsTheEmulatorsOwn() {
        let (view, recorder) = makeView()

        view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(recorder.text, "a")
        XCTAssertEqual(recorder.answeringQuery, [false], "a keystroke was read as a terminal reply")
    }

    /// A mouse report is the emulator's too, and that is deliberate rather than incidental.
    ///
    /// It is encoded by `Terminal.sendEvent` and leaves by the same door as a query's answer, so it
    /// carries the mark — which is right: a report can be produced by the pointer merely crossing a
    /// pane, and motion is not a statement about where the keyboard belongs. A *click* is, and
    /// `PaneTerminalView.mouseDown` says so directly instead.
    func testAMouseReportIsTheEmulatorsOwnAndTheClickIsWhatFocuses() {
        let (view, recorder) = makeView()
        view.getTerminal().feed(text: "\u{1b}[?1000h")

        guard let click = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 40, y: 40),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else { return XCTFail("could not synthesise a click") }
        view.mouseDown(with: click)

        XCTAssertFalse(recorder.bytes.isEmpty, "the click was not reported to the program at all")
        XCTAssertFalse(
            recorder.answeringQuery.contains(false),
            "a mouse report reached the delegate as though it were typed"
        )
    }

    /// …and an ordinary keystroke erases nothing.
    ///
    /// The failure this exists for is the opposite one and is far worse than the duplicate: an
    /// erasure keyed on something other than a non-empty replacement range would put a Delete in
    /// front of every character the user types.
    func testAnOrdinaryInsertionErasesNothing() {
        let (view, recorder) = makeView()

        view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("b", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(recorder.text, "ab", "an insertion with no replacement range erased something")
    }
}

/// Records what the emulator hands to its delegate, which is the seam bytes cross to reach the
/// channel. `TerminalPaneView.Coordinator` forwards exactly this to `SessionService.sendKeys`.
///
/// Not `@MainActor`: SwiftTerm's delegate protocols are not, and a conformance that added isolation
/// would not compile. The tests drive it from one thread.
private final class RecordingDelegate: TerminalViewDelegate, @unchecked Sendable {
    private(set) var bytes: [[UInt8]] = []
    /// What the view claimed about each write *at the moment it was made*, which is the only moment
    /// the answer exists: the flag is cleared as the call returns.
    private(set) var answeringQuery: [Bool] = []

    var text: String { bytes.map { String(decoding: $0, as: UTF8.self) }.joined() }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        bytes.append(Array(data))
        answeringQuery.append((source as? ComposingTerminalView)?.isAnsweringQuery ?? false)
    }

    func scrolled(source: TerminalView, position: Double) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// The same, one layer down, for the questions that are the *terminal's* rather than the view's.
private final class RecordingTerminalDelegate: TerminalDelegate, @unchecked Sendable {
    private(set) var sent: [[UInt8]] = []
    private(set) var mouseModeChanges = 0

    func send(source: Terminal, data: ArraySlice<UInt8>) { sent.append(Array(data)) }
    func mouseModeChanged(source: Terminal) { mouseModeChanges += 1 }

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
