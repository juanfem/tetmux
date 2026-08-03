import SwiftUI
import tetmuxCore

/// F4.28 — for the focused tab: host, session, tmux version, RTT, and the active pane's foreground
/// command and working directory. Every value here is live; none of it is a placeholder.
struct StatusBarView: View {
    let host: HostState
    let session: TmuxSession
    let window: TmuxWindow
    let focusedPaneId: String?

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

            if let pane {
                Text("\(pane.cols)×\(pane.rows)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Pane size in cells, as reported by tmux")
            }

            if let rtt = host.rttMilliseconds {
                HStack(spacing: 4) {
                    Circle().fill(rttColor(rtt)).frame(width: 6, height: 6)
                    Text(String(format: "%.0f ms", rtt)).font(.caption2).foregroundStyle(.secondary)
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
}
