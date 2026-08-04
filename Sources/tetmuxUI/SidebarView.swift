import SwiftUI
import tetmuxCore

/// F4.1 — Host → Session → Window. Panes are deliberately absent as *rows*: a pane is not
/// independently attachable, so listing it in a navigation tree is noise. Their commands do appear on
/// the window row, because "what is running in there" is the thing a window is actually identified by.
///
/// Density is the design constraint (§7): the target is twenty sessions across five hosts visible
/// without scrolling, so rows stay single-line, sessions start collapsed, and connection state is a
/// rail rather than a row of its own.
struct SidebarView: View {
    @Bindable var model: AppModel
    /// The window this sidebar belongs to. Selection is per window: clicking a session here used to
    /// retarget every open window, because there was one selection between them all.
    let state: WindowState

    /// Hosts the user has expanded or collapsed *by hand*, overriding the default.
    ///
    /// Storing the exceptions rather than the set of open hosts, because the default is not a
    /// constant: a connected host starts open and a disconnected one starts closed, and hosts arrive
    /// asynchronously — a set of "expanded" ids computed before they load comes up empty and the whole
    /// tree renders collapsed.
    @State private var hostExpansion: [String: Bool] = [:]
    /// Sessions the user has opened. Collapsed is the default here, so this *is* the open set.
    @State private var expandedSessions: Set<String> = []
    /// Which row the pointer is over. Host-qualified, because tmux ids are per-server: `$0` and `@1`
    /// exist on every host, so an unqualified key lights up the matching row on every other host too.
    @State private var hoveredRow: String?

    var body: some View {
        List {
            Section {
                ForEach(model.hosts) { host in
                    hostGroup(host)
                }
            } header: {
                HStack(spacing: 8) {
                    Text("HOSTS").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                    Spacer()
                    Button { setAllExpanded(true) } label: {
                        Image(systemName: "chevron.down.square").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Expand every host and session")
                    .accessibilityLabel("Expand all")
                    Button { setAllExpanded(false) } label: {
                        Image(systemName: "chevron.right.square").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Collapse every host and session")
                    .accessibilityLabel("Collapse all")
                    Button { model.presentNewHost(in: state) } label: {
                        Image(systemName: "plus").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Add host")
                    .accessibilityLabel("Add host")
                }
            }
        }
        .listStyle(.sidebar)
        // A session or window created from this tree opens as soon as tmux confirms it exists.
        .onChange(of: model.sessionsToExpand) { _, _ in
            for host in model.hosts {
                for session in host.sessions
                where model.takeSessionExpansion(hostId: host.id, sessionId: session.id) {
                    expandedSessions.insert(key(host, session.id))
                    hostExpansion[host.id] = true
                }
            }
        }
    }

    // MARK: - Keys
    //
    // Everything the sidebar remembers is keyed by host as well as by tmux id. tmux numbers sessions
    // and windows per server, so `$0`/`@1` exist on every host at once — this is what made two window
    // rows on different hosts highlight together, and hovering one reveal the other's buttons.

    private func key(_ host: HostState, _ id: String) -> String { "\(host.id)|\(id)" }

    private func isExpanded(_ host: HostState) -> Bool {
        // A host that is not connected has nothing worth showing and is usually not what the user came
        // for, so it starts closed and takes one row instead of many.
        hostExpansion[host.id] ?? host.connectionState.isActive
    }

    private func isExpanded(_ host: HostState, _ session: TmuxSession) -> Bool {
        expandedSessions.contains(key(host, session.id))
    }

    /// Every host and every session at once.
    ///
    /// Writes an explicit entry for each host rather than clearing the overrides, because clearing
    /// would hand each host back to its default — and "expand all" that leaves the disconnected hosts
    /// shut is not expand all.
    private func setAllExpanded(_ expanded: Bool) {
        for host in model.hosts {
            hostExpansion[host.id] = expanded
            for session in host.sessions {
                if expanded {
                    expandedSessions.insert(key(host, session.id))
                } else {
                    expandedSessions.remove(key(host, session.id))
                }
            }
        }
    }

    /// Every session of one host.
    private func setExpanded(_ host: HostState, _ expanded: Bool) {
        hostExpansion[host.id] = expanded
        for session in host.sessions {
            if expanded {
                expandedSessions.insert(key(host, session.id))
            } else {
                expandedSessions.remove(key(host, session.id))
            }
        }
    }

    // MARK: - Host

    /// One host and everything under it, with a status rail down the side.
    ///
    /// The whole group is a single `List` row so the rail can span it. Per-row `List` behaviour is no
    /// loss here: the tree already draws its own selection and uses plain buttons, because giving the
    /// `List` a `selection:` binding makes AppKit's selection gesture claim every click and leaves the
    /// rows unclickable.
    private func hostGroup(_ host: HostState) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // The rail. Carries connection state for the whole group at a glance, and costs no row.
            RoundedRectangle(cornerRadius: 1)
                .fill(railColor(host.connectionState))
                .frame(width: 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                hostRow(host)
                if isExpanded(host) {
                    ForEach(host.sessions) { session in
                        sessionRow(host: host, session: session)
                        if isExpanded(host, session) {
                            ForEach(session.windows) { window in
                                windowRow(host: host, session: session, window: window)
                            }
                        }
                    }
                    if host.sessions.isEmpty && host.connectionState.isActive {
                        Text("No sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 22)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func railColor(_ state: ConnectionState) -> Color {
        switch state {
        case .connected: return .green
        case .degraded: return .yellow
        case .failed: return .red
        case .connecting, .reconnecting: return .orange
        case .disconnected: return .secondary.opacity(0.35)
        }
    }

    private func hostRow(_ host: HostState) -> some View {
        let live = host.connectionState.isActive
        return HStack(spacing: 6) {
            Button {
                hostExpansion[host.id] = !isExpanded(host)
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
                state.selectedHostId = host.id
                if !live {
                    // A click is the user asserting the host is reachable, so it clears the
                    // circuit breaker rather than merely queueing behind it.
                    model.reconnect(host.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: host.config.isLocal ? "laptopcomputer" : "server.rack")
                        .foregroundStyle(live ? Color.accentColor : .secondary)
                        .font(.callout)
                    Text(host.config.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        // Greyed when there is nothing behind it, so a screen of hosts reads as
                        // "these three are live" without picking apart the badges.
                        .foregroundStyle(live ? .primary : .secondary)
                    Spacer(minLength: 4)
                    hostStatusLabel(host)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Item 3 — a host is where sessions come from, so the button to make one lives on it.
            let showsActions = hoveredRow == host.id || host.id == state.selectedHostId
            RowButton(
                systemName: "chevron.down.square",
                help: "Expand every session on \(host.config.name)",
                isVisible: showsActions
            ) {
                setExpanded(host, true)
            }
            RowButton(
                systemName: "chevron.right.square",
                help: "Collapse every session on \(host.config.name)",
                isVisible: showsActions
            ) {
                setExpanded(host, false)
            }
            RowButton(
                systemName: "plus",
                help: "New session on \(host.config.name)",
                isVisible: showsActions
            ) {
                model.createSessionWithDefaultName(hostId: host.id, revealIn: state)
            }
        }
        .onHover { hovering(host.id, $0) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Host \(host.config.name), \(host.connectionState.accessibilityDescription)")
        .contextMenu {
            if host.connectionState.isActive {
                Button("New Session") { model.createSessionWithDefaultName(hostId: host.id, revealIn: state) }
                Button("Detach Other Clients") {
                    Task { await model.service.detachOtherClients(hostId: host.id) }
                }
                Divider()
                Button("Disconnect") { model.disconnect(host.id) }
            } else {
                Button("Reconnect") { model.reconnect(host.id) }
                Button("New Session") { model.createSessionWithDefaultName(hostId: host.id, revealIn: state) }
            }
            if !host.config.isLocal {
                Divider()
                Button("Edit Host…") { model.presentEditHost(host.id, in: state) }
                Button("Remove Host", role: .destructive) { model.removeHost(host.id) }
            }
        }
    }

    /// The state of a host that is not simply connected, in words rather than as a coloured dot.
    ///
    /// The rail already carries the colour; a dot beside it would say the same thing twice and still
    /// not tell anyone what "yellow" meant.
    @ViewBuilder
    private func hostStatusLabel(_ host: HostState) -> some View {
        switch host.connectionState {
        case .connected:
            EmptyView()
        case .connecting:
            ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 10, height: 10)
        case .reconnecting(let attempt, _):
            Text("reconnecting \(attempt)/8")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .disconnected:
            Text("not connected").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        case .degraded(let reason), .failed(let reason):
            // §7 — tmux's or ssh's own words, in full, on hover.
            Text(host.connectionState.isActive ? "degraded" : "failed")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(reason)
        }
    }

    // MARK: - Session

    private func sessionRow(host: HostState, session: TmuxSession) -> some View {
        let rowKey = key(host, session.id)
        let isSelected = state.isShowing(hostId: host.id, sessionId: session.id)
        let expanded = isExpanded(host, session)
        return HStack(spacing: 4) {
            Button {
                expandedSessions.formSymmetricDifference([rowKey])
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse \(session.name)" : "Expand \(session.name)")

            Button {
                model.select(in: state, host: host.id, session: session.id, window: session.activeWindow?.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: session.isAttached ? "macwindow.badge.plus" : "macwindow")
                        .font(.caption)
                        .foregroundStyle(session.isAttached ? Color.accentColor : .secondary)
                    Text(session.name).font(.subheadline).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    // Only while closed: with the windows listed underneath, a count is just the
                    // number of rows directly below it.
                    if !expanded {
                        Text("\(session.windows.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(session.name)
            // Item 5 — double-click focuses this window on the session. The first click still
            // selects, so this reads as "and also get everything else out of the way".
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                focus(host: host, session: session)
            })

            RowButton(
                systemName: "plus",
                help: "New window in \(session.name)",
                isVisible: hoveredRow == rowKey || isSelected
            ) {
                model.newWindow(hostId: host.id, sessionId: session.id, revealIn: state)
            }
            RowButton(
                systemName: "xmark",
                help: "Kill \(session.name)",
                isVisible: hoveredRow == rowKey || isSelected
            ) {
                model.requestKillSession(in: state, hostId: host.id, sessionId: session.id)
            }
        }
        .padding(.leading, 14)
        .onHover { hovering(rowKey, $0) }
        .accessibilityLabel("Session \(session.name), \(session.windows.count) windows")
        .contextMenu {
            Button("Rename Session…") {
                model.requestRenameSession(in: state, hostId: host.id, sessionId: session.id)
            }
            Button("New Window") { model.newWindow(hostId: host.id, sessionId: session.id, revealIn: state) }
            Button("Open in New Window") {
                model.showSession(
                    hostId: host.id, sessionId: session.id,
                    collapseSidebar: true, preferNewWindow: true
                )
            }
            Divider()
            Button("Kill Session…", role: .destructive) {
                model.requestKillSession(in: state, hostId: host.id, sessionId: session.id)
            }
        }
    }

    /// Item 5 — focus mode: this window shows the session and nothing else.
    ///
    /// Deliberately local. An earlier version opened a new macOS window, or brought a different one
    /// forward, which is not what a double-click in *this* window's tree should do — the tree belongs
    /// to this window and so does the result.
    ///
    /// The tmux window already on screen is kept if it belongs to the session being focused, so
    /// double-clicking the session you are already in does not throw away which of its windows you
    /// were looking at. It only falls back to the first window when arriving from somewhere else.
    private func focus(host: HostState, session: TmuxSession, window: TmuxWindow? = nil) {
        // Double-clicking a *window* names the target outright. Double-clicking a session does not, so
        // it keeps whatever window is already on screen if that window belongs to the session — only
        // falling back to the first when arriving from somewhere else.
        let target = window?.id
            ?? state.selectedWindowId.flatMap { current in
                session.windows.first { $0.id == current }?.id
            }
            ?? session.windows.first?.id
        model.select(in: state, host: host.id, session: session.id, window: target)
        state.sidebarVisibility = .detailOnly
    }

    // MARK: - Window

    /// F4.5 — what is running in the window, its pane count, and an activity indicator.
    private func windowRow(host: HostState, session: TmuxSession, window: TmuxWindow) -> some View {
        let rowKey = key(host, window.id)
        // Host-qualified — see `WindowState.isShowing`. Without the host in the comparison a window
        // `@1` in session `$0` highlights on every host that has one, which is every host.
        let isSelected = state.isShowing(hostId: host.id, sessionId: session.id, windowId: window.id)
        let label = window.displayLabel
        return HStack(spacing: 4) {
            Button {
                model.select(in: state, host: host.id, session: session.id, window: window.id)
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(window.hasActivity ? Color.accentColor : Color.clear)
                        .frame(width: 5, height: 5)
                    Text(label)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if window.paneCount > 1 {
                        Image(systemName: "square.split.2x1").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The full text when it does not fit — the label is the only identification a window has,
            // and a truncated one can easily be identical to its neighbour's.
            .help(label)
            // Same gesture as a session row, one level down: show this window and get out of the way.
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                focus(host: host, session: session, window: window)
            })

            RowButton(
                systemName: "xmark",
                help: "Close \(window.name)",
                isVisible: hoveredRow == rowKey || isSelected
            ) {
                model.select(in: state, host: host.id, session: session.id, window: window.id)
                model.requestCloseWindow(in: state)
            }
        }
        .padding(.leading, 32)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.20) : Color.clear)
        )
        .onHover { hovering(rowKey, $0) }
        .accessibilityLabel("Window \(label), \(window.paneCount) panes")
        .contextMenu {
            Button("Rename Window…") {
                model.requestRenameWindow(in: state, hostId: host.id, windowId: window.id)
            }
            Button("Open in New Window") {
                model.showSession(
                    hostId: host.id, sessionId: session.id, windowId: window.id,
                    collapseSidebar: true, preferNewWindow: true
                )
            }
            Divider()
            Button("Close Window…", role: .destructive) {
                model.select(in: state, host: host.id, session: session.id, window: window.id)
                model.requestCloseWindow(in: state)
            }
        }
    }

    /// Tracks the hovered row without letting a stale leave-event clear a newer enter-event.
    private func hovering(_ rowKey: String, _ isInside: Bool) {
        if isInside {
            hoveredRow = rowKey
        } else if hoveredRow == rowKey {
            hoveredRow = nil
        }
    }
}

/// A small action on a sidebar row.
///
/// Always laid out and only sometimes visible: hiding it outright would resize the row under the
/// pointer, and the tree would shuffle as the mouse crossed it — the same reason the tab bar's close
/// button works this way.
private struct RowButton: View {
    let systemName: String
    let help: String
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .help(help)
        .accessibilityLabel(help)
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
