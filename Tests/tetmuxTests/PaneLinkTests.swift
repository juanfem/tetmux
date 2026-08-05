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
