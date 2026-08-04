import AppKit
import SwiftUI

/// F4.19/F4.22 — the single place that decides which chords the application takes and which reach
/// the pane. Every surface consults this; no view invents its own key handling.
///
/// The whole default set lives in `Cmd` space. That is the one real simplification of being
/// macOS-only: `Cmd` chords do not collide with readline, Emacs, or tmux's prefix, so everything
/// else — including every bare `Ctrl` chord — forwards to the pane untouched.
public enum ApplicationShortcut: String, CaseIterable, Hashable, Sendable {
    case launcher
    case newAppWindow
    case newWindow
    case closeWindow
    case closePane
    case splitRight
    case splitDown
    case zoomPane
    case focusNextPane
    case focusPreviousPane
    case nextWindow
    case previousWindow
    case find
    case increaseFontSize
    case decreaseFontSize
    case resetFontSize
    case paste
    case sendNextLiteral
    case renameWindow
    case renameSession

    public var title: String {
        switch self {
        case .launcher: return "Open Launcher…"
        // ⌘N means a window of the application in every other macOS app; it used to open a tmux
        // window here, which is what made it surprising. The tmux one keeps ⌘T and says which kind
        // of window it means.
        //
        // Deliberately not "New Tab", even though a tmux window is shown as one: AppKit manages menu
        // items by that exact title itself when automatic window tabbing is on, so a custom item
        // competing for the name is at its mercy. Naming the domain object avoids the question.
        case .newAppWindow: return "New Window"
        case .newWindow: return "New tmux Window"
        case .closeWindow: return "Close Window…"
        case .closePane: return "Close Pane"
        case .splitRight: return "Split Right"
        case .splitDown: return "Split Down"
        case .zoomPane: return "Zoom Pane"
        case .focusNextPane: return "Select Next Pane"
        case .focusPreviousPane: return "Select Previous Pane"
        case .nextWindow: return "Next tmux Window"
        case .previousWindow: return "Previous tmux Window"
        case .find: return "Find…"
        case .increaseFontSize: return "Bigger"
        case .decreaseFontSize: return "Smaller"
        case .resetFontSize: return "Actual Size"
        case .paste: return "Paste"
        case .sendNextLiteral: return "Send Next Chord Literally"
        case .renameWindow: return "Rename Window…"
        case .renameSession: return "Rename Session…"
        }
    }
}

public struct KeyBinding: Equatable, Sendable {
    public let key: Character
    public let modifiers: EventModifiers

    public init(_ key: Character, _ modifiers: EventModifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    public var keyEquivalent: KeyEquivalent { KeyEquivalent(key) }
}

public struct KeymapPolicy: Sendable {
    private var bindings: [ApplicationShortcut: KeyBinding]

    /// The documented default map. `Cmd+K` for the launcher is safe precisely because `Ctrl+K`
    /// (kill-line) is untouched (F4.20).
    public static let `default` = KeymapPolicy(bindings: [
        .launcher: KeyBinding("k"),
        .newAppWindow: KeyBinding("n"),
        .newWindow: KeyBinding("t"),
        .closeWindow: KeyBinding("w", [.command, .shift]),
        // Declared since the first keymap and never bound, so its menu item rendered with no chord.
        // ⌥⌘W rather than anything nearer ⌘W: the three of them are a window of the application, a
        // tmux window, and one pane, in increasing order of how much they take with them.
        .closePane: KeyBinding("w", [.command, .option]),
        .splitRight: KeyBinding("d"),
        .splitDown: KeyBinding("d", [.command, .shift]),
        // tmux's own `prefix z`, in Cmd space. Not ⌘Z, which is Undo everywhere in macOS.
        .zoomPane: KeyBinding("z", [.command, .shift]),
        // The bracket pair macOS uses for "move within the document" — Safari and Xcode both.
        .focusNextPane: KeyBinding("]", [.command, .option]),
        .focusPreviousPane: KeyBinding("[", [.command, .option]),
        .nextWindow: KeyBinding("]", [.command, .shift]),
        .previousWindow: KeyBinding("[", [.command, .shift]),
        .find: KeyBinding("f"),
        // `+` is what the key is labelled and `=` is what it sends unshifted; binding the unshifted
        // one is what every Mac application does, so ⌘= and ⌘+ both work.
        .increaseFontSize: KeyBinding("="),
        .decreaseFontSize: KeyBinding("-"),
        .resetFontSize: KeyBinding("0"),
        .paste: KeyBinding("v"),
        .sendNextLiteral: KeyBinding("v", [.command, .option]),
        // tmux's own rename bindings are prefix-based (`prefix ,` and `prefix $`), which never reach
        // us — the pane sees the prefix. These are the GUI equivalents and stay in Cmd space.
        .renameWindow: KeyBinding("r"),
        .renameSession: KeyBinding("r", [.command, .shift]),
    ])

    public init(bindings: [ApplicationShortcut: KeyBinding]) {
        self.bindings = bindings
    }

    public func binding(for shortcut: ApplicationShortcut) -> KeyBinding? {
        bindings[shortcut]
    }

    public mutating func rebind(_ shortcut: ApplicationShortcut, to binding: KeyBinding?) {
        bindings[shortcut] = binding
    }

    /// Which application shortcut, if any, an `NSEvent` should be taken as.
    ///
    /// `literalEscapeActive` is F4.21: after `Cmd+Alt+V` the next chord passes through verbatim, so
    /// any binding here can still reach the pane.
    public func shortcut(for event: NSEvent, literalEscapeActive: Bool = false) -> ApplicationShortcut? {
        guard !literalEscapeActive else { return nil }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return nil }
        guard let character = event.charactersIgnoringModifiers?.lowercased().first else { return nil }
        let modifiers = Self.eventModifiers(from: flags)

        // Exact modifier match, so Cmd+Shift+D never resolves to the Cmd+D binding.
        return bindings
            .filter { $0.value.key == character && $0.value.modifiers == modifiers }
            .min { $0.key.rawValue < $1.key.rawValue }?
            .key
    }

    private static func eventModifiers(from flags: NSEvent.ModifierFlags) -> EventModifiers {
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}

extension View {
    /// Applies the policy's binding for a shortcut, so the menus and the interception rules can
    /// never drift apart.
    @ViewBuilder
    func keyboardShortcut(_ shortcut: ApplicationShortcut, in policy: KeymapPolicy) -> some View {
        if let binding = policy.binding(for: shortcut) {
            self.keyboardShortcut(binding.keyEquivalent, modifiers: binding.modifiers)
        } else {
            self
        }
    }
}
