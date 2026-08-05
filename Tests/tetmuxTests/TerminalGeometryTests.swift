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

    /// The scale factor the view under test will resolve for itself.
    ///
    /// It has to be *this* number and not a convenient constant, because the snap to whole pixels is
    /// `ceil(w * scale) / scale` on both sides and a mismatch moves the cell width by a whole point:
    /// at 12pt SF Mono the `W` advance is 7.2, which snaps to 7.5 at 2× and to 8.0 at 1×, and 720pt
    /// of frame is then either 96 columns or 90. Hard-coding 2 here made the test fail on any runner
    /// with no screen — SwiftTerm falls back through `window` to `NSScreen.main` to 1, and a headless
    /// `xctest` has neither — while the defect it exists to catch was nowhere near it.
    private var viewScaleFactor: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 1
    }

    private func makeView(cols: Int, theme: TerminalTheme = .default) -> (TerminalView, CGSize, CGFloat) {
        let cell = theme.cellSize(backingScaleFactor: viewScaleFactor)
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
        let cell = theme.cellSize(backingScaleFactor: viewScaleFactor)
        for cols in [40, 80, 96, 200] {
            let width = CGFloat(cols) * cell.width
            XCTAssertEqual(Int(width / cell.width), cols, "\(cols) columns did not survive the round trip")
        }
    }

    /// A 1× and a 2× display give the same font *different* cell widths, so asking with the wrong
    /// one is not a rounding difference — it is several columns.
    ///
    /// This is what made `NSScreen.main` the wrong source. It is not the window's screen; it is the
    /// screen holding whichever window has keyboard focus anywhere on the system, so clicking into
    /// another application on the other monitor changed the answer while the window had not moved.
    /// SwiftTerm meanwhile resolves its own `cellDimension` from `window?.backingScaleFactor` and
    /// gets the real one, so the two sides of §3.3 came apart. Measured on a 1× monitor beside a 2×
    /// built-in: a 572pt pane asked tmux for 71 columns while its own grid drew 76.
    ///
    /// The fix is `@Environment(\.displayScale)`, which follows the window. There is nothing here to
    /// assert about the environment itself — that is SwiftUI's — so what is pinned is the reason it
    /// matters: the two scale factors disagree by whole columns, and a future "just use 2" would
    /// bring the bug straight back.
    func testTheTwoScaleFactorsDisagreeByWholeColumns() {
        let theme = TerminalTheme.default
        let oneX = theme.cellSize(backingScaleFactor: 1).width
        let twoX = theme.cellSize(backingScaleFactor: 2).width
        XCTAssertNotEqual(oneX, twoX, "a font that snapped the same way at both densities would make this moot")

        // A pane the size of the one that was measured misbehaving.
        let paneWidth: CGFloat = 572
        let asked = Int(paneWidth / oneX)
        let drawn = Int(paneWidth / twoX)
        XCTAssertGreaterThanOrEqual(
            drawn - asked, 3,
            "expected the wrong scale factor to cost several columns, not a rounding error"
        )
    }
}
