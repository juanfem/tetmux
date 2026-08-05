import SwiftUI
import tetmuxCore

/// F4.28 — for the focused tab: host, session, tmux version, RTT, and the active pane's foreground
/// command and working directory. Every value here is live; none of it is a placeholder.
struct StatusBarView: View {
    let host: HostState
    let session: TmuxSession
    let window: TmuxWindow
    let focusedPaneId: String?
    /// F4.21 — whether the next chord is going to the pane rather than to the application.
    let literalEscapeArmed: Bool

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var pane: TmuxPane? {
        window.panes.first { $0.id == (focusedPaneId ?? window.activePaneId) }
            ?? window.panes.first
    }

    var body: some View {
        HStack(spacing: 12) {
            item(icon: host.config.isLocal ? "laptopcomputer" : "server.rack", text: host.config.name)
            separator
            item(icon: "macwindow", text: session.name)

            if let command = pane?.command, !command.isEmpty {
                separator
                item(icon: "terminal", text: command, tint: .accentColor)
            }
            if let path = pane?.currentPath, !path.isEmpty {
                separator
                item(icon: "folder", text: abbreviate(path), tint: .secondary)
            }

            Spacer(minLength: 8)

            // A pane in a tmux mode is showing an overlay this application is not streamed and does
            // not draw, so its contents are a `capture-pane` still frame and its keys mean whatever
            // the mode's table says they mean. Unlabelled, that is indistinguishable from a pane that
            // has stopped — which is the complaint copy mode has always produced from the other side,
            // when somebody else's `prefix [` froze a pane here. Named rather than hinted at, because
            // "copy-mode" is the word the user needs to know to type `q` and get out.
            if let pane, pane.isInMode {
                Text(pane.mode)
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .help("This pane is in tmux's \(pane.mode). Keys go to the mode, not the shell.")
                    .accessibilityLabel("Pane is in \(pane.mode)")
                separator
            }

            // A mode that changes what the next keystroke does has to be visible while it is on;
            // otherwise ⌥⌘V pressed by accident makes the *following* chord vanish with nothing to
            // explain it. Accented and worded rather than a dot: it says which key it is waiting for.
            if literalEscapeArmed {
                Text("next chord → pane")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .help("The next key you press is sent to the pane instead of tetmux (⌥⌘V)")
                    .accessibilityLabel("Next chord goes to the pane")
                separator
            }

            if let pane {
                Text("\(pane.cols)×\(pane.rows)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Pane size in cells, as reported by tmux")
            }

            if let rtt = host.rttMilliseconds {
                HStack(spacing: 4) {
                    Circle().fill(rttColor(rtt)).frame(width: 6, height: 6)
                    Text(Self.rttText(rtt, differentiateWithoutColor: differentiateWithoutColor))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .help("Round trip over the control channel")
            }

            if let version = host.tmuxVersion {
                Text("tmux \(version)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    private var separator: some View {
        Divider().frame(height: 11)
    }

    private func item(icon: String, text: String, tint: Color = .primary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption).foregroundStyle(tint).lineLimit(1)
        }
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func rttColor(_ rtt: Double) -> Color {
        rtt < 50 ? .green : (rtt < 150 ? .orange : .red)
    }

    /// The dot is the judgement and the number is the measurement, so with colour taken away only the
    /// measurement is left — and "120 ms" answers nothing unless you already know where the
    /// thresholds sit. The word is the same answer the dot gives, in the one channel that survives.
    ///
    /// Words rather than a second shape, because that is the answer the sidebar already reached one
    /// panel up: a host that is not simply connected says "reconnecting 3/8" or "degraded" in text
    /// precisely because a coloured dot "would say the same thing twice and still not tell anyone
    /// what yellow meant". A new shape vocabulary here would need learning; these do not.
    ///
    /// Only with the preference on. The status bar is a single compact line and the word is genuinely
    /// redundant when the colour is doing its job — which is exactly the trade the preference exists
    /// to let the user make.
    static func rttText(_ rtt: Double, differentiateWithoutColor: Bool) -> String {
        let measured = String(format: "%.0f ms", rtt)
        guard differentiateWithoutColor else { return measured }
        let judgement = rtt < 50 ? "good" : (rtt < 150 ? "fair" : "slow")
        return "\(measured) · \(judgement)"
    }
}
