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
    case copyMode
    case copyModeStartSelection
    case copyModeCopy
    case copyModeSearch

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
        // One item for both directions: what it does depends on where the pane already is, and two
        // items would leave whichever one did not apply sitting there greyed out saying nothing.
        case .copyMode: return "Enter Copy Mode"
        case .copyModeStartSelection: return "Start Selection"
        case .copyModeCopy: return "Copy Selection"
        case .copyModeSearch: return "Search Backward…"
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

    // MARK: - Text forms

    /// The order modifier symbols are written in on macOS: ⌃⌥⇧⌘, control outermost, command nearest
    /// the key. Every menu in the system does it this way, so a settings table that did not would
    /// look wrong beside the menu showing the same chord.
    private static let displayOrder: [(EventModifiers, String, String)] = [
        (.control, "⌃", "ctrl"),
        (.option, "⌥", "alt"),
        (.shift, "⇧", "shift"),
        (.command, "⌘", "cmd"),
    ]

    /// `⇧⌘W`, for anywhere a person reads it.
    public var displayString: String {
        let symbols = Self.displayOrder
            .filter { modifiers.contains($0.0) }
            .map(\.1)
            .joined()
        return symbols + String(key).uppercased()
    }

    /// `cmd+shift+w`, for `settings.json`.
    ///
    /// Words rather than `EventModifiers.rawValue`, which is what a `Codable` conformance would have
    /// produced. §2.3 chose JSON here precisely so the files can be read and edited by hand, and
    /// `{"closeWindow": 18}` is not that — nor is it stable in any sense the reader can check.
    public var storageString: String {
        let names = Self.displayOrder.filter { modifiers.contains($0.0) }.map(\.2)
        return (names + [String(key)]).joined(separator: "+")
    }

    /// Parses `storageString` back, rejecting anything it does not recognise.
    ///
    /// A `+` bound as the key survives: the components are taken with empty ones kept, so `cmd++`
    /// splits to `["cmd", "", ""]` and the empty tail is read as the character it was split on.
    public init?(storageString: String) {
        let parts = storageString.lowercased().split(
            separator: "+", omittingEmptySubsequences: false
        ).map(String.init)
        guard parts.count >= 2 else { return nil }

        var modifiers: EventModifiers = []
        for name in parts.dropLast() where !name.isEmpty {
            guard let match = Self.displayOrder.first(where: { $0.2 == name }) else { return nil }
            modifiers.insert(match.0)
        }
        let tail = parts[parts.count - 1]
        // An empty tail is only ever the `+` that the split consumed.
        let keyText = tail.isEmpty ? "+" : tail
        guard keyText.count == 1, let key = keyText.first else { return nil }
        guard !modifiers.isEmpty else { return nil }

        self.key = key
        self.modifiers = modifiers
    }

    /// The chord an `NSEvent` carries, or `nil` for a key that cannot be part of one.
    ///
    /// `charactersIgnoringModifiers` deliberately, and lowercased: ⇧⌘W arrives with the character
    /// `W` and ⌘⇧= arrives as `+` on some layouts, and a keymap that stored what the shift key did
    /// to the character would never match the event it was recorded from.
    public init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let character = event.charactersIgnoringModifiers?.lowercased().first,
              !character.isNewline else { return nil }
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        guard !modifiers.isEmpty else { return nil }
        self.key = character
        self.modifiers = modifiers
    }
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
        // tmux's own `prefix [`, in Cmd space. Not ⌘C, which is Copy — and copy mode is the thing
        // you enter *before* copying, so taking the Copy chord for it would be exactly backwards.
        .copyMode: KeyBinding("[", [.command, .control]),
        // tmux's own emacs copy table marks with `C-Space`, and that is the chord this wants — but a
        // `KeyBinding` is a character, so it would render as `⌃⌘` followed by nothing in the menu and
        // in the settings table, which is a shortcut nobody can read back. `S` for selection instead.
        .copyModeStartSelection: KeyBinding("s", [.command, .control]),
        // The one item that really is Copy: it ends with the selection on the Mac's pasteboard, which
        // is what ⌘C means everywhere. Available only in copy mode, where SwiftTerm has no selection
        // of its own for the ordinary ⌘C to act on.
        .copyModeCopy: KeyBinding("c", [.command, .control]),
        // ⌘F is SwiftTerm's local find bar, which searches what the emulator is holding. This is
        // tmux's search, which reaches the history the emulator never received.
        .copyModeSearch: KeyBinding("f", [.command, .control]),
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

    // MARK: - Editing (F4.19)

    /// What else is already on this chord, if anything.
    ///
    /// The check has to exist because `shortcut(for:)` resolves a tie by rawValue order, which is a
    /// tiebreak and not an answer: with two commands on ⌘D one of them silently stops working and
    /// which one depends on the spelling of an enum case. So a duplicate is refused at the point of
    /// being typed rather than resolved afterwards.
    public func shortcut(boundTo binding: KeyBinding, excluding shortcut: ApplicationShortcut? = nil) -> ApplicationShortcut? {
        bindings.first { $0.key != shortcut && $0.value == binding }?.key
    }

    /// Whether a chord may be bound at all.
    ///
    /// ⌘ is required, and that is a design constraint rather than a limitation (F4.19/F4.20). The
    /// whole default set lives in `Cmd` space so that everything else — every bare `Ctrl` chord,
    /// readline, Emacs, tmux's own prefix — reaches the pane untouched. A rebind that took `Ctrl+K`
    /// would take kill-line away from every shell on every host, which is the one thing the keymap
    /// policy exists to promise will not happen.
    public static func isBindable(_ binding: KeyBinding) -> Bool {
        binding.modifiers.contains(.command)
    }

    /// Only what the user changed, keyed by the shortcut's raw value.
    ///
    /// The difference from the defaults rather than the whole map, so a later change to a default
    /// binding reaches everyone who never touched it — the alternative freezes today's defaults into
    /// every settings file that has ever been written. An explicit `null` is a shortcut deliberately
    /// unbound, which is not the same as one that was never edited.
    public var overrides: [String: String?] {
        var result: [String: String?] = [:]
        for shortcut in ApplicationShortcut.allCases {
            let mine = bindings[shortcut]
            let standard = Self.default.bindings[shortcut]
            guard mine != standard else { continue }
            // `updateValue`, not a subscript assignment. Assigning `nil` through the subscript of a
            // `[String: String?]` *removes* the key rather than storing a null, so a deliberately
            // unbound shortcut would be indistinguishable from one nobody touched — and would come
            // back with its default chord on the next launch.
            result.updateValue(mine?.storageString, forKey: shortcut.rawValue)
        }
        return result
    }

    /// The defaults with `overrides` applied. Anything unparseable is ignored rather than fatal: this
    /// comes from a file the user is invited to edit, and one bad line must not cost the whole keymap.
    public static func applying(overrides: [String: String?]) -> KeymapPolicy {
        var policy = KeymapPolicy.default
        for (name, chord) in overrides {
            guard let shortcut = ApplicationShortcut(rawValue: name) else { continue }
            guard let chord else {
                policy.bindings[shortcut] = nil
                continue
            }
            guard let binding = KeyBinding(storageString: chord), isBindable(binding) else { continue }
            policy.bindings[shortcut] = binding
        }
        return policy
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
