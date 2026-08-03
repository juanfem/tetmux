import SwiftUI
import tetmuxCore

/// F4.1 — Host → Session → Window. Panes are deliberately absent: a pane is not independently
/// attachable, so listing it in a navigation tree is noise.
///
/// Density is the design constraint (§7): the target is twenty sessions across five hosts visible
/// without scrolling, so rows stay single-line and badges carry the state.
struct SidebarView: View {
    @Bindable var model: AppModel
    /// Hosts are expanded by default and this tracks the exceptions. Tracking the expanded set
    /// instead would depend on hosts being loaded before the first layout pass, and they are not —
    /// they arrive asynchronously, so the tree came up collapsed.
    @State private var collapsedHosts: Set<String> = []

    var body: some View {
        // A plain List, deliberately. Giving it a `selection:` binding makes AppKit's own selection
        // gesture claim every click in a row, which swallows the row tap handlers below and leaves
        // the whole tree unclickable. Rows draw their own selected state instead.
        List {
            Section {
                ForEach(model.hosts) { host in
                    hostRow(host)
                    if isExpanded(host) {
                        ForEach(host.sessions) { session in
                            sessionRow(host: host, session: session)
                            ForEach(session.windows) { window in
                                windowRow(host: host, session: session, window: window)
                            }
                        }
                        if host.sessions.isEmpty {
                            Text(host.connectionState.isActive ? "No sessions" : "Not connected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 22)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("HOSTS").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.isAddHostPresented = true } label: {
                        Image(systemName: "plus").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add host")
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func isExpanded(_ host: HostState) -> Bool {
        !collapsedHosts.contains(host.id)
    }

    private func hostRow(_ host: HostState) -> some View {
        HStack(spacing: 6) {
            Button {
                if isExpanded(host) { collapsedHosts.insert(host.id) } else { collapsedHosts.remove(host.id) }
            } label: {
                Image(systemName: isExpanded(host) ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
            }
            .buttonStyle(.plain)

            // A Button, not a tap gesture on the row. Inside a List, `onTapGesture` is not reliably
            // hit-tested — the row cell claims the click first — which left the whole tree
            // unclickable. Buttons also give keyboard navigation for free (§7).
            Button {
                model.selectedHostId = host.id
                if !host.connectionState.isActive {
                    // A click is the user asserting the host is reachable, so it clears the
                    // circuit breaker rather than merely queueing behind it.
                    model.reconnect(host.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: host.config.isLocal ? "laptopcomputer" : "server.rack")
                        .foregroundStyle(Color.accentColor)
                        .font(.callout)
                    Text(host.config.name).fontWeight(.medium).lineLimit(1)
                    Spacer(minLength: 4)
                    StatusBadge(state: host.connectionState)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Host \(host.config.name), \(host.connectionState.accessibilityDescription)")
        .contextMenu {
            if host.connectionState.isActive {
                Button("New Session…") { model.newSessionTarget = host.id }
                Button("Detach Other Clients") {
                    Task { await model.service.detachOtherClients(hostId: host.id) }
                }
                Divider()
                Button("Disconnect") { model.disconnect(host.id) }
            } else {
                Button("Reconnect") { model.reconnect(host.id) }
                Button("New Session…") { model.newSessionTarget = host.id }
            }
            if !host.config.isLocal {
                Divider()
                Button("Remove Host", role: .destructive) { model.removeHost(host.id) }
            }
        }
    }

    private func sessionRow(host: HostState, session: TmuxSession) -> some View {
        Button {
            model.select(host: host.id, session: session.id, window: session.activeWindow?.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: session.isAttached ? "macwindow.badge.plus" : "macwindow")
                    .font(.caption)
                    .foregroundStyle(session.isAttached ? Color.accentColor : .secondary)
                Text(session.name).font(.subheadline).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(session.windows.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Session \(session.name), \(session.windows.count) windows")
        .contextMenu {
            Button("Kill Session…", role: .destructive) {
                model.killSession(hostId: host.id, sessionId: session.id)
            }
        }
    }

    /// F4.5 — name, pane count, the active pane's foreground command, and an activity indicator.
    private func windowRow(host: HostState, session: TmuxSession, window: TmuxWindow) -> some View {
        let isSelected = window.id == model.selectedWindowId && session.id == model.selectedSessionId
        return Button {
            model.select(host: host.id, session: session.id, window: window.id)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(window.hasActivity ? Color.accentColor : Color.clear)
                    .frame(width: 5, height: 5)
                Text(window.name).font(.subheadline).lineLimit(1)
                if !window.activeCommand.isEmpty {
                    Text(window.activeCommand)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if window.paneCount > 1 {
                    Image(systemName: "square.split.2x1").font(.caption2).foregroundStyle(.secondary)
                    Text("\(window.paneCount)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 36)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.accentColor.opacity(0.20) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Window \(window.name), \(window.paneCount) panes"
                + (window.activeCommand.isEmpty ? "" : ", running \(window.activeCommand)")
        )
    }
}

struct StatusBadge: View {
    let state: ConnectionState

    var body: some View {
        Group {
            switch state {
            case .connecting:
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 10, height: 10)
            case .reconnecting:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            default:
                Circle().fill(color).frame(width: 7, height: 7)
            }
        }
        .help(state.reason ?? state.accessibilityDescription)
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .degraded: return .yellow
        case .failed: return .red
        case .disconnected: return .secondary
        case .connecting, .reconnecting: return .orange
        }
    }
}

extension ConnectionState {
    var accessibilityDescription: String {
        switch self {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .degraded(let reason): return "degraded: \(reason)"
        case .reconnecting(let attempt, _): return "reconnecting, attempt \(attempt)"
        case .failed(let reason): return "failed: \(reason)"
        }
    }
}
