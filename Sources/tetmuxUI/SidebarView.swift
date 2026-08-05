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

    @Environment(\.colorSchemeContrast) private var contrast

    /// Whether the pointer is over the footer's Add host row.
    @State private var addHostHovered = false

    /// ⌥, which turns every destructive row button into one that acts without asking. Held here so
    /// the glyph can say so *before* the click rather than after it — a modifier whose only evidence
    /// is what already happened is not a modifier anyone can learn.
    @State private var modifiers = ModifierKeyMonitor()

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(model.hosts) { host in
                        hostGroup(host)
                    }
                } header: {
                    HStack(spacing: 2) {
                        Text("HOSTS").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                        Spacer()
                        // Both stay one click — the whole point of the pair is that neither hides
                        // behind a menu — but they no longer read as the same glyph at this size.
                        HeaderButton(help: "Collapse every host and session", label: "Collapse all") {
                            setAllExpanded(false)
                        } icon: {
                            RuleStackIcon(showsMiddleRule: false)
                        }
                        HeaderButton(help: "Expand every host and session", label: "Expand all") {
                            setAllExpanded(true)
                        } icon: {
                            RuleStackIcon(showsMiddleRule: true)
                        }
                    }
                    .padding(.trailing, RowAction.edgeInset)
                }
            }
            .listStyle(.sidebar)

            // Add host is the one action that belongs to the list rather than to a row, so it sits in
            // the dead space under the tree instead of competing with the view controls in the header.
            Divider()
            addHostFooter
        }
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

    private var addHostFooter: some View {
        Button { model.presentNewHost(in: state) } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.callout).foregroundStyle(.secondary)
                Text("Add host").font(.subheadline)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(addHostHovered ? ContrastPolicy.hoverFill(contrast) : Color.clear)
        )
        .padding(RowAction.edgeInset)
        .onHover { addHostHovered = $0 }
        .help("Add a host")
        .accessibilityLabel("Add host")
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
        // One context menu for the whole group, dispatched to the row the pointer is on.
        //
        // Not one per row, which is what this was and what did not work: the host, its sessions and
        // its windows are a *single* `List` row (see the note above), and AppKit resolves a context
        // menu at the cell. Several nested `.contextMenu`s inside one cell collapse to one, and the
        // one that survived was the host's — so right-clicking a session or a window row showed
        // Disconnect and Detach Other Clients, and Rename Session, Rename Window and the rest were
        // unreachable from the tree for as long as the group has been a single row.
        //
        // `hoveredRow` already tracks which row the pointer is on, because that is what reveals a
        // row's buttons; a right-click is always preceded by the pointer arriving, so it is current
        // by the time the menu is built. Anything it cannot resolve falls back to the host, which is
        // both the enclosing thing and what used to happen unconditionally.
        .contextMenu { menu(for: host) }
    }

    /// What the pointer is on, for the group-level menu above.
    private enum RowSubject {
        case host
        case session(TmuxSession)
        case window(TmuxSession, TmuxWindow)
    }

    private func hoveredSubject(in host: HostState) -> RowSubject {
        guard let hoveredRow else { return .host }
        for session in host.sessions {
            if hoveredRow == key(host, session.id) { return .session(session) }
            for window in session.windows where hoveredRow == key(host, window.id) {
                return .window(session, window)
            }
        }
        return .host
    }

    @ViewBuilder
    private func menu(for host: HostState) -> some View {
        switch hoveredSubject(in: host) {
        case .host:
            hostMenu(host)
        case .session(let session):
            sessionMenu(host: host, session: session)
        case .window(let session, let window):
            windowMenu(host: host, session: session, window: window)
        }
    }

    /// The rail's hue, and the one colour-carried signal in the app that needs no
    /// `differentiateWithoutColor` fallback (§7).
    ///
    /// Checked rather than assumed: `hostStatusLabel` puts every state but `.connected` into words
    /// on the row the rail belongs to — a spinner, "reconnecting 3/8", "degraded", "failed", "not
    /// connected" — and `.connected` is the one with no label at all. So the six states are already
    /// six distinct readings with the hue removed, and adding a badge would be the second thing
    /// saying what the label says, which is what that label was written to replace.
    ///
    /// The one gap is a host scrolled so far that its row is off screen while its rail is not. Left
    /// alone deliberately: at that point the rail is 2pt of colour belonging to a host whose name is
    /// also off screen, so it identifies nothing either way.
    private func railColor(_ state: ConnectionState) -> Color {
        switch state {
        case .connected: return .green
        case .degraded: return .yellow
        case .failed: return .red
        case .connecting, .reconnecting: return .orange
        case .disconnected: return .secondary.opacity(ContrastPolicy.recessedOpacity(contrast, standard: 0.35))
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
                        // Deliberately *not* greyed when the host is offline. Greying the name as well
                        // as the rail and the label made an idle host read as a disabled one — three
                        // greys saying the same thing, and the one carrying the identity is the one
                        // that had to stay legible. The rail and the status label carry the state.
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    hostStatusLabel(host)
                    // Only while closed, exactly as a collapsed session shows its window count: with
                    // the sessions listed underneath, the number is the count of the rows below it.
                    if !isExpanded(host), !host.sessions.isEmpty {
                        Text("\(host.sessions.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Item 3 — a host is where sessions come from, so the button to make one lives on it.
            let showsActions = hoveredRow == host.id || host.id == state.selectedHostId
            rowActions {
                RowButton(
                    glyph: .plus,
                    help: "New session on \(host.config.name)",
                    isVisible: showsActions
                ) {
                    model.createSessionWithDefaultName(hostId: host.id, revealIn: state)
                }
                // Laid out whether or not the host is live, so a host connecting or dropping does not
                // shift the row's other button sideways under the pointer.
                RowButton(
                    glyph: .cross,
                    help: "Disconnect from \(host.config.name)",
                    isVisible: showsActions && live
                ) {
                    model.disconnect(host.id)
                }
            }
        }
        .onHover { hovering(host.id, $0) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Host \(host.config.name), \(host.connectionState.accessibilityDescription), "
                + "\(host.sessions.count) sessions"
        )
    }

    @ViewBuilder
    private func hostMenu(_ host: HostState) -> some View {
        Group {
            // Expanding or collapsing one host's sessions used to be two of the four buttons crowded
            // onto the row's right edge. The row now carries only the two actions the spec assigns to
            // a host, so these keep a home here rather than disappearing.
            Button("Expand All Sessions") { setExpanded(host, true) }
            Button("Collapse All Sessions") { setExpanded(host, false) }
            Divider()
            if host.connectionState.isActive {
                Button("New Session") { model.createSessionWithDefaultName(hostId: host.id, revealIn: state) }
                Button("Detach Other Clients") {
                    Task { await model.service.detachOtherClients(hostId: host.id) }
                }
                Divider()
                // F4.11's two ways of letting go, and they are not the same thing. "Detach" says so
                // to tmux and leaves the session running for the next client; "Disconnect" also puts
                // `window-size` back and stops the reconnect backoff, which is what the user means
                // when they are done with a host rather than done with this client.
                Button("Detach This Client") { model.detachThisClient(host.id) }
                Button("Disconnect") { model.disconnect(host.id) }
            } else {
                Button("Reconnect") { model.reconnect(host.id) }
                Button("New Session") { model.createSessionWithDefaultName(hostId: host.id, revealIn: state) }
            }
            Divider()
            // The local host is editable too now — it has a start directory and a clipboard policy,
            // which are the two settings that do not depend on there being a connection to make. It
            // is still not removable: it is not a stored host, it is the tmux on this machine.
            Button(host.config.isLocal ? "Local tmux Settings…" : "Edit Host…") {
                model.presentEditHost(host.id, in: state)
            }
            if !host.config.isLocal {
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
                    // A session is the one thing in the tree that *contains* windows, so it is the
                    // one layered glyph (§2). Colour still carries what *tetmux* is streaming — not
                    // `session_attached`, which counts every client of the server including
                    // terminals elsewhere on the machine. Accented means these panes move.
                    SessionStackIcon()
                        .foregroundStyle(host.isLive(session.id) ? Color.accentColor : .secondary)
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

            rowActions {
                RowButton(
                    glyph: .plus,
                    help: "New window in \(session.name)",
                    isVisible: hoveredRow == rowKey || isSelected
                ) {
                    model.newWindow(hostId: host.id, sessionId: session.id, revealIn: state)
                }
                // Inline rather than behind an overflow menu: closing a run of sessions is one click
                // and one confirmation each, not a menu opened per row. It already asks before
                // killing — unless ⌥ is down, which is how a run of them becomes one click each.
                RowButton(
                    glyph: .cross,
                    help: modifiers.isOptionHeld
                        ? "Kill \(session.name) without asking"
                        : "Kill \(session.name)",
                    isVisible: hoveredRow == rowKey || isSelected,
                    isArmed: modifiers.isOptionHeld
                ) {
                    model.requestKillSession(
                        in: state, hostId: host.id, sessionId: session.id,
                        skippingConfirmation: OptionKey.isHeld
                    )
                }
            }
        }
        .padding(.leading, 14)
        .onHover { hovering(rowKey, $0) }
        // Liveness used to be a second glyph as well as a colour; the layered icon is now the same
        // shape either way, so the state it carries has to be said here in words.
        .accessibilityLabel(
            "Session \(session.name), \(session.windows.count) windows, "
                + (host.isLive(session.id) ? "attached" : "not attached")
        )
    }

    @ViewBuilder
    private func sessionMenu(host: HostState, session: TmuxSession) -> some View {
        Group {
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
                    // §3 — the pane glyph describes the window, so it sits with the row's other
                    // icons rather than at the right edge, where it read as a third button. The slot
                    // is reserved whether or not the window is split, so every name starts at the
                    // same x; §2 leaves it never empty, since one pane is a plain rectangle.
                    WindowPaneIcon(split: Self.splitAxis(window))
                        .foregroundStyle(.secondary)
                        .frame(width: TreeIcon.slot, height: TreeIcon.slot)
                    Text(label)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
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

            rowActions {
                RowButton(
                    glyph: .cross,
                    help: modifiers.isOptionHeld
                        ? "Close \(window.name) without asking"
                        : "Close \(window.name)",
                    isVisible: hoveredRow == rowKey || isSelected,
                    isArmed: modifiers.isOptionHeld
                ) {
                    model.select(in: state, host: host.id, session: session.id, window: window.id)
                    model.requestCloseWindow(in: state, skippingConfirmation: OptionKey.isHeld)
                }
            }
        }
        .padding(.leading, 32)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? ContrastPolicy.selectionFill(contrast) : Color.clear)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(ContrastPolicy.selectionBorder(contrast), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering(rowKey, $0) }
        .accessibilityLabel("Window \(label), \(window.paneCount) panes")
    }

    @ViewBuilder
    private func windowMenu(host: HostState, session: TmuxSession, window: TmuxWindow) -> some View {
        Group {
            Button("Rename Window…") {
                model.requestRenameWindow(in: state, hostId: host.id, windowId: window.id)
            }
            Button("Open in New Window") {
                model.showSession(
                    hostId: host.id, sessionId: session.id, windowId: window.id,
                    collapseSidebar: true, preferNewWindow: true
                )
            }
            // The same two items the tab carries: a window is the same thing in both places, and a
            // command that exists on one and not the other is the kind of gap that makes a tree feel
            // unrelated to the content beside it.
            WindowSessionMenus(
                model: model, hostId: host.id, sessionId: session.id, windowId: window.id
            )
            Divider()
            Button("Close Window…", role: .destructive) {
                model.select(in: state, host: host.id, session: session.id, window: window.id)
                model.requestCloseWindow(in: state)
            }
        }
    }

    /// Which way the window's outermost seam runs, or `nil` when it has a single pane.
    ///
    /// The *root* container and no deeper one: the icon draws one rule, and the rule it should draw
    /// is the split the user would see first. A nested seam has no room to be shown at 13px and
    /// would contradict the outer one if it were.
    static func splitAxis(_ window: TmuxWindow) -> SplitDirection? {
        guard case .container(let direction, _, _, _, _, _) = window.layoutTree else {
            // No layout yet. `list-panes` can already say there are several, so say *divided* rather
            // than lying about a window that is about to redraw as one — the axis is a guess only
            // until the first `%layout-change`, which is the very next thing to arrive.
            return window.paneCount > 1 ? .leftRight : nil
        }
        return direction
    }

    // MARK: - Row actions

    /// The trailing action group of a row.
    ///
    /// One place for the spacing rules so they cannot drift back into per-row variation, which is what
    /// this replaced: every row's right edge used to space, size and reveal its buttons differently.
    private func rowActions<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: RowAction.gap, content: content)
            .padding(.trailing, RowAction.edgeInset)
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

/// Geometry every sidebar control shares.
///
/// Constants rather than literals at each call site, because the thing being fixed was that the rows
/// disagreed with each other: a 12px glyph here, a 14px hit box there, and buttons flush against the
/// scroller on one row and inset on the next.
private enum RowAction {
    /// The hit target. A bare glyph is not one — 22pt is.
    static let size: CGFloat = 22
    static let radius: CGFloat = 5
    /// Between the additive button and the destructive one. `+` and `✕` are never adjacent.
    static let gap: CGFloat = 6
    /// From the sidebar's inner edge, so nothing sits flush against the scroller.
    static let edgeInset: CGFloat = 6
    /// Opacity only, and short. Anything that changes layout would shuffle the tree under the pointer.
    static let reveal = Animation.easeInOut(duration: 0.12)

    /// Under the pointer, and only there — a button has no frame and no fill at rest.
    ///
    /// One rule rather than a plain and a selected variant, because a translucent darkening composites
    /// correctly over either: on the sidebar material it is the spec's `#dedee1`, and on a selected
    /// row's accent tint it is that tint a comparable step darker, which is what the spec asks for
    /// there. A literal pair of hex fills would have to be chosen against a background this control
    /// cannot see, and would invert wrongly in dark mode besides.
    static func hoverFill(_ contrast: ColorSchemeContrast) -> Color { ContrastPolicy.hoverFill(contrast) }
}

/// The line weight and slot width shared by everything the sidebar *draws* rather than sets in a font.
private enum TreeIcon {
    /// One weight across the tree icons and the row buttons alike, so a row has a single line weight
    /// from its leading glyph to its trailing action. SF Symbols was the thing breaking that: its
    /// strokes are tuned per symbol and came out heavier than anything drawn beside them.
    static let stroke: CGFloat = 1.3
    /// Reserved on every window row, split or not, so all the names in a session start at the same x.
    static let slot: CGFloat = 13
}

/// A small action on a sidebar row.
///
/// Always laid out and only sometimes visible: hiding it outright would resize the row under the
/// pointer, and the tree would shuffle as the mouse crossed it — the same reason the tab bar's close
/// button works this way. The reveal is therefore opacity and nothing else.
///
/// Unframed and unfilled at rest, so the 22pt hit target is invisible until the pointer is on the
/// button itself. The framed version this replaced put a bordered box on every revealed row, which on
/// a hovered or selected row — already tinted — stacked two rectangles of chrome behind a glyph and
/// made the right edge of the tree the loudest thing in it.
private struct RowButton: View {
    let glyph: RowActionGlyph.Kind
    let help: String
    let isVisible: Bool
    /// ⌥ is down, so this button will act rather than ask.
    ///
    /// Said in colour rather than as a different glyph. The two glyphs in the tree are the same two
    /// rules at two rotations precisely so they weigh the same, and a third shape drawn to sit
    /// between them would have to be matched all over again for a state that lasts as long as a key
    /// is held. Red is also the one thing here that reads at a glance as *this does not come back*.
    var isArmed: Bool = false
    let action: () -> Void

    /// §7 — Reduce Motion. The reveal is the only animation in the tree, and its whole job is to keep
    /// a button from appearing abruptly under the pointer; with the preference on, appearing abruptly
    /// is what the user has asked for.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    /// Red is the *only* thing saying this click will not stop to ask, which is precisely the kind of
    /// signal this preference exists to replace.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            RowActionGlyph(kind: glyph, isEmphasised: saysArmedWithoutColour)
                .foregroundStyle(tint)
                .frame(width: RowAction.size, height: RowAction.size)
                .background(
                    RoundedRectangle(cornerRadius: RowAction.radius)
                        .fill(chipFill)
                )
                .contentShape(RoundedRectangle(cornerRadius: RowAction.radius))
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        .animation(reduceMotion ? nil : RowAction.reveal, value: isVisible)
        .allowsHitTesting(isVisible)
        .onHover { isHovered = $0 && isVisible }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityHidden(!isVisible)
    }

    private var tint: AnyShapeStyle {
        if isArmed { return AnyShapeStyle(Color.red) }
        return AnyShapeStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }

    /// §7 — `differentiateWithoutColor`, and only then: red alone says this click will not stop to
    /// ask, and that is the whole content of the state.
    private var saysArmedWithoutColour: Bool { isArmed && differentiateWithoutColor }

    /// The chip behind the glyph, which is the part that actually carries "armed" without hue.
    ///
    /// Filling the button's own background rather than adding a shape: this control already has that
    /// rounded rectangle for hover, so arming it is a state of something already on screen instead of
    /// a new element appearing under the pointer. The heavier rule alone was measured and is not
    /// enough — 45 inked pixels to 65 on an 11×11 glyph drawn in `.secondary`, which reads offscreen
    /// and does not read on a row.
    private var chipFill: Color {
        if saysArmedWithoutColour { return Color.primary.opacity(0.30) }
        return isHovered ? RowAction.hoverFill(contrast) : Color.clear
    }
}

/// The `+` and the `✕` on a row action, drawn as rules rather than set from SF Symbols.
///
/// Both are the *same two rules*, one pair crossed at right angles and one pair rotated 45°, which is
/// the only way the two buttons weigh the same. `Image(systemName: "xmark")` beside
/// `Image(systemName: "plus")` does not: a diagonal stroke lays more ink across a row of pixels than an
/// axis-aligned one, so the `✕` read as heavier at every point size and every weight the two were
/// tried at. Rotating leaves the ✕ spanning 8pt where the + spans 11 — that is the optical match, not
/// a mistake to correct.
private struct RowActionGlyph: View {
    enum Kind { case plus, cross }

    let kind: Kind
    /// Draws the same glyph at a heavier stroke, for `differentiateWithoutColor` (§7).
    ///
    /// Weight rather than a third shape, which keeps the reasoning above intact: the two glyphs are
    /// the same two rules at two rotations *because* that is the only way they weigh the same, and a
    /// distinct armed shape would have to be matched against both all over again — for a state that
    /// lasts exactly as long as a key is held. Heavier says "more of what this already is", which is
    /// what arming means.
    ///
    /// Measured, because it is not enough on its own: doubling the rule takes an 11×11 glyph from 45
    /// inked pixels to 65 at 1×, which is a real difference offscreen and did not read on a row where
    /// the glyph is drawn in `.secondary`. So the caller pairs this with a filled chip behind the
    /// button — this is the part that keeps the *glyph* consistent with the chip, not the signal.
    var isEmphasised: Bool = false

    /// The rule length before rotation.
    private static let length: CGFloat = 11

    var body: some View {
        ZStack {
            rule.rotationEffect(.degrees(kind == .plus ? 0 : 45))
            rule.rotationEffect(.degrees(kind == .plus ? 90 : -45))
        }
        .frame(width: Self.length, height: Self.length)
    }

    private var rule: some View {
        Capsule().frame(
            width: Self.length,
            height: isEmphasised ? TreeIcon.stroke * 2 : TreeIcon.stroke
        )
    }
}

/// A session: windows layered behind one another, and the only layered glyph in the tree.
///
/// Two 11×8 rectangles, the front one offset 4 down and right (§2).
private struct SessionStackIcon: View {
    private static let rect = CGSize(width: 11, height: 8)
    private static let offset: CGFloat = 4
    /// Clearance cut around the front rectangle. Without it the two merge into a filled blob at this
    /// size — the failure the spec warns about, and it is worst on the selection tint.
    private static let clearance: CGFloat = 1.3

    var body: some View {
        ZStack(alignment: .topLeading) {
            outline
            // The gap, cut out rather than painted.
            //
            // The spec calls for a background-coloured fill, but a sidebar row has no one background:
            // it is the sidebar material, or a hover highlight, or the selection tint over either, and
            // painting the wrong one shows as a pale smear across the rear window. `destinationOut`
            // erases to transparent instead, so whatever the row is actually sitting on shows through
            // and the icon needs to know nothing about it.
            //
            // Filled with an explicit opaque colour, and that is the whole trick rather than a detail.
            // `destinationOut` removes destination alpha *in proportion to the source's*, so an eraser
            // that inherits the ambient `foregroundStyle` erases only as much as that style is opaque —
            // and `Color.secondary` is translucent. The live icon (accent, fully opaque) cut a clean
            // gap while every idle one was left with a half-erased grey smear across both rectangles:
            // precisely the blob the spec warns about, arrived at from the other direction. Which
            // colour is irrelevant, only its alpha.
            shape
                .fill(Color.black)
                .frame(
                    width: Self.rect.width + Self.clearance * 2,
                    height: Self.rect.height + Self.clearance * 2
                )
                .offset(x: Self.offset - Self.clearance, y: Self.offset - Self.clearance)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .overlay(alignment: .topLeading) {
            outline.offset(x: Self.offset, y: Self.offset)
        }
        .frame(
            width: Self.rect.width + Self.offset,
            height: Self.rect.height + Self.offset,
            alignment: .topLeading
        )
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 1.5) }

    private var outline: some View {
        shape
            .strokeBorder(lineWidth: TreeIcon.stroke)
            .frame(width: Self.rect.width, height: Self.rect.height)
    }
}

/// A tmux window: one rectangle, divided along its outermost seam when the window is split.
///
/// The three levels of the tree then differ by *structure* rather than by decoration — layered
/// contains windows, plain is one pane, divided is a split — which is what makes them tell apart at
/// 13px on a selected row, where colour says nothing.
private struct WindowPaneIcon: View {
    /// `nil` when the window has a single pane.
    let split: SplitDirection?

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .strokeBorder(lineWidth: TreeIcon.stroke)
            // Half the box is filled when the window is split.
            //
            // A hairline rule was the only difference between split and not, and at 13px on a row
            // that may also be tinted by selection it was very nearly nothing — the two icons read as
            // the same rectangle. A filled half is a difference in *area* rather than in one line, so
            // it survives the size, the tint, and a quick glance down the list. The fill's edge is
            // the seam, and the rule stays on top of it to keep that edge crisp against the tint.
            .background(alignment: split == .leftRight ? .leading : .top) {
                if let split {
                    GeometryReader { geometry in
                        Rectangle()
                            // Weighted by eye at 13px rather than picked as a round number: at 0.22
                            // the fill was legible when magnified and very nearly absent at the size
                            // it is actually drawn, which is the failure this change exists to undo.
                            // The fill *is* the split/not-split distinction, so Increase Contrast
                            // takes it further still rather than leaving the two icons alike.
                            .fill(.primary.opacity(contrast == .increased ? 0.60 : 0.32))
                            .frame(
                                width: split == .leftRight ? geometry.size.width / 2 : geometry.size.width,
                                height: split == .leftRight ? geometry.size.height : geometry.size.height / 2
                            )
                    }
                }
            }
            // Composited, so the fill is clipped to the same rounded corners as the border rather
            // than squaring them off.
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay {
                if let split {
                    // Centred rather than placed at the real ratio: the rule is the *fact* of a split,
                    // and a 13px box cannot show 70/30 as anything but off-centre noise.
                    Rectangle().frame(
                        width: split == .leftRight ? TreeIcon.stroke : nil,
                        height: split == .leftRight ? nil : TreeIcon.stroke
                    )
                }
            }
            .frame(width: TreeIcon.slot, height: 10)
    }
}

/// A view control in the `HOSTS` header: one click, 22pt, no frame.
///
/// Unframed on purpose, unlike `RowButton`. These sit on the header's own background rather than on a
/// highlighted row, so there is nothing for a frame to separate them from.
private struct HeaderButton<Icon: View>: View {
    let help: String
    let label: String
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            icon()
                .frame(width: RowAction.size, height: RowAction.size)
                .background(
                    RoundedRectangle(cornerRadius: RowAction.radius)
                        .fill(isHovered ? ContrastPolicy.hoverFill(contrast) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: RowAction.radius))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}

/// Collapse all and Expand all, as a stack of rules.
///
/// SF Symbols has no pair that survives this size: `chevron.down.square` and `chevron.right.square`
/// differ by the rotation of a 4pt chevron inside a box, which at 11pt is two identical grey squares —
/// you had to click one to learn what it did. Rules stacked with a gap read as *closed up*, and a
/// third shorter rule appearing between them reads as something opening, which is the actual
/// difference between the two commands.
private struct RuleStackIcon: View {
    let showsMiddleRule: Bool

    var body: some View {
        VStack(spacing: 2) {
            rule(width: 10)
            if showsMiddleRule { rule(width: 5) }
            rule(width: 10)
        }
        .foregroundStyle(.secondary)
    }

    private func rule(width: CGFloat) -> some View {
        Capsule().frame(width: width, height: 1.4)
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
