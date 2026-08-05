import SwiftUI

/// F4.19 — the editable keymap, as a table of every chord the application takes.
///
/// The table is the documentation. F4.19 asks for a keymap that is both *documented* and *editable*,
/// and the honest way to do that is one list that is authoritative for both: everything tetmux
/// intercepts is a row here, so anything not in this list reaches the pane. That is the promise
/// F4.20 makes about `Ctrl+K`, stated as a thing the user can check rather than a claim in a file.
struct KeymapSettingsView: View {
    @Bindable var model: AppModel

    /// Which row is listening for a chord. One at a time — two recorders would both claim the same
    /// key equivalent and the winner would be whichever view AppKit walked into first.
    @State private var recording: ApplicationShortcut?
    /// The last refusal, shown under the table until the next attempt.
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(ApplicationShortcut.allCases.enumerated()), id: \.element) { index, shortcut in
                        row(shortcut)
                            // A striped table rather than dividers: twenty rows of two short items
                            // read as a list of pairs this way and as a wall of rules the other.
                            .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
                    }
                }
            }
            .frame(height: 300)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))

            if let refusal {
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            } else {
                // §4.4's rule, where somebody rebinding a chord will read it. It is not a footnote:
                // it is why ⌘K can be the launcher at all.
                Text("Every binding needs ⌘. Chords without it — including every bare ⌃ chord — are forwarded to the pane untouched, which is what keeps ⌃K as kill-line in your shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            HStack {
                Text("Menus follow this table, so a rebound command shows its new chord.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") {
                    recording = nil
                    refusal = nil
                    model.resetKeymap()
                }
            }
            .padding(.top, 10)
        }
    }

    private func row(_ shortcut: ApplicationShortcut) -> some View {
        HStack {
            Text(shortcut.title)
                .lineLimit(1)
            Spacer(minLength: 12)

            if recording == shortcut {
                ZStack {
                    Text("Press a chord…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ShortcutRecorder(
                        isRecording: true,
                        onCapture: { capture($0, for: shortcut) },
                        onCancel: { recording = nil }
                    )
                }
                .frame(width: 110, height: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18)))
            } else {
                Button {
                    refusal = nil
                    recording = shortcut
                } label: {
                    Text(model.keymap.binding(for: shortcut)?.displayString ?? "unbound")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(model.keymap.binding(for: shortcut) == nil ? .secondary : .primary)
                        .frame(width: 110, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to record a new chord")
            }

            // Clearing is a real state, not a way of saying "default": a command with no chord is
            // still in the menu and still reachable there, and it is the only way to hand a chord
            // back to the pane permanently.
            Button {
                refusal = nil
                recording = nil
                model.rebind(shortcut, to: nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(model.keymap.binding(for: shortcut) == nil ? 0 : 1)
            .disabled(model.keymap.binding(for: shortcut) == nil)
            .help("Unbind \(shortcut.title)")
            .accessibilityLabel("Unbind \(shortcut.title)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func capture(_ binding: KeyBinding, for shortcut: ApplicationShortcut) {
        switch model.rebind(shortcut, to: binding) {
        case .applied:
            recording = nil
            refusal = nil
        case .conflict(let owner):
            // The field stays open, so the answer to a refusal is to press another chord rather than
            // to click the row again.
            refusal = "\(binding.displayString) is already \(owner.title). Unbind it first, or pick another chord."
        case .notInCommandSpace:
            refusal = "\(binding.displayString) has no ⌘ in it. tetmux only intercepts ⌘ chords — everything else belongs to the pane."
        }
    }
}
