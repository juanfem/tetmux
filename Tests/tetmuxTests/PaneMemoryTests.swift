import XCTest
import SwiftTerm
@testable import tetmuxUI

/// P6.7 — what a pane's scrollback costs, pinned at its source.
///
/// The memory half of P6.7 was amended on 2026-08-06 to a per-pane bound (< 90 MB with one pane at
/// the default scrollback, < 30 MB for each additional) because the old total contradicted its own
/// "10 000 lines/pane" parenthesis. That amendment rests on one number from a dependency — the size
/// of a terminal cell — and a dependency's struct layout is exactly the kind of fact that changes
/// under you without a compile error.
///
/// So it is asserted rather than assumed. If SwiftTerm packs `CharData` tighter, P6.7's bound is
/// suddenly conservative and should be tightened; if it grows one, the bound silently stops holding
/// and `docs/measurements.md` is describing a machine that no longer exists.
final class PaneMemoryTests: XCTestCase {

    /// What P6.7's arithmetic multiplies by.
    private let assumedCellStride = 24

    func testACellIsTheSizeP67sArithmeticAssumes() {
        XCTAssertEqual(
            MemoryLayout<CharData>.stride, assumedCellStride,
            """
            SwiftTerm's cell size changed. P6.7's memory bound and the per-pane figures in \
            docs/measurements.md were derived from \(assumedCellStride) bytes a cell — redo that \
            arithmetic and amend the requirement rather than deleting this assertion.
            """
        )
    }

    /// The cell is 24 bytes because of what is *in* it, and the largest part is the attribute.
    ///
    /// `code` is 4, `width` 1, the atom 1, one byte of padding — and `Attribute` is 14, which is two
    /// 4-byte `Color`s (truecolor needs three components plus a tag) and the style. That is what
    /// makes a cell 24 rather than the 16 SwiftTerm's own comment beside the padding field still
    /// claims: the comment predates truecolor and the struct outgrew it. Worth pinning separately,
    /// because a change here is the *reason* a change above would happen, and knowing which half
    /// moved is the difference between a dependency bump and a redesign.
    func testTheAttributeIsWhatMakesACellLarge() {
        XCTAssertEqual(MemoryLayout<Attribute>.stride, 14)
        XCTAssertEqual(MemoryLayout<Attribute.Color>.stride, 4)
    }

    /// The estimate the settings pane shows beside the scrollback picker.
    ///
    /// It exists so the choice is legible: the picker offers 100 000 lines, which is ten times the
    /// default and is paid *per pane*. Asserted rather than eyeballed because it is the one place
    /// the application makes a numeric claim to the user about memory, and a wrong one there is
    /// worse than none — somebody would lower their scrollback for nothing, or raise it into
    /// gigabytes trusting a figure that was out by an order of magnitude.
    func testTheSettingsEstimateTracksTheChoice() {
        var theme = TerminalTheme.default
        let perCell = MemoryLayout<CharData>.stride

        theme.scrollbackLines = 10_000
        XCTAssertEqual(theme.estimatedScrollbackBytesPerPane(), 10_000 * 80 * perCell)
        XCTAssertEqual(theme.estimatedScrollbackBytesPerPane() / 1_048_576, 18)

        // The two ends of the picker, which are what the estimate is really for: the difference
        // between them is 1.5 MB a pane and 183 MB a pane.
        theme.scrollbackLines = 1_000
        XCTAssertEqual(theme.estimatedScrollbackBytesPerPane() / 1_048_576, 1)
        theme.scrollbackLines = 100_000
        XCTAssertEqual(theme.estimatedScrollbackBytesPerPane() / 1_048_576, 183)

        // …and it is proportional, so no choice in between can be surprising.
        theme.scrollbackLines = 5_000
        let half = theme.estimatedScrollbackBytesPerPane()
        theme.scrollbackLines = 10_000
        XCTAssertEqual(theme.estimatedScrollbackBytesPerPane(), half * 2)
    }

    /// The consequence, stated in the units P6.7 is written in.
    ///
    /// This is the arithmetic that made the old "< 150 MB with 20 panes at 10 000 lines/pane"
    /// unmeetable: one pane of ordinary width holds more than a tenth of that budget in cell data
    /// alone, before any allocator rounding, per-line object, alternate screen buffer or view.
    func testOnePaneOfScrollbackIsMostOfTheOldBudget() {
        let theme = TerminalTheme.default
        XCTAssertEqual(theme.scrollbackLines, 10_000, "the default this is a claim about")

        let bytes = theme.scrollbackLines * 80 * MemoryLayout<CharData>.stride
        let megabytes = Double(bytes) / 1_048_576
        XCTAssertGreaterThan(megabytes, 15, "80 columns of default scrollback: \(megabytes) MB")
        // Twenty of them cannot fit in 150 MB, which is the whole reason P6.7 was amended.
        XCTAssertGreaterThan(megabytes * 20, 150)
    }
}
