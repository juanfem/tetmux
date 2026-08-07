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
    case newSession
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
        // **A tmux window is a "Tab" everywhere in the UI; "Window" names the macOS window and
        // nothing else.** Before this the qualifier was applied unevenly — "New tmux Window" and
        // "Next tmux Window" but a bare "Close Window…" and "Rename Window…" for the same object —
        // and worse, "New Window" meant the *macOS* window here and the *tmux* one in the sidebar's
        // session menu: the same two words for opposite objects, two clicks apart. Naming the thing
        // the user is actually looking at settles it without a qualifier anywhere.
        //
        // "New Tab" and "Close Tab" are titles AppKit manages itself, but only **under automatic
        // window tabbing**, which is off here (`NSWindow.allowsAutomaticWindowTabbing = false`, in
        // AppMain). Verified against the running app rather than assumed: File carries exactly one
        // "New Tab" at ⌘T and Session one "Close Tab…" at ⇧⌘W, both enabled, and AppKit injects no
        // tab items of its own — no "Show Tab Bar", no "Merge All Windows". If that flag ever goes
        // back to true, these two titles are the first thing to re-check.
        case .newAppWindow: return "New Window"
        case .newSession: return "New Session"
        case .newWindow: return "New Tab"
        case .closeWindow: return "Close Tab…"
        case .closePane: return "Close Pane"
        case .splitRight: return "Split Right"
        case .splitDown: return "Split Down"
        case .zoomPane: return "Zoom Pane"
        case .focusNextPane: return "Select Next Pane"
        case .focusPreviousPane: return "Select Previous Pane"
        case .nextWindow: return "Next Tab"
        case .previousWindow: return "Previous Tab"
        case .find: return "Find…"
        case .increaseFontSize: return "Bigger"
        case .decreaseFontSize: return "Smaller"
        case .resetFontSize: return "Actual Size"
        case .paste: return "Paste"
        case .sendNextLiteral: return "Send Next Chord Literally"
        case .renameWindow: return "Rename Tab…"
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

    /// The keys that have no glyph of their own, named the way macOS names them.
    ///
    /// Every one of these is a character `charactersIgnoringModifiers` really produces, so every one
    /// of them is recordable today — and without this table they were rendered by uppercasing the
    /// character, which for the space key is a chord ending in nothing and for an arrow key is a
    /// private-use codepoint the font draws as a box. A shortcut nobody can read back is a shortcut
    /// nobody can check, which is most of what the settings table is for.
    ///
    /// macOS spells the space key out — System Settings shows Spotlight's chord as `⌘Space` — and
    /// uses a symbol for the rest, which is what the menus themselves do. The storage names are for
    /// `settings.json`, which §2.3 chose so the file can be read and edited by hand: `cmd+ctrl+space`
    /// says what it means, and a literal trailing space would not survive a person looking at it.
    private static let namedKeys: [(key: Character, display: String, storage: String)] = [
        (" ", "Space", "space"),
        ("\t", "⇥", "tab"),
        ("\u{1b}", "⎋", "escape"),
        ("\u{7f}", "⌫", "delete"),
        // AppKit's function-key block. `NSUpArrowFunctionKey` and its neighbours, written as scalars
        // so the table stays a table.
        (Character(UnicodeScalar(0xF700)!), "↑", "up"),
        (Character(UnicodeScalar(0xF701)!), "↓", "down"),
        (Character(UnicodeScalar(0xF702)!), "←", "left"),
        (Character(UnicodeScalar(0xF703)!), "→", "right"),
        (Character(UnicodeScalar(0xF729)!), "↖", "home"),
        (Character(UnicodeScalar(0xF72B)!), "↘", "end"),
        (Character(UnicodeScalar(0xF72C)!), "⇞", "pageup"),
        (Character(UnicodeScalar(0xF72D)!), "⇟", "pagedown"),
    ]

    /// `⇧⌘W`, or `⌃⌘Space`, for anywhere a person reads it.
    public var displayString: String {
        let symbols = Self.displayOrder
            .filter { modifiers.contains($0.0) }
            .map(\.1)
            .joined()
        let name = Self.namedKeys.first { $0.key == key }?.display ?? String(key).uppercased()
        return symbols + name
    }

    /// `cmd+shift+w`, for `settings.json`.
    ///
    /// Words rather than `EventModifiers.rawValue`, which is what a `Codable` conformance would have
    /// produced. §2.3 chose JSON here precisely so the files can be read and edited by hand, and
    /// `{"closeWindow": 18}` is not that — nor is it stable in any sense the reader can check.
    public var storageString: String {
        let names = Self.displayOrder.filter { modifiers.contains($0.0) }.map(\.2)
        let keyText = Self.namedKeys.first { $0.key == key }?.storage ?? String(key)
        return (names + [keyText]).joined(separator: "+")
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
        // A name first, then a literal character. The two cannot collide: every name is longer than
        // one character, and the check below rejects anything longer than one that is not a name.
        let key: Character
        if let named = Self.namedKeys.first(where: { $0.storage == keyText }) {
            key = named.key
        } else if keyText.count == 1, let single = keyText.first {
            key = single
        } else {
            return nil
        }
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
        // ⇧⌘N beside ⌘N, which is the relationship: a session is the bigger unit and the macOS
        // window is the smaller one. Free in this app and unclaimed by macOS in a terminal — it is
        // New Folder in Finder and nothing here.
        .newSession: KeyBinding("n", [.command, .shift]),
        .newWindow: KeyBinding("t"),
        // **⌘W closes the tab and ⇧⌘W the macOS window**, which is what they do in Safari, Chrome,
        // Terminal.app and iTerm2 — the apps whose muscle memory anyone arrives here with. They used
        // to be the other way round, ordered by blast radius so the easiest chord destroyed nothing.
        // That argument is real but it lost: the cost of being alone in the inversion is paid on
        // every ⌘W by everyone, while the confirmation (F4.10) already stands between ⌘W and
        // anything irreversible.
        //
        // What makes it stick is `CommandGroup(replacing: .saveItem)` in `menuCommands`, which takes
        // AppKit's File ▸ Close out and supplies our own on ⇧⌘W. Mutating the `NSMenuItem` instead —
        // setting `keyEquivalentModifierMask` on `performClose:` at launch and again on every
        // activation — was tried first and does **not** hold: SwiftUI rebuilds the File menu and
        // restores ⌘W, where it collides with this binding and loses its key character, leaving the
        // macOS window with no close chord at all. Measured, both times.
        .closeWindow: KeyBinding("w"),
        // ⌃⌘W, and **not** ⌥⌘W, which AppKit owns: `Close All` is an automatic alternate of `Close`
        // and holds ⌥⌘W in the File menu, which is searched before this one. The duplicate did not
        // fail loudly — AppKit kept the modifier mask on our item and dropped the key character, so
        // the Keys tab and the README both advertised a chord that fired Close All instead. Measured
        // before the fix: ⌥⌘W with two panes in one window left the panes at two and the windows at
        // zero. Anything added to the ⌘W family from here needs checking against the *running* menu
        // bar, not against this file.
        .closePane: KeyBinding("w", [.command, .control]),
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
        // tmux's own emacs copy table marks with `C-Space`, and so does every emacs-descended editor;
        // this is that chord in `Cmd` space. It reads as `⌃⌘Space` because `namedKeys` spells the
        // space key out, which is what macOS does with it.
        .copyModeStartSelection: KeyBinding(" ", [.command, .control]),
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
