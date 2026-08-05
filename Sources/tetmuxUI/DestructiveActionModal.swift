import SwiftUI
import tetmuxCore

/// F4.10 — destructive commands show the target's name, pane count, and running commands.
/// Deliberately has no "don't ask again" checkbox: the cost of the confirmation is a keystroke,
/// and the cost of getting it wrong is somebody's long-running job.
struct DestructiveActionModal: View {
    var title: String = "Confirm Destructive Action"
    let targetName: String
    var paneCount: Int = 1
    var runningCommands: [String] = []
    /// What the sentence at the top is about, so the section below can say what the *other* clients
    /// are about to lose without the two disagreeing.
    var subject: Subject = .window
    /// Clients attached to the session, excluding tetmux's own (`AppModel.otherClients`). Passed in
    /// rather than looked up here, and re-evaluated whenever the model publishes, so a `list-clients`
    /// answer arriving after the sheet opened corrects what it says.
    var otherClients: [TmuxClient] = []
    /// False when the host is not connected, which makes an empty `otherClients` "we cannot say"
    /// rather than "nobody". The distinction is the whole point of the section.
    var clientsAreKnown: Bool = true
    let onConfirm: () -> Void
    let onCancel: () -> Void

    /// Read at the site and answered by `ContrastPolicy`, like every other place that honours
    /// Increase Contrast.
    @Environment(\.colorSchemeContrast) private var contrast

    enum Subject {
        case window
        case session

        var confirmTitle: String {
            switch self {
            case .window: return "Close Window"
            case .session: return "Kill Session"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text(title).font(.headline)
            }

            explanation
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

            attachedClients

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(subject.confirmTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    /// Says why this is a kill rather than a close. For a window: it is in one session, and tmux
    /// cannot take a window out of its only session without destroying it — `unlink-window` refuses.
    /// For a session there is no non-destructive reading at all. Presenting either as an ordinary
    /// close would be describing the wrong action.
    ///
    /// Emphasis is `Text(...).bold()` and concatenation rather than `**markdown**` in the string.
    /// SwiftUI parses markdown only in a *literal* `Text`, so the asterisks around an interpolated
    /// name were reaching the sheet verbatim: it read `tmux cannot close **build** without…`.
    private var explanation: Text {
        switch subject {
        case .window:
            return Text("tmux cannot close ") + Text(targetName).bold()
                + Text(" without ending what is running in it: it is only in this session. "
                       + "Its \(paneCount) \(paneCount == 1 ? "pane" : "panes") will be terminated.")
        case .session:
            return Text("Killing ") + Text(targetName).bold()
                + Text(" ends every process in its \(paneCount) "
                       + "\(paneCount == 1 ? "window" : "windows"). tmux has no way to undo this "
                       + "and no way to reattach afterwards.")
        }
    }

    /// Who else is in the session, because a kill is not private.
    ///
    /// This is the fact the confirmation used to leave out. `kill-session` ends the session for
    /// *every* client attached to it, and a window in one session goes the same way — so somebody at
    /// another terminal, or on another machine over ssh, loses what they were doing because of a
    /// click made here. The absence of other clients is reported just as plainly: "nobody else is
    /// attached" is what makes the section trustworthy on the occasions it says otherwise.
    ///
    /// tmux does not record where a client connected from, so neither does this — see
    /// `TmuxCommand.clientsFormat`. What it can name is the unix user, the tty, and the terminal
    /// type, and the footnote says as much rather than letting "me on /dev/ttys004" be read as
    /// a claim about which machine that is.
    @ViewBuilder
    private var attachedClients: some View {
        if !clientsAreKnown {
            Label("Not connected, so tetmux cannot tell whether other clients are attached.",
                  systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if otherClients.isEmpty {
            Label("No other clients are attached.", systemImage: "person")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(otherClients.count == 1
                     ? "1 other client is attached and will lose it:"
                     : "\(otherClients.count) other clients are attached and will lose it:")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                ForEach(otherClients) { client in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: client.isControlMode ? "display" : "person")
                            .font(.caption2)
                        // The detail sits under the name rather than after it: a tty, a terminal
                        // type and an idle time on one line wrap into a hanging fragment, and the
                        // name — the only part that identifies anybody — is what gets pushed around.
                        VStack(alignment: .leading, spacing: 1) {
                            Text(client.displayName).font(.caption).fontDesign(.monospaced)
                            let detail = describe(client)
                            if !detail.isEmpty {
                                Text(detail).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("tmux does not record where a client connected from; it knows the user, the "
                     + "terminal device, and when it was last active.")
                    .font(.caption2)
                    .foregroundStyle(ContrastPolicy.footnoteColor(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    /// The parenthetical after a client's name: what it is, and how long since it did anything.
    ///
    /// Relative rather than a wall-clock time deliberately — `client_activity` is a timestamp from
    /// the *server's* clock, so on a remote host with a skewed clock an absolute time would be wrong
    /// in a way that looks authoritative. A duration is wrong by the same amount and reads as the
    /// estimate it is.
    private func describe(_ client: TmuxClient) -> String {
        var parts: [String] = []
        if client.isControlMode { parts.append("control mode") }
        if !client.terminal.isEmpty { parts.append(client.terminal) }
        if let activity = client.lastActivity {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            parts.append("active \(formatter.localizedString(for: activity, relativeTo: Date()))")
        }
        return parts.joined(separator: " · ")
    }
}
