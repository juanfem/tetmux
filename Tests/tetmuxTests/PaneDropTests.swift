import AppKit
import SwiftTerm
import XCTest
@testable import tetmuxCore
@testable import tetmuxUI

/// Drag and drop onto a terminal, the way Terminal.app defines it: a dropped file types its
/// path, escaped for the shell; dropped text is a paste.
///
/// The interesting surface is the escaping, because its failures point in opposite directions.
/// Under-escape and a space in a filename splits into two arguments — or worse, `$(…)` in one
/// runs — the moment the user presses return. Over-escape and every accented filename arrives
/// wearing backslashes it does not need. Both read as "drag and drop is broken", neither says so
/// anywhere, and the case that cannot be backslash-escaped at all (a newline, which backslash
/// *continues* rather than carries) would silently run the fragment before it as a command.
@MainActor
final class PaneDropTests: XCTestCase {

    // MARK: - Escaping

    func testAnOrdinaryPathIsNotEscapedAtAll() {
        XCTAssertEqual(
            ComposingTerminalView.shellEscaped("/Users/me/Projects/tetmux/README.md"),
            "/Users/me/Projects/tetmux/README.md"
        )
    }

    func testShellMetacharactersAreBackslashEscaped() {
        XCTAssertEqual(
            ComposingTerminalView.shellEscaped("/Users/me/My File (draft 2).txt"),
            "/Users/me/My\\ File\\ \\(draft\\ 2\\).txt"
        )
        XCTAssertEqual(ComposingTerminalView.shellEscaped("/tmp/a'b\"c$d"), "/tmp/a\\'b\\\"c\\$d")
        // `~` and `=` look harmless and are not: zsh expands both at the start of a word.
        XCTAssertEqual(ComposingTerminalView.shellEscaped("~backup=old"), "\\~backup\\=old")
    }

    /// Non-ASCII is literal to every shell, so escaping it would be pure noise — the failure this
    /// pins is `café` arriving as `caf\é`.
    func testNonASCIIPassesThroughUntouched() {
        XCTAssertEqual(
            ComposingTerminalView.shellEscaped("/tmp/café/日本語 メモ.txt"),
            "/tmp/café/日本語\\ メモ.txt"
        )
    }

    /// Backslash-newline is a line *continuation*: the escape that carries every other character
    /// makes this one vanish, and the shell would run the fragment before it as a command. Single
    /// quotes are the only quoting a newline survives, with embedded quotes closed around.
    func testAPathCarryingANewlineFallsBackToSingleQuotes() {
        XCTAssertEqual(
            ComposingTerminalView.shellEscaped("/tmp/line\nbreak'quote"),
            "'/tmp/line\nbreak'\\''quote'"
        )
    }

    // MARK: - What the pasteboard turns into

    /// A private pasteboard per test: the general one belongs to the user running the suite.
    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("tetmux-test-\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    func testDroppedFilesBecomeEscapedPathsWithOneTrailingSpace() {
        let board = pasteboard()
        board.writeObjects([
            URL(fileURLWithPath: "/tmp/plain.txt") as NSURL,
            URL(fileURLWithPath: "/tmp/with space.txt") as NSURL,
        ])
        XCTAssertEqual(
            ComposingTerminalView.droppedText(from: board),
            "/tmp/plain.txt /tmp/with\\ space.txt "
        )
    }

    func testDroppedTextIsInsertedVerbatim() {
        let board = pasteboard()
        board.setString("echo 'hello world'\n", forType: .string)
        // Verbatim, and no trailing space: text is a paste, not an argument.
        XCTAssertEqual(ComposingTerminalView.droppedText(from: board), "echo 'hello world'\n")
    }

    /// A Finder drag carries a string alongside the file URL, and the string half is the display
    /// name — taking it would type `plain.txt` with no path at all.
    func testFilesBeatTheTextThatRidesAlongWithThem() {
        let board = pasteboard()
        board.declareTypes([.fileURL, .string], owner: nil)
        (URL(fileURLWithPath: "/tmp/plain.txt") as NSURL).write(to: board)
        board.setString("plain.txt", forType: .string)
        XCTAssertEqual(ComposingTerminalView.droppedText(from: board), "/tmp/plain.txt ")
    }

    func testAnEmptyPasteboardIsNoDropAtAll() {
        XCTAssertNil(ComposingTerminalView.droppedText(from: pasteboard()))
    }

    // MARK: - The surfaces

    /// Both surfaces, by name: the pane, and the class §4.6's passthrough uses bare. Registration
    /// happens in initialisers, so a refactor that added a new designated init and forgot the
    /// call would present as drops silently bouncing off one surface only.
    func testBothTerminalSurfacesAcceptDrops() {
        let pane = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400),
            font: TerminalTheme.default.resolvedFont()
        )
        let passthrough = ComposingTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        for view in [pane, passthrough] {
            XCTAssertTrue(view.registeredDraggedTypes.contains(.fileURL))
            XCTAssertTrue(view.registeredDraggedTypes.contains(.string))
        }
    }

    /// A background tab's panes must hold no registration at all.
    ///
    /// Every tab of a session is built and stacked, and the ones not selected are hidden with zero
    /// opacity and `allowsHitTesting(false)` — neither of which AppKit's search for a drag's
    /// destination consults. It goes by registration and frames, so with two tabs open every drop
    /// landed in the first tab's pane rather than the tab on screen, typing the path into a shell
    /// the user could not see. Unregistering is the only thing that search obeys.
    func testOnlyTheSelectedTabsPanesAreDropDestinations() {
        let view = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400),
            font: TerminalTheme.default.resolvedFont()
        )
        view.acceptsDrops = false
        XCTAssertEqual(view.registeredDraggedTypes, [], "a hidden tab's pane still took drops")

        // And a tab switch puts them back: panes are never rebuilt, so nothing else would.
        view.acceptsDrops = true
        XCTAssertTrue(view.registeredDraggedTypes.contains(.fileURL))
        XCTAssertTrue(view.registeredDraggedTypes.contains(.string))
    }

    /// The flag reaches the view from the tab that owns it, which is the half a unit test on the
    /// view alone cannot see: `isSelectedTab` is threaded through `TerminalPaneView` separately
    /// from `isFocused`, because every pane of the visible tab is a destination and only one of
    /// them has the keyboard.
    func testTheSelectedTabFlagReachesTheSurface() {
        let view = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400),
            font: TerminalTheme.default.resolvedFont()
        )
        for selected in [false, true, false] {
            let pane = TerminalPaneView(
                hostId: "local", paneId: "%1", cols: 80, rows: 24, isFocused: false,
                isSelectedTab: selected, theme: .default, allowsRemoteClipboardWrite: false,
                service: SessionService(), onFocusRequest: {}
            )
            pane.applyDropRegistration(to: view)
            XCTAssertEqual(view.acceptsDrops, selected)
        }
    }

    /// The base class's route is the passthrough surface's: straight out the channel, because
    /// there is no tmux buffer on the far end to go through.
    func testTheBaseSurfaceWritesADropStraightToTheChannel() {
        let recorder = RecordingDropDelegate()
        let view = ComposingTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.terminalDelegate = recorder
        view.insertDropped("/tmp/plain.txt ")
        XCTAssertEqual(recorder.text, "/tmp/plain.txt ")
    }

    /// The program on the far end of a passthrough channel can ask for bracketed paste the same
    /// as any other, and a drop that ignored the mode would let a path containing a newline —
    /// or dropped multi-line text — start executing on arrival.
    func testTheBaseSurfaceHonoursBracketedPaste() {
        let recorder = RecordingDropDelegate()
        let view = ComposingTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.terminalDelegate = recorder
        view.getTerminal().feed(text: "\u{1b}[?2004h")
        view.insertDropped("dropped")
        XCTAssertEqual(recorder.text, "\u{1b}[200~dropped\u{1b}[201~")
    }

    /// A pane takes the coordinator's paste route, and takes the focus with it.
    ///
    /// Both halves are the override's whole reason to exist, and both fail quietly. Inheriting the
    /// base class's direct write would send the text as SwiftTerm's own keystroke-per-character
    /// insertion, which cannot carry a newline safely and goes nowhere near tmux's paste buffer — so
    /// it would look right for a short path and mangle anything longer. And a drop is a statement
    /// about where the pointer is, like a right-click: dropping onto an unfocused pane must move the
    /// focus there, or the path is typed into whichever pane happened to have it.
    ///
    /// The recorder stands in for the delegate the coordinator normally is, so that "nothing left
    /// through the channel" can be asserted at all: the route under test is the one that does not go
    /// there.
    func testAPaneRoutesADropThroughTheCoordinatorAndFocusesItself() {
        var focusRequests = 0
        let coordinator = TerminalPaneView.Coordinator(parent: TerminalPaneView(
            hostId: "local", paneId: "%1", cols: 80, rows: 24, isFocused: false,
            isSelectedTab: true, theme: .default, allowsRemoteClipboardWrite: false,
            service: SessionService(), onFocusRequest: { focusRequests += 1 }
        ))
        let recorder = RecordingDropDelegate()
        let view = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400),
            font: TerminalTheme.default.resolvedFont()
        )
        // Held by the view weakly, as the real one is by the real view.
        view.coordinator = coordinator
        view.terminalDelegate = recorder

        view.insertDropped("/tmp/plain.txt ")

        XCTAssertEqual(focusRequests, 1, "a drop landed in a pane without focusing it")
        XCTAssertEqual(recorder.text, "", "the drop was typed at the emulator instead of pasted")
    }
}

/// The seam the drop leaves through — `PaneInputTests`' recorder without the isolation.
///
/// That one is `@MainActor` behind a `@preconcurrency` conformance because it reads a view's state,
/// which is main-actor; this one reads nothing but its own bytes, so a plain nonisolated witness
/// satisfies `TerminalViewDelegate` on both toolchains this package is built with. Copying the
/// attribute across bought nothing and cost a warning saying exactly that.
private final class RecordingDropDelegate: TerminalViewDelegate {
    private(set) var bytes: [[UInt8]] = []

    var text: String { bytes.map { String(decoding: $0, as: UTF8.self) }.joined() }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        bytes.append(Array(data))
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
