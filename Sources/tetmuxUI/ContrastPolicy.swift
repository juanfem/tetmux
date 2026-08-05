import SwiftUI

/// Increase Contrast, resolved in one place (§8, the accessibility row of the audit).
///
/// The counterpart to how Reduce Motion is handled: read the environment at the site, ask here what
/// the value should be. Centralised for the same reason `KeymapPolicy` is — the alternative is a
/// `contrast == .increased ? a : b` at a dozen call sites, each with its own numbers, drifting until
/// a selected row and a selected tab disagree about how selected they look.
///
/// The rules are all of one kind: **a signal carried by a faint wash becomes a signal carried by an
/// obvious one.** Nothing changes shape, nothing appears or disappears, and nothing moves — a user
/// who turns this on has not asked for a different application, only for one they can see. That is
/// also why the standard values here are the tuned ones from the sketch rather than round numbers:
/// this is the amplifier, not a second design.
///
/// SwiftUI's `\.colorSchemeContrast` is the signal. It is `.increased` exactly when System Settings'
/// **Increase contrast** is on, and it is already per-appearance, so nothing here has to know whether
/// the window is light or dark.
enum ContrastPolicy {

    /// The tint behind a selected row, tab, or launcher result.
    ///
    /// A 20 % accent wash over the sidebar material is a few points of luminance — enough to find
    /// when you are looking for it, easy to miss when you are not. Increased, it is a wash you cannot
    /// mistake for the row above it, and it is paired with a border below so selection survives even
    /// where the accent is close to the ground.
    static func selectionFill(_ contrast: ColorSchemeContrast) -> Color {
        Color.accentColor.opacity(contrast == .increased ? 0.45 : 0.20)
    }

    /// A stroke around the selected row, drawn only at increased contrast.
    ///
    /// Not an outline that appears from nowhere: it lands exactly on the edge of the fill that is
    /// already there, so the shape of a selected row is unchanged and only its edge becomes definite.
    static func selectionBorder(_ contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? Color.accentColor : .clear
    }

    /// A hover wash. Same argument as `selectionFill`, one step quieter because hover is transient
    /// and the pointer is already saying where it is.
    static func hoverFill(_ contrast: ColorSchemeContrast) -> Color {
        Color.primary.opacity(contrast == .increased ? 0.22 : 0.10)
    }

    /// How far something unavailable, disabled, or not-yet-connected is allowed to recede.
    ///
    /// Fading text is the cheapest way to say "not now" and the most direct thing Increase Contrast
    /// exists to undo. It is not raised to 1 — then it stops saying anything — but it stops being a
    /// legibility problem.
    static func recessedOpacity(_ contrast: ColorSchemeContrast, standard: Double) -> Double {
        contrast == .increased ? max(standard, 0.85) : standard
    }

    /// A hairline that only has to be *visible*, not decorative: panel edges, dividers between rows.
    static func hairline(_ contrast: ColorSchemeContrast) -> Color {
        Color.primary.opacity(contrast == .increased ? 0.35 : 0.08)
    }

    /// The wash behind a status banner — the connection banner's orange, the failure banner's red.
    ///
    /// These carry meaning by hue as well as by their text, so the wash has to be readable as a
    /// coloured band rather than as a tint someone might not notice at all.
    static func bannerFill(_ contrast: ColorSchemeContrast, _ base: Color) -> Color {
        base.opacity(contrast == .increased ? 0.34 : 0.14)
    }

    // MARK: - Panes

    /// How far an unfocused pane drops back when the window is split.
    ///
    /// At increased contrast it does not drop back at all. Dimming a pane is dimming *terminal text*,
    /// which is the one thing in this application a person is actually reading, and a user who has
    /// asked the system for more contrast has said as plainly as macOS lets them that they do not
    /// want it composited away. Nothing is lost by removing it, because the dim was never the focus
    /// indicator: the frame is, and it gets stronger in exchange.
    static func inactivePaneOpacity(_ contrast: ColorSchemeContrast, standard: Double) -> Double {
        contrast == .increased ? 1 : standard
    }

    /// How much of the accent's saturation the focused pane's frame keeps.
    ///
    /// Ordinarily most of it is taken out so the frame sits below the pane's own text — a permanent
    /// saturated rectangle competes with what is inside it. At increased contrast that trade is the
    /// wrong way round: the frame is now the *only* thing distinguishing the focused pane, since the
    /// dim is gone, so it takes the accent as the user chose it.
    static func paneBorderSaturation(_ contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? 1.0 : 0.30
    }

    static func paneBorderWidth(_ contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? 2 : 1
    }
}
