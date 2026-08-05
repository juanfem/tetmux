import AppKit
import SwiftUI

/// A field that captures the next chord pressed, for the keymap table (F4.19).
///
/// An `NSView` because there is no SwiftUI way to see a ⌘-chord at all. `onKeyPress` is offered only
/// the events the responder chain did not claim, and a ⌘-chord is claimed by the main menu long
/// before that — which is the whole difficulty of a recorder in an application that already binds
/// most of `Cmd` space to menu items.
///
/// `performKeyEquivalent` is the hook, not `keyDown`. AppKit offers a key equivalent to the key
/// window's view hierarchy *before* the main menu, so a recorder that answers `true` there takes
/// ⌘K away from the launcher item for exactly as long as it is recording. `keyDown` would never see
/// it: by then the menu has already run the command.
struct ShortcutRecorder: NSViewRepresentable {
    /// Whether this field is the one listening. One recorder at a time, decided by the table.
    let isRecording: Bool
    let onCapture: (KeyBinding) -> Void
    /// Escape, which means "leave it as it was".
    let onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.owner = context.coordinator
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        context.coordinator.parent = self
        view.isRecording = isRecording
        if isRecording, view.window?.firstResponder !== view {
            // Asynchronously: the field is shown by the same state change that starts the recording,
            // so the view may not be in a window yet at the moment this runs.
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator {
        var parent: ShortcutRecorder
        init(parent: ShortcutRecorder) { self.parent = parent }
    }

    final class RecorderView: NSView {
        var owner: Coordinator?
        var isRecording = false

        override var acceptsFirstResponder: Bool { isRecording }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return false }
            return MainActor.assumeIsolated { capture(event) }
        }

        /// A chord with no ⌘ in it never reaches `performKeyEquivalent`, so plain keys land here —
        /// Escape above all, which is how the field is left without changing anything.
        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }
            MainActor.assumeIsolated { _ = capture(event) }
        }

        @MainActor
        private func capture(_ event: NSEvent) -> Bool {
            guard let owner else { return false }
            // 53 is Escape. Checked by key code rather than by character because the character is
            // `\u{1b}`, which is also what ⌃[ produces — and ⌃[ is a chord somebody might record.
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                owner.parent.onCancel()
                return true
            }
            guard let binding = KeyBinding(event: event) else { return false }
            owner.parent.onCapture(binding)
            return true
        }
    }
}
