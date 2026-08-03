import SwiftUI

/// F4.10 — destructive commands show the target's name, pane count, and running commands.
/// Deliberately has no "don't ask again" checkbox: the cost of the confirmation is a keystroke,
/// and the cost of getting it wrong is somebody's long-running job.
struct DestructiveActionModal: View {
    var title: String = "Confirm Destructive Action"
    let targetName: String
    var paneCount: Int = 1
    var runningCommands: [String] = []
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text(title).font(.headline)
            }

            // Says why this is a kill rather than a close. The window is in one session, and tmux
            // cannot take a window out of its only session without destroying it — `unlink-window`
            // refuses. Presenting it as an ordinary close would be describing the wrong action.
            Text("tmux cannot close **\(targetName)** without ending what is running in it: "
                 + "it is only in this session. Its \(paneCount) \(paneCount == 1 ? "pane" : "panes") "
                 + "will be terminated.")
                .fixedSize(horizontal: false, vertical: true)

            if !runningCommands.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Running:")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    ForEach(Array(runningCommands.enumerated()), id: \.offset) { _, command in
                        HStack(spacing: 6) {
                            Image(systemName: "terminal").font(.caption2)
                            Text(command).font(.caption).fontDesign(.monospaced)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Close Window", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
