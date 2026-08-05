import AppKit
import SwiftTerm

/// A pane's colours: foreground, background, cursor, and the sixteen ANSI slots.
///
/// The second-most-adjusted terminal preference after font size, and the only part of the
/// application's appearance that is *not* the system's to decide. §7's rule is the line: the chrome
/// composites from `controlAccentColor` and hierarchical styles so it follows the system appearance,
/// and this applies to pane **content** only. A tab bar that changed colour with the terminal scheme
/// would be an application pretending to be a terminal.
///
/// Shipped as a small set of named schemes rather than nineteen colour wells. Nineteen wells is a
/// afternoon of fiddling to arrive at something worse than any of these, and the ones here are the
/// palettes people actually name when asked.
public struct TerminalColorScheme: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Ordinary text, and what an unstyled cell is drawn in.
    public let foreground: RGB
    public let background: RGB
    public let cursor: RGB
    /// The sixteen ANSI slots, in tmux's own order: black, red, green, yellow, blue, magenta, cyan,
    /// white, then the eight bright variants. Programs address these by number, so the order is the
    /// contract and not a preference.
    public let ansi: [RGB]

    /// 8 bits per channel, which is how every palette in the world is written down.
    ///
    /// Deliberately not `NSColor`: a scheme is a value that gets compared, stored in `UserDefaults`
    /// and diffed against the previous one, and `NSColor` is none of those things reliably — two
    /// colours that draw identically can differ as objects, which would make every theme write look
    /// like a change.
    public struct RGB: Equatable, Sendable {
        public let r: UInt8, g: UInt8, b: UInt8

        public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
            (self.r, self.g, self.b) = (r, g, b)
        }

        /// `#rrggbb`, which is what the scheme table shows and what a person recognises.
        public init?(hex: String) {
            var text = hex
            if text.hasPrefix("#") { text.removeFirst() }
            guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
            self.init(UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff))
        }

        /// SwiftTerm's `Color` is 16 bits per channel; 8-bit `n` scales to `n * 257`, which maps
        /// 0xff to 0xffff exactly rather than to 0xff00.
        public var terminalColor: Color {
            Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
        }

        public var nsColor: NSColor {
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    /// The system scheme: what a pane looked like before there were any.
    ///
    /// `nil` colours rather than a copy of the current appearance's values, because the point of it
    /// is to *follow* — light and dark, and a change while the app is running. Everything else here
    /// is a fixed palette by definition; this one is the absence of one.
    public static let system = TerminalColorScheme(
        id: "system",
        name: "System",
        foreground: RGB(0, 0, 0), background: RGB(255, 255, 255), cursor: RGB(0, 0, 0),
        ansi: defaultAnsi
    )

    public var followsSystemAppearance: Bool { id == Self.system.id }

    /// xterm's own sixteen, which is what a program means by "colour 1" unless told otherwise.
    static let defaultAnsi: [RGB] = [
        RGB(0, 0, 0), RGB(0xcd, 0, 0), RGB(0, 0xcd, 0), RGB(0xcd, 0xcd, 0),
        RGB(0, 0, 0xee), RGB(0xcd, 0, 0xcd), RGB(0, 0xcd, 0xcd), RGB(0xe5, 0xe5, 0xe5),
        RGB(0x7f, 0x7f, 0x7f), RGB(0xff, 0, 0), RGB(0, 0xff, 0), RGB(0xff, 0xff, 0),
        RGB(0x5c, 0x5c, 0xff), RGB(0xff, 0, 0xff), RGB(0, 0xff, 0xff), RGB(0xff, 0xff, 0xff),
    ]

    private static func palette(_ hexes: [String]) -> [RGB] {
        // A malformed entry is a programming error in a literal below, not user input, so it falls
        // back to the xterm slot rather than failing the launch.
        hexes.enumerated().map { RGB(hex: $1) ?? defaultAnsi[$0] }
    }

    public static let solarizedDark = TerminalColorScheme(
        id: "solarized-dark", name: "Solarized Dark",
        foreground: RGB(hex: "839496")!, background: RGB(hex: "002b36")!, cursor: RGB(hex: "93a1a1")!,
        ansi: palette([
            "073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
            "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3",
        ])
    )

    public static let solarizedLight = TerminalColorScheme(
        id: "solarized-light", name: "Solarized Light",
        foreground: RGB(hex: "657b83")!, background: RGB(hex: "fdf6e3")!, cursor: RGB(hex: "586e75")!,
        ansi: palette([
            "073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
            "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3",
        ])
    )

    public static let nord = TerminalColorScheme(
        id: "nord", name: "Nord",
        foreground: RGB(hex: "d8dee9")!, background: RGB(hex: "2e3440")!, cursor: RGB(hex: "d8dee9")!,
        ansi: palette([
            "3b4252", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "88c0d0", "e5e9f0",
            "4c566a", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "8fbcbb", "eceff4",
        ])
    )

    public static let gruvboxDark = TerminalColorScheme(
        id: "gruvbox-dark", name: "Gruvbox Dark",
        foreground: RGB(hex: "ebdbb2")!, background: RGB(hex: "282828")!, cursor: RGB(hex: "ebdbb2")!,
        ansi: palette([
            "282828", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "a89984",
            "928374", "fb4934", "b8bb26", "fabd2f", "83a598", "d3869b", "8ec07c", "ebdbb2",
        ])
    )

    public static let tomorrowNight = TerminalColorScheme(
        id: "tomorrow-night", name: "Tomorrow Night",
        foreground: RGB(hex: "c5c8c6")!, background: RGB(hex: "1d1f21")!, cursor: RGB(hex: "c5c8c6")!,
        ansi: palette([
            "1d1f21", "cc6666", "b5bd68", "f0c674", "81a2be", "b294bb", "8abeb7", "c5c8c6",
            "969896", "cc6666", "b5bd68", "f0c674", "81a2be", "b294bb", "8abeb7", "ffffff",
        ])
    )

    /// Everything the settings pane offers, System first because it is the default and the way back.
    public static let all: [TerminalColorScheme] = [
        .system, .solarizedDark, .solarizedLight, .nord, .gruvboxDark, .tomorrowNight,
    ]

    public static func named(_ id: String) -> TerminalColorScheme {
        all.first { $0.id == id } ?? .system
    }
}
