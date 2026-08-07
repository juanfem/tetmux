import AppKit
import SwiftTerm
import XCTest
@testable import tetmuxUI

/// T5.5 — what a pane does with a link, and with the point a right-click landed on.
///
/// Two things are asserted here and they fail for different reasons. The detection is SwiftTerm's,
/// so those tests are really a contract with the dependency: implicit matching is on by default in
/// the pinned version, and if a bump turns it off or narrows the pattern, plain-text URLs stop being
/// clickable with nothing in the app to notice. The scheme allowlist is ours, and it is the only
/// thing standing between remote text and `NSWorkspace.open`.
@MainActor
final class PaneLinkTests: XCTestCase {

    /// Feeds a line of plain text into a terminal and returns what it finds at `col` on row 0.
    private func linkInPlainText(_ text: String, at col: Int) -> String? {
        let terminal = Terminal(delegate: NullTerminalDelegate(), options: TerminalOptions(cols: 120, rows: 4))
        terminal.feed(text: text)
        return terminal.link(at: .screen(Position(col: col, row: 0)), mode: .explicitAndImplicit)
    }

    /// The case the audit named: the URL `git push` prints, in ordinary output with no OSC 8 around
    /// it. Nothing in tetmux emits this — it is the emulator's implicit matcher, and the point of the
    /// test is that it is reachable and switched on.
    func testAUrlInPlainOutputIsDetected() {
        let line = "remote: Create a pull request by visiting https://github.com/acme/widget/pull/new/topic"
        let found = linkInPlainText(line, at: 50)
        XCTAssertEqual(found, "https://github.com/acme/widget/pull/new/topic")
    }

    func testOrdinaryProseIsNotALink() {
        XCTAssertNil(linkInPlainText("total 48 drwxr-xr-x 5 me staff 160 Aug  5 09:14 Sources", at: 20))
    }

    /// A pane's contents are remote text and `NSWorkspace.open` launches whatever application has
    /// claimed a scheme, so anything that could start something locally has to be refused. The
    /// allowlist is checked here rather than through `open`, which would actually launch it.
    func testOnlySchemesThatCannotLaunchSomethingLocallyAreOpened() {
        let allowed = [
            "https://example.com/a",
            "http://example.com",
            "mailto:someone@example.com",
            "ftp://ftp.example.com/pub",
        ]
        let refused = [
            "file:///etc/passwd",
            "ssh://root@example.com",
            "x-apple-script://run",
            "vnc://example.com",
            "javascript:alert(1)",
            "not a url at all",
            "",
        ]
        for link in allowed {
            XCTAssertTrue(TerminalPaneView.isOpenableExternally(link), "should have been allowed: \(link)")
        }
        for link in refused {
            XCTAssertFalse(TerminalPaneView.isOpenableExternally(link), "should have been refused: \(link)")
        }
    }
}

/// What a screen reader can get out of a pane.
///
/// The chrome around the terminal was labelled thoroughly and the terminal itself had a name, a role
/// and no contents at all — SwiftTerm's accessibility service is an empty stub. These assert the part
/// that matters: the text on screen is readable, and the role says what kind of thing it is.
@MainActor
final class PaneAccessibilityTests: XCTestCase {

    private func makePane(feeding text: String) -> PaneTerminalView {
        let view = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 240),
            font: TerminalTheme.default.resolvedFont()
        )
        view.feed(text: text)
        return view
    }

    func testTheScreenContentsAreTheAccessibilityValue() {
        let pane = makePane(feeding: "first line\r\nsecond line\r\n")
        let value = pane.accessibilityValue() as? String
        XCTAssertNotNil(value)
        XCTAssertTrue(value?.contains("first line") == true, "got \(value ?? "nil")")
        XCTAssertTrue(value?.contains("second line") == true, "got \(value ?? "nil")")
        XCTAssertEqual(pane.accessibilityNumberOfCharacters(), value?.count)
    }

    /// The viewport, not the scrollback: the cost of the value has to be bounded by the grid, or a
    /// pane holding a large history makes every VoiceOver query expensive.
    func testTheValueIsBoundedByTheGridRatherThanTheScrollback() {
        let pane = makePane(feeding: (1...500).map { "line \($0)\r\n" }.joined())
        let value = pane.accessibilityValue() as? String ?? ""
        let rows = pane.getTerminal().rows
        XCTAssertEqual(value.split(separator: "\n", omittingEmptySubsequences: false).count, rows)
        XCTAssertFalse(value.contains("line 1\n"), "an old line must have scrolled out of the value")
        XCTAssertTrue(value.contains("line 500"), "the newest line must be in it")
    }

    /// "text area" is what every field on screen announces as.
    func testThePaneSaysWhatKindOfThingItIs() {
        XCTAssertEqual(makePane(feeding: "").accessibilityRoleDescription(), "terminal")
    }

    func testNoSelectionMeansNoSelectedText() {
        XCTAssertNil(makePane(feeding: "hello").accessibilitySelectedText())
    }
}

/// SwiftTerm's `Terminal` requires a delegate; nothing here reacts to one.
private final class NullTerminalDelegate: TerminalDelegate {
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
    func clipboardCopy(source: Terminal, content: Data) {}
    func clipboardRead(source: Terminal) -> Data? { nil }
    func notify(source: Terminal, title: String, body: String) {}
    func iTermContent(source: Terminal, content: ArraySlice<UInt8>) {}
    func selectionChanged(source: Terminal) {}
    func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {}
    func createImage(source: Terminal, data: Data, width: ImageSizeRequest, height: ImageSizeRequest,
                     preserveAspectRatio: Bool) {}
}

/// SwiftTerm writes parser diagnostics to stdout, and tetmux turns that off.
///
/// Pinned for the reason the other SwiftTerm pins exist: this is behaviour tetmux depends on but
/// does not implement, so a dependency bump that renamed or removed `silentLog` should fail here
/// rather than quietly restore a line of chatter per unhandled sequence — which a remote shell's
/// prompt hook can emit on every command.
final class TerminalLoggingTests: XCTestCase {

    func testPaneTerminalsAreQuietByDefault() {
        let terminal = Terminal(delegate: StubTerminalDelegate())
        terminal.silentLog = false
        TerminalTheme.quietParserLogging(terminal)
        XCTAssertTrue(terminal.silentLog, "SwiftTerm would print to stdout on every unhandled code")
    }

    /// The default is the *debug* build's, which is the one that prints. Asserting the flag rather
    /// than the build configuration keeps this meaningful in both.
    func testSwiftTermStillExposesTheFlagWeSet() {
        let terminal = Terminal(delegate: StubTerminalDelegate())
        terminal.silentLog = true
        XCTAssertTrue(terminal.silentLog)
        terminal.silentLog = false
        XCTAssertFalse(terminal.silentLog)
    }
}

private final class StubTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

/// Switching tab must move the keyboard with it.
///
/// Every tmux window of the session is built and the unselected ones are hidden with `.opacity(0)`
/// rather than dropped, so their pane surfaces stay in the view hierarchy — and a transparent
/// `NSView` is still perfectly able to be first responder. `focusedPaneId` is one value per macOS
/// window, so after a keyboard tab switch it still named a pane in the tab being *left*: nothing in
/// the new tab matched it, so nothing there took the keyboard, while the old tab's pane went on
/// matching and went on receiving every keystroke. You typed into a pane you could not see.
final class TabFocusTests: XCTestCase {

    @MainActor
    func testSelectingAnotherTabDropsTheFocusedPane() {
        let state = WindowState()
        state.selectedWindowId = "@1"
        state.focusedPaneId = "%5"

        state.selectedWindowId = "@2"

        XCTAssertNil(
            state.focusedPaneId,
            "it named a pane in the tab being left, so the new tab could focus nothing"
        )
    }

    /// Re-selecting the same tab is not a switch, and must not throw away where the user was.
    @MainActor
    func testReselectingTheSameTabKeepsTheFocusedPane() {
        let state = WindowState()
        state.selectedWindowId = "@1"
        state.focusedPaneId = "%5"

        state.selectedWindowId = "@1"

        XCTAssertEqual(state.focusedPaneId, "%5")
    }
}

/// Middle-click pastes the selection, not the clipboard.
final class PrimarySelectionTests: XCTestCase {

    @MainActor
    func testASelectionBecomesThePrimary() {
        PrimarySelection.text = nil
        PrimarySelection.text = "selected words"
        XCTAssertEqual(PrimarySelection.text, "selected words")
    }

    /// The clipboard is the last resort and must not be the first answer: that is what made
    /// selecting a word and middle-clicking paste whatever was last ⌘C'd.
    @MainActor
    func testThePrimaryIsSeparateFromTheClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("clipboard contents", forType: .string)
        PrimarySelection.text = "selected words"

        XCTAssertEqual(PrimarySelection.text, "selected words")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "clipboard contents")
        XCTAssertNotEqual(PrimarySelection.text, NSPasteboard.general.string(forType: .string))
    }
}
