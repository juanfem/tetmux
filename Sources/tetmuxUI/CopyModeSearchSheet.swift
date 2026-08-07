import SwiftUI

/// Asks for the text to search tmux's own history for.
///
/// Deliberately a sheet rather than a find bar, and deliberately not ⌘F. SwiftTerm's find bar is
/// already ⌘F and searches what the *emulator* is holding — which is the local scrollback, capped by
/// the theme's `scrollbackLines` and reset by every repaint. This searches what tmux is holding,
/// which is the history the emulator never received and the reason copy mode exists at all. Two
/// searches over two different bodies of text, so two controls that look different.
///
/// One shot rather than incremental: each keystroke would be a `send-keys -X search-backward` round
/// trip that moves the copy cursor, so an incremental field would walk the history backwards while
/// somebody typed. Find Next repeats it.
struct CopyModeSearchSheet: View {
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var needle: String = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Search History").font(.headline)
            Text("Searches what tmux is holding, not only what this pane has received.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            TextField("Text to find", text: $needle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .focused($isFieldFocused)
                .onSubmit { commit() }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Find", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { isFieldFocused = true }
    }

    private var trimmed: String {
        needle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }
}
