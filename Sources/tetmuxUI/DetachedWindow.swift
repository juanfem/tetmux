import AppKit
import SwiftUI
import tetmuxCore

/// What a torn-off macOS window is showing (F4.12).
///
/// The value identity is what SwiftUI keys the window on, so asking for a scene that is already open
/// brings that window forward instead of opening a second copy of it.
public struct DetachedScene: Codable, Hashable, Identifiable, Sendable {
    public static let windowGroupId = "tetmux.detached"

    public var hostId: String
    /// `$id`
    public var sessionId: String
    /// `@id`, or nil for the whole session — which gets its own tab bar.
    public var windowId: String?

    public var id: String { "\(hostId)|\(sessionId)|\(windowId ?? "*")" }

    public init(hostId: String, sessionId: String, windowId: String? = nil) {
        self.hostId = hostId
        self.sessionId = sessionId
        self.windowId = windowId
    }
}

/// One tmux window, or one session's worth of them, in its own macOS window.
///
/// Shares the host's single control-mode channel with the main window — no second tmux client is
/// created, so this costs nothing on the server and cannot desynchronise from what the main window
/// sees. What it *cannot* do is make a second session live: control mode streams `%output` only for
/// the attached session, so a window showing any other session says so and offers to switch.
struct DetachedWindowView: View {
    let model: AppModel
    let scene: DetachedScene

    /// Per-window state. Deliberately not the model's: two windows sharing a selection or a focused
    /// pane would move each other's keyboard focus, and a sheet bound to shared state tries to present
    /// itself in both windows at once.
    @State private var selectedWindowId: String?
    @State private var focusedPaneId: String?
    @State private var owner = UUID()
    @State private var pendingRename: AppModel.PendingRename?
    @State private var pendingClose: AppModel.PendingClose?

    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    private var host: HostState? {
        model.hosts.first { $0.id == scene.hostId }
    }

    private var session: TmuxSession? {
        host?.sessions.first { $0.id == scene.sessionId }
    }

    /// Whether the client is attached to this session — the thing that decides if panes are live.
    /// `session_attached` counts every client including other people's, so the attached *session id*
    /// this client reported is the only trustworthy signal.
    private var isLive: Bool {
        host?.activeSessionId == scene.sessionId
    }

    private var window: TmuxWindow? {
        guard let session else { return nil }
        if let fixed = scene.windowId {
            return session.windows.first { $0.id == fixed }
        }
        return session.windows.first { $0.id == selectedWindowId } ?? session.activeWindow
    }

    var body: some View {
        Group {
            if let host, let session, let window {
                content(host: host, session: session, window: window)
            } else {
                gonePlaceholder
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .navigationTitle(title)
        .onChange(of: controlActiveState) { _, state in
            guard state == .key else { return }
            publishScope()
        }
        .onAppear { if controlActiveState == .key { publishScope() } }
        .onChange(of: focusedPaneId) { _, _ in if controlActiveState == .key { publishScope() } }
        .onChange(of: selectedWindowId) { _, _ in if controlActiveState == .key { publishScope() } }
        .sheet(item: $pendingRename) { pending in
            RenameSheet(
                pending: pending,
                onCommit: { model.commit(pending, to: $0); pendingRename = nil },
                onCancel: { pendingRename = nil }
            )
        }
        .sheet(item: $pendingClose) { pending in
            DestructiveActionModal(
                title: "Close Window",
                targetName: pending.windowName,
                paneCount: pending.paneCount,
                runningCommands: pending.runningCommands,
                onConfirm: {
                    model.killWindow(hostId: pending.hostId, windowId: pending.windowId)
                    pendingClose = nil
                    // A window-scoped scene has nothing left to show once its window is gone.
                    if scene.windowId != nil { dismissWindow() }
                },
                onCancel: { pendingClose = nil }
            )
        }
    }

    private var title: String {
        guard let session else { return "tetmux" }
        guard let window else { return session.name }
        return scene.windowId == nil ? "\(session.name) — \(window.name)" : window.name
    }

    /// Tells the model what this window is showing, so application-wide menu commands act on it while
    /// it is frontmost rather than on the main window's sidebar selection.
    private func publishScope() {
        model.frontmostScope = AppModel.Scope(
            hostId: scene.hostId,
            sessionId: scene.sessionId,
            windowId: window?.id,
            paneId: focusedPaneId ?? window?.preferredPaneId
        )
    }

    @ViewBuilder
    private func content(host: HostState, session: TmuxSession, window: TmuxWindow) -> some View {
        VStack(spacing: 0) {
            ConnectionBanner(state: host.connectionState) { model.reconnect(host.id) }
            // §7 — a refusal is a property of the host, so it belongs in whichever window is in front
            // when it happens, not only the main one.
            CommandFailureBanner(failure: host.lastCommandFailure) {
                model.dismissCommandFailure(host.id)
            }

            if !isLive {
                notAttachedBanner(host: host, session: session)
            }

            header(host: host, session: session, window: window)
            Divider()

            TerminalContainerView(
                hostId: host.id,
                window: window,
                theme: model.theme,
                service: model.service,
                focusedPaneId: $focusedPaneId,
                owner: owner,
                // The main window owns the client size; below tmux 2.9 that is the only size there is.
                drivesClientSize: false
            )

            Divider()
            StatusBarView(host: host, session: session, window: window, focusedPaneId: focusedPaneId)
        }
    }

    /// The honest version of what a single channel can do: this session's panes are a snapshot until
    /// the client moves here, and moving it freezes whatever session was attached before.
    private func notAttachedBanner(host: HostState, session: TmuxSession) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Not attached — these panes are a snapshot. tmux streams output for one session per connection.")
                    .font(.caption)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Attach Here") {
                    model.attachHere(hostId: host.id, sessionId: session.id)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .help("Moves this connection to \(session.name). Windows of \(host.activeSession?.name ?? "the other session") become snapshots.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.14))
            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Not attached. These panes are a snapshot.")
    }

    // MARK: - Header

    @ViewBuilder
    private func header(host: HostState, session: TmuxSession, window: TmuxWindow) -> some View {
        HStack(spacing: 0) {
            if scene.windowId == nil {
                // Session scope: the session's windows as tabs, exactly as the main window shows them.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(session.windows) { candidate in
                            tab(candidate, host: host, session: session, isSelected: candidate.id == window.id)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "macwindow.on.rectangle").font(.caption).foregroundStyle(.secondary)
                    Text(window.name).font(.subheadline).lineLimit(1)
                    Text(session.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.leading, 10)
                .contextMenu { windowMenu(host: host, session: session, window: window) }
            }

            Spacer(minLength: 8)
            Divider().frame(height: 18)

            Group {
                Button { model.split(leftRight: true) } label: { Image(systemName: "rectangle.split.2x1") }
                    .help("Split right (⌘D)")
                Button { model.split(leftRight: false) } label: { Image(systemName: "rectangle.split.1x2") }
                    .help("Split down (⇧⌘D)")
                Button { mergeBack(window: window) } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .help("Move back into the main window")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 4)
        }
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func tab(_ candidate: TmuxWindow, host: HostState, session: TmuxSession, isSelected: Bool) -> some View {
        Button {
            // Local state only. Calling `model.select` here would drag the main window's view onto this
            // tab as well, and it is not needed for liveness: `%output` arrives for every pane of the
            // attached session, not just the current window's.
            selectedWindowId = candidate.id
            focusedPaneId = nil
        } label: {
            HStack(spacing: 5) {
                if candidate.hasActivity && !isSelected {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                }
                Text(candidate.name).lineLimit(1)
                if candidate.paneCount > 1 {
                    Text("\(candidate.paneCount)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            pendingRename = model.renameRequest(hostId: host.id, window: candidate)
        })
        .accessibilityLabel("Window \(candidate.name), \(candidate.paneCount) panes")
        .contextMenu { windowMenu(host: host, session: session, window: candidate) }
    }

    @ViewBuilder
    private func windowMenu(host: HostState, session: TmuxSession, window: TmuxWindow) -> some View {
        Button("Rename Window…") {
            pendingRename = model.renameRequest(hostId: host.id, window: window)
        }
        Button("Move Back to Main Window") { mergeBack(window: window) }
        Divider()
        Button("Close Window…", role: .destructive) {
            pendingClose = model.closeRequest(hostId: host.id, window: window)
        }
    }

    /// F4.12 — the reverse of tearing off. Selects the window in the main window, brings it forward,
    /// and closes this one.
    private func mergeBack(window: TmuxWindow) {
        model.select(host: scene.hostId, session: scene.sessionId, window: window.id)
        model.frontmostScope = nil
        openWindow(id: RootScene.mainWindowId)
        dismissWindow()
    }

    // MARK: - Gone

    /// The session or window this scene points at no longer exists — killed here, or by someone else on
    /// the server. There is nothing to show and nothing to reconnect to.
    private var gonePlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(host == nil ? "This host is no longer configured." : "This \(scene.windowId == nil ? "session" : "window") is gone.")
                .font(.headline)
            if host?.connectionState.isActive == false {
                Text("The host is not connected, so its topology is the last one seen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Close Window") { dismissWindow() }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
