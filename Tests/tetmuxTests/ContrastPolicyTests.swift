import SwiftUI
import XCTest
@testable import tetmuxUI

/// Increase Contrast, asserted as *direction* rather than as numbers.
///
/// The numbers are a design judgement and will be retuned; what must not change is that every rule
/// moves the same way. The failure this guards against is the quiet one: a site added later that
/// takes the standard value in both branches, or a value nudged until "increased" is no longer the
/// higher of the two — either leaves the preference switched on and doing nothing, which is
/// indistinguishable from it not being implemented.
final class ContrastPolicyTests: XCTestCase {

    func testEveryWashGetsStrongerRatherThanWeaker() {
        XCTAssertGreaterThan(
            opacity(of: ContrastPolicy.selectionFill(.increased)),
            opacity(of: ContrastPolicy.selectionFill(.standard))
        )
        XCTAssertGreaterThan(
            opacity(of: ContrastPolicy.hoverFill(.increased)),
            opacity(of: ContrastPolicy.hoverFill(.standard))
        )
        XCTAssertGreaterThan(
            opacity(of: ContrastPolicy.hairline(.increased)),
            opacity(of: ContrastPolicy.hairline(.standard))
        )
        XCTAssertGreaterThan(
            opacity(of: ContrastPolicy.bannerFill(.increased, .orange)),
            opacity(of: ContrastPolicy.bannerFill(.standard, .orange))
        )
    }

    /// Selection is the one signal that gets a second channel rather than only a louder first one:
    /// the accent wash can land close to the ground for some accents, and a border cannot.
    func testSelectionGainsABorderItDoesNotOtherwiseHave() {
        XCTAssertEqual(ContrastPolicy.selectionBorder(.standard), .clear)
        XCTAssertNotEqual(ContrastPolicy.selectionBorder(.increased), .clear)
    }

    /// Dimming a pane is dimming terminal text, which is the thing the user is reading. With the
    /// preference on it stops entirely — and the frame around the focused pane takes over the job,
    /// which is why it has to get stronger in the same breath.
    func testAnUnfocusedPaneStopsBeingDimmedAndTheFrameTakesOver() {
        XCTAssertEqual(ContrastPolicy.inactivePaneOpacity(.increased, standard: 0.72), 1)
        XCTAssertEqual(ContrastPolicy.inactivePaneOpacity(.standard, standard: 0.72), 0.72)

        XCTAssertGreaterThan(
            ContrastPolicy.paneBorderSaturation(.increased),
            ContrastPolicy.paneBorderSaturation(.standard)
        )
        XCTAssertGreaterThan(
            ContrastPolicy.paneBorderWidth(.increased),
            ContrastPolicy.paneBorderWidth(.standard)
        )
    }

    /// Recessed text comes back toward legible without coming all the way back: at 1 it would stop
    /// saying "not now", which is the thing it is there to say.
    func testRecessedTextIsRaisedButNotErased() {
        let raised = ContrastPolicy.recessedOpacity(.increased, standard: 0.35)
        XCTAssertGreaterThan(raised, 0.35)
        XCTAssertLessThan(raised, 1.0)
        XCTAssertEqual(ContrastPolicy.recessedOpacity(.standard, standard: 0.35), 0.35)
    }

    /// The confirmation's footnote — what tmux does and does not know about an attached client — is
    /// the faintest text in the application, and a caveat nobody can read is a caveat that is not
    /// there. It comes forward without becoming body text.
    func testFootnoteTextComesForward() {
        let increased = opacity(of: ContrastPolicy.footnoteColor(.increased))
        let standard = opacity(of: ContrastPolicy.footnoteColor(.standard))
        XCTAssertGreaterThan(increased, standard)
        XCTAssertLessThan(increased, 1.0)
    }

    /// A caller that is already at or above the floor must not be pulled *down* by asking.
    func testAlreadyLegibleValuesAreNotLowered() {
        XCTAssertEqual(ContrastPolicy.recessedOpacity(.increased, standard: 0.95), 0.95)
    }

    /// `Color` has no public alpha, and comparing two of them says nothing about which is stronger.
    private func opacity(of color: Color) -> CGFloat {
        NSColor(color).usingColorSpace(.sRGB)?.alphaComponent ?? -1
    }
}

/// Differentiate Without Color, which unlike Increase Contrast has no shared numbers to centralise:
/// the replacement channel is necessarily different at every site — a word here, a stroke weight
/// there — so each reads the environment and answers for itself. What is asserted is that the
/// answer differs at all, since a site that returns the same thing either way is the failure.
@MainActor
final class DifferentiateWithoutColorTests: XCTestCase {

    /// The dot is the judgement and the number is the measurement. Take the colour away and only the
    /// measurement is left, and "120 ms" answers nothing unless you already know the thresholds.
    func testTheLatencyJudgementIsAvailableInWords() {
        XCTAssertEqual(StatusBarView.rttText(12, differentiateWithoutColor: true), "12 ms · good")
        XCTAssertEqual(StatusBarView.rttText(120, differentiateWithoutColor: true), "120 ms · fair")
        XCTAssertEqual(StatusBarView.rttText(400, differentiateWithoutColor: true), "400 ms · slow")
    }

    /// The words track the same thresholds as the dot, boundaries included — a word that disagreed
    /// with the colour beside it would be worse than no word.
    func testTheWordsChangeAtTheSameThresholdsAsTheColour() {
        XCTAssertEqual(StatusBarView.rttText(49, differentiateWithoutColor: true), "49 ms · good")
        XCTAssertEqual(StatusBarView.rttText(50, differentiateWithoutColor: true), "50 ms · fair")
        XCTAssertEqual(StatusBarView.rttText(149, differentiateWithoutColor: true), "149 ms · fair")
        XCTAssertEqual(StatusBarView.rttText(150, differentiateWithoutColor: true), "150 ms · slow")
    }

    /// Off, the status bar stays the compact single line it was. The word is genuinely redundant
    /// while the colour is doing its job, which is the trade the preference exists to let a user make.
    func testTheWordIsNotAddedWhenTheColourIsDoingItsJob() {
        XCTAssertEqual(StatusBarView.rttText(12, differentiateWithoutColor: false), "12 ms")
        XCTAssertEqual(StatusBarView.rttText(400, differentiateWithoutColor: false), "400 ms")
    }
}
