import SwiftUI
import tetmuxCore

/// F4.38 — what each host colour looks like on the Mac.
///
/// Fixed values, not system colours, and the same in light and dark — a deliberate exception to §7's
/// "composited from system colours". The host chip puts white text on this colour in both
/// appearances, so every value has to keep white text at 4.5:1 or better in both, and the system's
/// `.teal`, `.green` and `.yellow` brighten in dark mode until white on them is unreadable. A colour
/// that stays put is also the point: it is a name for a machine, and a name should not change with
/// the time of day.
extension HostColor {
    var swatch: Color {
        switch self {
        case .blue: return Color(red: 0x25 / 255, green: 0x63 / 255, blue: 0xC9 / 255)
        case .teal: return Color(red: 0x0D / 255, green: 0x7A / 255, blue: 0x6F / 255)
        case .green: return Color(red: 0x2F / 255, green: 0x7D / 255, blue: 0x32 / 255)
        case .ochre: return Color(red: 0x8A / 255, green: 0x6A / 255, blue: 0x00 / 255)
        case .orange: return Color(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x0A / 255)
        case .purple: return Color(red: 0x7C / 255, green: 0x3A / 255, blue: 0xED / 255)
        case .pink: return Color(red: 0xBE / 255, green: 0x18 / 255, blue: 0x5D / 255)
        case .graphite: return Color(red: 0x52 / 255, green: 0x52 / 255, blue: 0x5B / 255)
        case .red: return Color(red: 0xC0 / 255, green: 0x26 / 255, blue: 0x2D / 255)
        }
    }
}

/// The host's name in its colour: what the title bar shows under the session name for a coloured
/// host, in place of the grey subtitle a local one keeps.
struct HostChip: View {
    let name: String
    let color: HostColor

    var body: some View {
        Text(name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.swatch))
    }
}

/// The band under the toolbar that says "remote" before anything is read (F4.38). Decoration only:
/// the chip carries the name, and VoiceOver reads the name from the title.
struct HostLine: View {
    let color: HostColor

    var body: some View {
        Rectangle()
            .fill(color.swatch)
            .frame(height: 3)
            .accessibilityHidden(true)
    }
}
