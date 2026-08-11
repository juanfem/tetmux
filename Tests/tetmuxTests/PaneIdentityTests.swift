import AppKit
import SwiftTerm
import SwiftUI
import XCTest
@testable import tetmuxCore
@testable import tetmuxUI

/// A pane's `NSView` has to survive a change in the *shape* of the layout, not only a change in its
/// numbers.
///
/// `.id(paneId)` was on the surface from the start and was not enough, because SwiftUI identity is
/// structural: a view keyed `%1` sitting inside a container of two children is a different view from
/// one keyed `%1` at the top of the tree, so splitting a window and closing the split both rebuilt
/// the *surviving* pane. What a rebuild costs is not obvious from the outside, which is why this is
/// asserted on the object rather than on anything drawn — the new view starts with an empty grid, so
/// the pane's scrollback goes, and its repaint races whatever the program was drawing at that
/// instant. Closing a split left a full-screen program at the old width until the macOS window was
/// resized: tmux had sent `SIGWINCH`, the program had redrawn, and the redraw went into a view being
/// torn down.
///
/// Driven through `NSHostingView` rather than by inspecting the layout arithmetic, because the
/// arithmetic was never wrong. The question is what SwiftUI does with it.
@MainActor
final class PaneIdentityTests: XCTestCase {

    /// Layouts captured from tmux 3.7b, checksums and all — `TmuxWindow.apply` verifies them (R3.5),
    /// so a hand-written approximation would be rejected and the window would render nothing.
    private let onePane = "aafd,120x40,0,0,0"
    private let twoPanes = "f91d,120x40,0,0{60x40,0,0,0,59x40,61,0,1}"

    private func window(layout: String, panes: [String]) -> TmuxWindow {
        var window = TmuxWindow(id: "@0", name: "shell")
        window.panes = panes.map { TmuxPane(id: $0, command: "zsh") }
        window.activePaneId = panes.last
        XCTAssertEqual(window.apply(layoutString: layout), .applied, "fixture layout was rejected")
        return window
    }

    private func container(_ window: TmuxWindow, service: SessionService) -> TerminalContainerView {
        TerminalContainerView(
            hostId: "local",
            window: window,
            service: service,
            focusedPaneId: .constant(nil),
            owner: UUID(),
            liveResize: LiveResizeGate()
        )
    }

    /// Every `TerminalView` in the hierarchy, by the pane id its accessibility label carries.
    private func surfaces(in view: NSView) -> [String: TerminalView] {
        var found: [String: TerminalView] = [:]
        for subview in view.subviews {
            if let terminal = subview as? TerminalView,
               let label = terminal.accessibilityLabel(),
               let paneId = label.split(separator: " ").last {
                found[String(paneId)] = terminal
            }
            found.merge(surfaces(in: subview)) { current, _ in current }
        }
        return found
    }

    private func hosting(_ window: TmuxWindow, service: SessionService) -> NSHostingView<TerminalContainerView> {
        let view = NSHostingView(rootView: container(window, service: service))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testSplittingAWindowKeepsTheSurvivingPanesSurface() throws {
        let service = SessionService()
        let view = hosting(window(layout: onePane, panes: ["%0"]), service: service)
        let before = try XCTUnwrap(surfaces(in: view)["%0"], "the single pane never got a surface")

        view.rootView = container(window(layout: twoPanes, panes: ["%0", "%1"]), service: service)
        view.layoutSubtreeIfNeeded()

        let after = surfaces(in: view)
        XCTAssertEqual(after.count, 2, "the split should add a surface, not replace the tree")
        XCTAssertTrue(
            after["%0"] === before,
            "splitting rebuilt the pane that was split; its scrollback and any output in flight go with it"
        )
    }

    /// The reported case, and the one that shows: closing a split leaves the survivor holding the
    /// grid it had, so a program that redrew on tmux's `SIGWINCH` drew into a view that no longer
    /// existed.
    func testClosingASplitKeepsTheSurvivingPanesSurface() throws {
        let service = SessionService()
        let view = hosting(window(layout: twoPanes, panes: ["%0", "%1"]), service: service)
        let before = try XCTUnwrap(surfaces(in: view)["%0"], "the split window never got surfaces")

        view.rootView = container(window(layout: onePane, panes: ["%0"]), service: service)
        view.layoutSubtreeIfNeeded()

        let after = surfaces(in: view)
        XCTAssertEqual(after.count, 1, "the closed pane's surface is still in the hierarchy")
        XCTAssertTrue(
            after["%0"] === before,
            "closing a pane rebuilt the surviving one, which is the resize that never arrives"
        )
    }

    /// …and the surface that survives has to *grow*, which is the half the user sees.
    ///
    /// Asserted as a ratio rather than against tmux's 120 columns, because the emulator's grid comes
    /// from its **frame**: SwiftTerm re-derives cols and rows in `setFrameSize`, so the last word
    /// belongs to the layout and not to the `resize(cols:rows:)` this view hands it. The two agree in
    /// the running app by construction — §3.3 asks tmux for `frame ÷ cell` in the first place — but
    /// not here, where the hosting view is an arbitrary 900 points wide. What that leaves worth
    /// asserting is the thing that was broken: the pane that keeps its surface takes the whole width
    /// when the split beside it closes, instead of staying at half of it while the program in it
    /// redraws at full width.
    func testTheSurvivingPaneGrowsIntoTheSpace() throws {
        let service = SessionService()
        let view = hosting(window(layout: twoPanes, panes: ["%0", "%1"]), service: service)
        let surface = try XCTUnwrap(surfaces(in: view)["%0"])
        let split = surface.getTerminal().cols
        XCTAssertGreaterThan(split, 1)

        view.rootView = container(window(layout: onePane, panes: ["%0"]), service: service)
        view.layoutSubtreeIfNeeded()

        // Half the window to all of it: the fixture's two panes are an even split.
        XCTAssertEqual(
            Double(surface.getTerminal().cols), Double(split) * 2, accuracy: 2,
            "the pane kept the width it had inside the split — a program redrawing at full width wraps"
        )
    }
}
