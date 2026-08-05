import AppKit
import SwiftTerm

/// F4.21 — `⌥⌘V`, after which the next chord reaches the pane instead of the application.
///
/// This is the only place in the app that intercepts a key event, and it exists because the ordinary
/// mechanism cannot be escaped from. Every other binding is a SwiftUI `keyboardShortcut` on a menu
/// item, which AppKit resolves in `performKeyEquivalent` before any view is offered the event — so
/// there is no view-level hook that could decide to let ⌘K through to a pane running fzf. A local
/// `NSEvent` monitor is the one thing that runs *earlier*: `NSApplication.sendEvent` calls monitors
/// before it dispatches key equivalents, and returning `nil` from one consumes the event outright.
///
/// It is deliberately not a second keymap. `KeymapPolicy.shortcut(for:literalEscapeActive:)` — which
/// has existed unused since the first keymap — is what decides whether an event is the escape chord,
/// so F4.22's "a single policy module is consulted by every surface" still holds with this surface
/// added: the monitor asks the policy and does no matching of its own.
@MainActor
final class KeyEventMonitor {
    private weak var model: AppModel?
    /// `nonisolated(unsafe)` for the same reason `ModifierKeyMonitor`'s is: written once in `init`,
    /// read once in `deinit`, and `NSEvent.removeMonitor` is safe from either.
    nonisolated(unsafe) private var monitor: Any?

    init(model: AppModel) {
        self.model = model
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // The decision is made inside the isolation and only a `Bool` crosses back out: an
            // `NSEvent` is not `Sendable`, so returning one through `assumeIsolated` does not
            // compile even though it never leaves the main thread.
            var consumed = false
            MainActor.assumeIsolated { consumed = self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Whether the event was consumed here and must not continue to the menu.
    private func handle(_ event: NSEvent) -> Bool {
        guard let model else { return false }

        if model.literalEscapeArmed {
            model.literalEscapeArmed = false
            // Only a pane can receive a literal chord. With anything else focused — a rename sheet,
            // the launcher — the mode was armed against something that cannot use it, so the event
            // goes back to its ordinary route rather than being swallowed.
            guard let pane = Self.focusedPane() else { return false }
            // Delivered straight to the pane rather than let through. Letting it through would hand
            // it to the menu, which is the interception this whole mechanism exists to get around:
            // ⌘V would paste instead of reaching the shell. SwiftTerm's `keyDown` turns it into the
            // byte sequence and hands it to the delegate, which sends it as `send-keys`.
            pane.keyDown(with: event)
            return true
        }

        guard model.keymap.shortcut(for: event) == .sendNextLiteral else { return false }
        // Nothing to arm the escape *for* when no pane has focus, and consuming ⌥⌘V there would make
        // the chord look broken rather than inapplicable.
        guard Self.focusedPane() != nil else { return false }
        model.literalEscapeArmed = true
        return true
    }

    /// The pane the keyboard is pointing at, or `nil` when the first responder is not one.
    private static func focusedPane() -> TerminalView? {
        NSApp.keyWindow?.firstResponder as? TerminalView
    }
}
