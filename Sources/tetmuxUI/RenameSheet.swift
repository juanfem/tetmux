import SwiftUI
import tetmuxCore

/// F4.11 — renaming a session or a window.
///
/// A sheet rather than an editable row. Inline editing inside a `List` needs the row to take focus,
/// and sidebar rows are `Button`s precisely because the row cell claims clicks; the two mechanisms
/// fight, and the failure mode is a field that cannot be typed into. A sheet also gives the same
/// affordance to the sidebar, the tab bar, and the menu without three implementations.
struct RenameSheet: View {
    let pending: AppModel.PendingRename
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(pending.title).font(.headline)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .focused($isFieldFocused)
                .onSubmit { commit() }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            name = pending.currentName
            // The whole point of the sheet is to type a name; landing without focus costs a click.
            isFieldFocused = true
        }
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }
}
