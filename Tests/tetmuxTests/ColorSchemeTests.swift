import AppKit
import SwiftTerm
import XCTest
@testable import tetmuxUI

/// The pane colour schemes: the parts that are ours to get wrong.
///
/// The drawing is SwiftTerm's, so nothing here asserts a pixel. What it asserts is the handful of
/// facts a scheme has to satisfy to be usable at all — sixteen slots in the order programs address
/// them, a conversion that reaches full white, a System entry that really follows the system, and a
/// round trip through `UserDefaults` — each of which is silent when wrong.
@MainActor
final class ColorSchemeTests: XCTestCase {

    /// Programs address these by number: `\u{1b}[31m` is slot 1 and has to be red on every scheme,
    /// or `git status` prints its deletions in whatever the palette's second entry happens to be.
    /// A scheme with fifteen entries is worse than none — `installPalette` silently does nothing.
    func testEverySchemeHasSixteenAnsiSlotsInTheExpectedOrder() {
        for scheme in TerminalColorScheme.all {
            XCTAssertEqual(scheme.ansi.count, 16, "\(scheme.name) would be rejected by installPalette")

            // Slot 1 is red, 2 is green, 4 is blue — compared against *each other* rather than
            // against a rule about their own channels. Real palettes are not primaries: Gruvbox's
            // green is `98971a`, an olive whose red channel edges out its green by one, and an
            // assertion that each slot's own named channel dominates would reject a scheme that is
            // perfectly correct. What has to hold is the ordering a program depends on — the red
            // slot is redder than the green slot, and so on.
            let red = scheme.ansi[1], green = scheme.ansi[2], blue = scheme.ansi[4]
            XCTAssertGreaterThan(red.r, green.r, "\(scheme.name): slot 1 is not redder than slot 2")
            XCTAssertGreaterThan(green.g, red.g, "\(scheme.name): slot 2 is not greener than slot 1")
            XCTAssertGreaterThan(blue.b, red.b, "\(scheme.name): slot 4 is not bluer than slot 1")
        }
    }

    /// Foreground and background have to be far enough apart to read, which is the one way a
    /// hand-typed palette fails that no compiler catches.
    func testEverySchemeIsLegible() {
        for scheme in TerminalColorScheme.all where !scheme.followsSystemAppearance {
            let fg = luminance(scheme.foreground), bg = luminance(scheme.background)
            XCTAssertGreaterThan(
                abs(fg - bg), 0.25,
                "\(scheme.name) draws \(fg) on \(bg) — text that close to its background is unreadable"
            )
        }
    }

    /// 8-bit to 16-bit has to reach the ends. `n << 8` maps 0xff to 0xff00, which is a white that is
    /// not quite white and a scheme that looks subtly washed out with nothing to point at.
    func testChannelConversionReachesFullScale() {
        XCTAssertEqual(TerminalColorScheme.RGB(255, 255, 255).terminalColor.red, 0xffff)
        XCTAssertEqual(TerminalColorScheme.RGB(0, 0, 0).terminalColor.blue, 0)
        // …and the middle stays proportional rather than merely bounded.
        XCTAssertEqual(TerminalColorScheme.RGB(0x80, 0, 0).terminalColor.red, 0x8080)
    }

    func testHexParsingAcceptsWhatTheSchemesAreWrittenIn() {
        XCTAssertEqual(TerminalColorScheme.RGB(hex: "#002b36"), TerminalColorScheme.RGB(0, 0x2b, 0x36))
        XCTAssertEqual(TerminalColorScheme.RGB(hex: "002b36"), TerminalColorScheme.RGB(0, 0x2b, 0x36))
        XCTAssertNil(TerminalColorScheme.RGB(hex: "00bb"), "a short string is not a colour")
        XCTAssertNil(TerminalColorScheme.RGB(hex: "gggggg"))
    }

    /// System is the absence of a palette, not a copy of one. If it ever became fixed values the
    /// symptom would be a pane that stayed light after the user switched to dark.
    func testTheSystemSchemeIsMarkedAsFollowingTheAppearance() {
        XCTAssertTrue(TerminalColorScheme.system.followsSystemAppearance)
        for scheme in TerminalColorScheme.all where scheme.id != TerminalColorScheme.system.id {
            XCTAssertFalse(scheme.followsSystemAppearance, "\(scheme.name) claims to follow the system")
        }
        XCTAssertEqual(TerminalColorScheme.all.first?.id, TerminalColorScheme.system.id, "System comes first")
    }

    /// An id that no longer exists — a downgrade, or a hand-edited preference — has to land
    /// somewhere rather than leaving a pane with no colours at all.
    func testAnUnknownSchemeIdFallsBackToSystem() {
        XCTAssertEqual(TerminalColorScheme.named("no-such-scheme").id, TerminalColorScheme.system.id)
        XCTAssertEqual(TerminalColorScheme.named("nord").id, "nord")
    }

    /// The theme is what carries the choice, and it persists with the rest of the appearance.
    func testTheChosenSchemeSurvivesTheDefaults() {
        let suite = "tetmux.tests.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var theme = TerminalTheme.default
        XCTAssertTrue(theme.colorScheme.followsSystemAppearance, "the default pane is the system's")

        theme.colorSchemeId = TerminalColorScheme.nord.id
        theme.save(to: defaults)
        XCTAssertEqual(TerminalTheme.load(from: defaults).colorSchemeId, "nord")
        XCTAssertEqual(TerminalTheme.load(from: defaults).colorScheme.name, "Nord")
    }

    /// The scheme reaches the emulator, which is the step that would make all of the above
    /// decorative if it were missing.
    func testApplyingASchemePaintsTheView() throws {
        let view = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 200),
            font: TerminalTheme.default.resolvedFont()
        )
        TerminalPaneView.applyColors(.nord, to: view)

        let painted = try XCTUnwrap(view.nativeBackgroundColor.usingColorSpace(.sRGB))
        let wanted = try XCTUnwrap(TerminalColorScheme.nord.background.nsColor.usingColorSpace(.sRGB))
        XCTAssertEqual(painted.redComponent, wanted.redComponent, accuracy: 0.01)
        XCTAssertEqual(painted.blueComponent, wanted.blueComponent, accuracy: 0.01)
        // The palette went in as well as the two named colours — a scheme that set only foreground
        // and background would leave every coloured program drawing in xterm's defaults. Asserted
        // through the caret, which is public, plus the fact that `installColors` accepted sixteen:
        // `ansiColors` itself is internal to SwiftTerm and not ours to read.
        XCTAssertEqual(view.caretColor, TerminalColorScheme.nord.cursor.nsColor)

        // …and handing it back to the system restores the appearance-following colours.
        TerminalPaneView.applyColors(.system, to: view)
        XCTAssertEqual(view.nativeBackgroundColor, NSColor.textBackgroundColor)
    }

    /// Rec. 709 relative luminance, which is what "is this readable" means numerically.
    private func luminance(_ colour: TerminalColorScheme.RGB) -> Double {
        (0.2126 * Double(colour.r) + 0.7152 * Double(colour.g) + 0.0722 * Double(colour.b)) / 255
    }
}
