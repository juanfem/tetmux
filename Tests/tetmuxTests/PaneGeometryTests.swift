import CoreGraphics
import XCTest
@testable import tetmuxCore
@testable import tetmuxUI

/// How a tmux layout becomes pane rects (F4.7), and the focus frame's band around each pane.
///
/// The band is what these are for. The frame used to be drawn over the terminal and covered its
/// outermost characters; it now has `paneInset` of its own on every side, and the room for it inside
/// the window comes out of the divider cells tmux reserves anyway. What breaks that silently is
/// proportional sharing: a narrow pane beside a wide one gets a sliver of the spare space, and its
/// band comes out of its last column again — the same pane that looks fine at 50/50.
@MainActor
final class PaneGeometryTests: XCTestCase {

    private let cell = CGSize(width: 7.5, height: 15)
    private let inset = TerminalContainerView.paneInset

    private func leaf(_ id: String, _ cols: Int, _ rows: Int) -> LayoutNode {
        .leaf(paneId: id, width: cols, height: rows, x: 0, y: 0)
    }

    /// The container `requestSizes` would ask tmux to fill with a `cols`×`rows` grid: the cells, the
    /// outer band, and nothing else.
    private func containerFor(cols: Int, rows: Int) -> CGSize {
        CGSize(
            width: CGFloat(cols) * cell.width + 2 * inset,
            height: CGFloat(rows) * cell.height + 2 * inset
        )
    }

    private func placements(_ tree: LayoutNode, in size: CGSize, scale: CGFloat = 2)
        -> [TerminalContainerView.PanePlacement] {
        TerminalContainerView.geometry(
            tree, origin: .zero, size: size, path: "",
            cell: cell, scale: scale, dividerWidth: 1, grabWidth: 9
        ).panes
    }

    private func assertEveryPaneHoldsItsGridAndBand(
        _ panes: [TerminalContainerView.PanePlacement], file: StaticString = #filePath, line: UInt = #line
    ) {
        for pane in panes {
            XCTAssertGreaterThanOrEqual(
                pane.rect.width, CGFloat(pane.cols) * cell.width + 2 * inset,
                "\(pane.paneId) is too narrow for its \(pane.cols) columns and its band", file: file, line: line
            )
            XCTAssertGreaterThanOrEqual(
                pane.rect.height, CGFloat(pane.rows) * cell.height + 2 * inset,
                "\(pane.paneId) is too short for its \(pane.rows) rows and its band", file: file, line: line
            )
        }
    }

    func testANarrowPaneBesideAWideOneStillGetsItsBand() {
        // 10 | 100, plus the divider cell: 111 columns.
        let tree = LayoutNode.container(
            direction: .leftRight, width: 111, height: 40, x: 0, y: 0,
            children: [leaf("%1", 10, 40), leaf("%2", 100, 40)]
        )
        assertEveryPaneHoldsItsGridAndBand(placements(tree, in: containerFor(cols: 111, rows: 40)))
    }

    func testNestedSplitsInBothDirectionsAllGetTheirBands() {
        // A column of three short panes beside one tall one; every divider is a cell tmux reserved.
        let column = LayoutNode.container(
            direction: .topBottom, width: 30, height: 40, x: 0, y: 0,
            children: [leaf("%1", 30, 3), leaf("%2", 30, 30), leaf("%3", 30, 5)]
        )
        let tree = LayoutNode.container(
            direction: .leftRight, width: 111, height: 40, x: 0, y: 0,
            children: [column, leaf("%4", 80, 40)]
        )
        let panes = placements(tree, in: containerFor(cols: 111, rows: 40))
        XCTAssertEqual(panes.map(\.paneId), ["%1", "%2", "%3", "%4"])
        assertEveryPaneHoldsItsGridAndBand(panes)
    }

    /// The smallest cell the font-size bounds allow is what the divider cell has to hold two bands
    /// and a seam in. If `paneInset` grows past it, this is where it shows.
    func testTheSmallestCellStillHoldsTwoBandsAndASeam() {
        var theme = TerminalTheme.default
        theme.fontSize = TerminalTheme.fontSizeRange.lowerBound
        let smallest = theme.cellSize(backingScaleFactor: 1)
        XCTAssertGreaterThanOrEqual(smallest.width, 2 * inset + 1)
    }

    func testPartsSumToTheWhole() {
        for weights in [[40, 39], [100, 99], [1, 1, 1], [7, 3], [99, 1]] {
            let needs = weights.map { CGFloat($0) * cell.width + 2 * inset }
            let parts = TerminalContainerView.fit(1000, needs: needs, weights: weights, scale: 2)
            XCTAssertEqual(parts.reduce(0, +), 1000, accuracy: 0.001, "weights \(weights)")
        }
    }

    func testSplitIsProportionalToCells() {
        let parts = TerminalContainerView.fit(1000, needs: [4, 4], weights: [70, 30], scale: 2)
        XCTAssertEqual(parts[0] / parts[1], 70.0 / 30.0, accuracy: 0.05)
    }

    func testExtentsLandOnThePixelGrid() {
        for scale: CGFloat in [1, 2] {
            let parts = TerminalContainerView.fit(1001, needs: [100.25, 300.75], weights: [13, 40], scale: scale)
            for part in parts {
                XCTAssertEqual((part * scale).rounded(), part * scale, "\(part) at \(scale)×")
            }
        }
    }

    /// A container showing a grid it does not own can be smaller than that grid; every pane still
    /// has to be laid out, not given a zero or negative extent.
    func testASqueezedContainerStillGivesEveryPaneAPoint() {
        let parts = TerminalContainerView.fit(10, needs: Array(repeating: 11.5, count: 12),
                                              weights: Array(repeating: 1, count: 12), scale: 2)
        XCTAssertTrue(parts.allSatisfy { $0 >= 1 }, "got \(parts)")
    }

    func testZeroWeightsFallBackToEqualShares() {
        let parts = TerminalContainerView.fit(300, needs: [0, 0, 0], weights: [0, 0, 0], scale: 1)
        XCTAssertEqual(parts, [100, 100, 100])
    }
}
