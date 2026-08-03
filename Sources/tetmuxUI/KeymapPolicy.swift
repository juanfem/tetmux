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
    case newWindow
    case closeWindow
    case closePane
    case splitRight
    case splitDown
    case paste
    case sendNextLiteral
    case renameWindow
    case renameSession

    public var title: String {
        switch self {
        case .launcher: return "Open Launcher…"
        case .newWindow: return "New Window"
        case .closeWindow: return "Close Window…"
        case .closePane: return "Close Pane"
        case .splitRight: return "Split Right"
        case .splitDown: return "Split Down"
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
        .newWindow: KeyBinding("t"),
        .closeWindow: KeyBinding("w", [.command, .shift]),
        .splitRight: KeyBinding("d"),
        .splitDown: KeyBinding("d", [.command, .shift]),
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
