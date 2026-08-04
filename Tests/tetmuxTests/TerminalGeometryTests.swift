import AppKit
import SwiftTerm
import XCTest
@testable import tetmuxCore
@testable import tetmuxUI

/// §3.3 — the grid tmux is asked for has to be the grid the emulator can actually draw.
///
/// `requestSizes` measures the container and asks tmux for `width / cellWidth` columns. That is only
/// correct if the emulator gets to use its whole frame, and for a long time it did not: SwiftTerm
/// reserves `scrollerWidth` on the right and derives its own column count from
/// `frame.width - reservedScrollerWidth`, overriding the `resize(cols:rows:)` it is handed. So tmux
/// sized every pane to more columns than could be drawn, and anything using the full width wrapped a
/// few columns early — a full-width TUI spilled the end of each line onto the next one.
///
/// The failure is silent and looks like a text-layout quirk rather than a geometry bug, which is why
/// it is worth a test rather than a comment.
@MainActor
final class TerminalGeometryTests: XCTestCase {

    private func makeView(cols: Int, theme: TerminalTheme = .default) -> (TerminalView, CGSize, CGFloat) {
        let cell = theme.cellSize(backingScaleFactor: 2)
        let size = CGSize(width: CGFloat(cols) * cell.width, height: 24 * cell.height)
        // Built at a different size, then given the real one — the order SwiftUI uses, and the order
        // that matters, because SwiftTerm recomputes its grid when the frame changes.
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 100),
            font: theme.resolvedFont()
        )
        return (view, size, cell.width)
    }

    func testHidingTheReservedScrollerGivesTheGridTheWholeFrame() {
        let requested = 96
        let (view, size, _) = makeView(cols: requested)

        TerminalPaneView.hideReservedScroller(in: view)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            view.getTerminal().cols, requested,
            "the emulator must render every column tmux was asked for, or full-width output wraps early"
        )
    }

    /// The control: without hiding it, the same frame yields *fewer* columns than it was sized for.
    ///
    /// Asserted as an inequality rather than an exact count, so it pins the defect without also
    /// pinning SwiftTerm's scroller metrics — those are its business and may change.
    func testTheReservedScrollerIsWhatCostsColumns() {
        let requested = 96
        let (view, size, _) = makeView(cols: requested)

        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()

        XCTAssertLessThan(
            view.getTerminal().cols, requested,
            "if this stops being true the scroller no longer reserves width and the hiding can go"
        )
    }

    /// The other half of the contract: the cell size comes from the font, so the columns a container
    /// asks for are exactly the columns its width divides into.
    func testColumnsAskedForFitTheContainerExactly() {
        let theme = TerminalTheme.default
        let cell = theme.cellSize(backingScaleFactor: 2)
        for cols in [40, 80, 96, 200] {
            let width = CGFloat(cols) * cell.width
            XCTAssertEqual(Int(width / cell.width), cols, "\(cols) columns did not survive the round trip")
        }
    }
}
