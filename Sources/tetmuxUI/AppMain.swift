import AppKit
import SwiftUI
import tetmuxCore

public struct TetmuxApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(TetmuxAppDelegate.self) private var appDelegate

    public init() {}

    public var body: some Scene {
        WindowGroup(id: RootScene.mainWindowId) {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                .task { await model.bootstrap() }
        }
        .windowToolbarStyle(.unified)
        .commands { menuCommands }

        // F4.12 — a tmux window or a whole session, torn off into its own macOS window. Keyed by
        // value, so re-opening a scene that is already on screen brings that window forward instead of
        // making a second one. Every one of these shares the host's single channel with the main
        // window; nothing here opens a second tmux client.
        WindowGroup(id: DetachedScene.windowGroupId, for: DetachedScene.self) { $scene in
            if let scene {
                DetachedWindowView(model: model, scene: scene)
            }
        }

        // F4.30 — every known session, attachable without bringing the main window forward.
        MenuBarExtra("tetmux", systemImage: "terminal.fill") {
            MenuBarContent(model: model)
        }
    }

    /// Menu items are built from `KeymapPolicy` so the documented keymap and what the application
    /// actually intercepts cannot drift apart (F4.22).
    @CommandsBuilder
    private var menuCommands: some Commands {
        let keymap = model.keymap

        CommandGroup(replacing: .newItem) {
            Button(ApplicationShortcut.newWindow.title) { model.newWindow() }
                .keyboardShortcut(.newWindow, in: keymap)
            Button(ApplicationShortcut.splitRight.title) { model.split(leftRight: true) }
                .keyboardShortcut(.splitRight, in: keymap)
            Button(ApplicationShortcut.splitDown.title) { model.split(leftRight: false) }
                .keyboardShortcut(.splitDown, in: keymap)
        }
        CommandGroup(replacing: .textEditing) {
            // Pastes go through tmux's buffer commands, not send-keys, so a large paste is one
            // round trip rather than a megabyte of command line (§3.2).
            Button(ApplicationShortcut.paste.title) { model.pasteIntoFocusedPane() }
                .keyboardShortcut(.paste, in: keymap)
        }
        CommandMenu("Session") {
            Button(ApplicationShortcut.launcher.title) { model.isLauncherPresented.toggle() }
                .keyboardShortcut(.launcher, in: keymap)
            Divider()
            Button(ApplicationShortcut.renameWindow.title) { model.requestRenameWindow() }
                .keyboardShortcut(.renameWindow, in: keymap)
            Button(ApplicationShortcut.renameSession.title) { model.requestRenameSession() }
                .keyboardShortcut(.renameSession, in: keymap)
            Divider()
            // F4.12 — acts on the frontmost window's subject, like every other command here.
            Button("Open in New macOS Window") { model.detachActiveWindow() }
            Divider()
            Button(ApplicationShortcut.closeWindow.title) { model.requestCloseWindow() }
                .keyboardShortcut(.closeWindow, in: keymap)
            Button(ApplicationShortcut.closePane.title) { model.closePane() }
                .keyboardShortcut(.closePane, in: keymap)
        }
    }
}

/// A SwiftPM executable has no app bundle, so nothing sets the activation policy for us; without
/// this the window opens behind everything and never takes focus.
public final class TetmuxAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The menu bar extra (F4.30) is the point of staying resident.
        false
    }
}

/// Scene identifiers. The main window needs an explicit one so a detached window can bring it forward
/// when its content is merged back.
public enum RootScene {
    public static let mainWindowId = "tetmux.main"
}

struct RootView: View {
    @Bindable var model: AppModel
    @State private var newSessionName = ""
    /// This window's identity for size ownership (§3.3).
    @State private var owner = UUID()
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            detail
        }
        .overlay {
            LauncherOverlay(isPresented: $model.isLauncherPresented, items: model.launcherItems())
        }
        // The main window is the default subject of every menu command; taking focus is what makes it
        // so again after a torn-off window claimed that role.
        .onChange(of: controlActiveState) { _, state in
            if state == .key { model.frontmostScope = nil }
        }
        .onChange(of: model.requestedDetachScene) { _, requested in
            guard let requested else { return }
            model.requestedDetachScene = nil
            openWindow(id: DetachedScene.windowGroupId, value: requested)
        }
        .sheet(item: $model.hostDraft) { draft in
            HostEditorView(
                draft: draft,
                onSave: { model.saveHost($0, password: $1, savePassword: $2) },
                onCancel: { model.hostDraft = nil }
            )
        }
        .sheet(item: $model.pendingAuthentication) { pending in
            AuthenticationSheet(
                pending: pending,
                onSubmit: { model.submitAuthentication(secret: $0, saveInKeychain: $1) },
                onCancel: { model.cancelAuthentication() }
            )
        }
        .sheet(item: $model.pendingClose) { pending in
            DestructiveActionModal(
                title: "Close Window",
                targetName: pending.windowName,
                paneCount: pending.paneCount,
                runningCommands: pending.runningCommands,
                onConfirm: { model.confirmCloseWindow() },
                onCancel: { model.pendingClose = nil }
            )
        }
        .sheet(item: $model.pendingRename) { pending in
            RenameSheet(
                pending: pending,
                onCommit: { model.commitRename(to: $0) },
                onCancel: { model.pendingRename = nil }
            )
        }
        .sheet(item: Binding(
            get: { model.newSessionTarget.map { NewSessionTarget(hostId: $0) } },
            set: { if $0 == nil { model.newSessionTarget = nil } }
        )) { target in
            newSessionSheet(hostId: target.hostId)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let host = model.selectedHost, let session = model.selectedSession, let window = model.selectedWindow {
            VStack(spacing: 0) {
                // The panes stay on screen when a channel dies — they hold real scrollback and the
                // window list is still meaningful — so this is the only place the user is told the
                // terminal in front of them is frozen, and the only reconnect they can reach
                // without knowing the sidebar dot is clickable.
                ConnectionBanner(state: host.connectionState) { model.reconnect(host.id) }
                WindowTabBar(model: model, session: session)
                Divider()
                TerminalContainerView(
                    hostId: host.id,
                    window: window,
                    theme: model.theme,
                    service: model.service,
                    focusedPaneId: $model.focusedPaneId,
                    owner: owner
                )
                Divider()
                StatusBarView(host: host, session: session, window: window, focusedPaneId: model.focusedPaneId)
            }
        } else if let host = model.selectedHost {
            HostPlaceholderView(host: host) { model.reconnect(host.id) }
        } else {
            EmptyStateView { model.presentNewHost() }
        }
    }

    // MARK: - Sheets

    private func newSessionSheet(hostId: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session").font(.headline)
            TextField("Session name", text: $newSessionName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel") { model.newSessionTarget = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.createSession(hostId: hostId, name: newSessionName)
                    newSessionName = ""
                    model.newSessionTarget = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newSessionName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

private struct NewSessionTarget: Identifiable {
    var id: String { hostId }
    let hostId: String
}

/// F4.6 — one application tab per tmux window.
struct WindowTabBar: View {
    @Bindable var model: AppModel
    let session: TmuxSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(session.windows) { window in
                        tab(window)
                    }
                }
                .padding(.horizontal, 6)
            }

            Divider().frame(height: 18)

            Group {
                Button { model.newWindow() } label: { Image(systemName: "plus") }
                    .help("New window (⌘T)")
                Button { model.split(leftRight: true) } label: { Image(systemName: "rectangle.split.2x1") }
                    .help("Split right (⌘D)")
                Button { model.split(leftRight: false) } label: { Image(systemName: "rectangle.split.1x2") }
                    .help("Split down (⇧⌘D)")
                Button { model.requestCloseWindow() } label: { Image(systemName: "xmark") }
                    .help("Close window (⇧⌘W)")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 4)
        }
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func tab(_ window: TmuxWindow) -> some View {
        let isSelected = window.id == model.selectedWindowId
        return Button {
            model.select(host: model.selectedHostId ?? "", session: session.id, window: window.id)
        } label: {
            HStack(spacing: 5) {
                if window.hasActivity && !isSelected {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                }
                Text(window.name).lineLimit(1)
                if window.paneCount > 1 {
                    Text("\(window.paneCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
        // Double-click to rename, as a tab bar is expected to. `simultaneousGesture` rather than
        // `onTapGesture`, so the button's own click handling is not replaced — the first click still
        // selects the tab, which is what makes renaming the tab you just double-clicked correct.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.requestRenameWindow(hostId: model.selectedHostId, windowId: window.id)
        })
        .accessibilityLabel("Window \(window.name), \(window.paneCount) panes")
        .contextMenu {
            Button("Rename Window…") {
                model.requestRenameWindow(hostId: model.selectedHostId, windowId: window.id)
            }
            Button("Open in New Window") {
                guard let hostId = model.selectedHostId else { return }
                openWindow(
                    id: DetachedScene.windowGroupId,
                    value: DetachedScene(hostId: hostId, sessionId: session.id, windowId: window.id)
                )
            }
            Divider()
            Button("Close Window…", role: .destructive) {
                model.select(host: model.selectedHostId ?? "", session: session.id, window: window.id)
                model.requestCloseWindow()
            }
        }
    }
}

/// Shown above the tab bar whenever the channel behind the visible panes is not healthy.
///
/// Automatic recovery is best-effort: ssh takes its keepalive interval to notice a dead link, and
/// the backoff gives up after eight attempts (F4.14). The button is the guaranteed path — the user
/// knows they are back on the right network long before we can infer it.
struct ConnectionBanner: View {
    let state: ConnectionState
    let onReconnect: () -> Void

    var body: some View {
        if let message {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if case .connecting = state {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    // §7 — whatever ssh or tmux said, verbatim, not a paraphrase of it.
                    Text(message)
                        .font(.caption)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    Spacer(minLength: 8)

                    if showsButton {
                        Button("Reconnect", action: onReconnect)
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.14))
                Divider()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Connection \(state.accessibilityDescription)")
        }
    }

    private var message: String? {
        switch state {
        case .connected:
            return nil
        case .connecting:
            return "Connecting…"
        case .disconnected:
            return "Disconnected — the panes below are a snapshot and are not live."
        case .reconnecting(let attempt, let seconds):
            return "Connection lost. Reconnecting (attempt \(attempt), retrying in \(Int(seconds))s)…"
        case .degraded(let reason):
            return reason
        case .failed(let reason):
            return reason
        }
    }

    /// Nothing to offer while a connect is already in flight.
    private var showsButton: Bool {
        if case .connecting = state { return false }
        return true
    }
}

struct HostPlaceholderView: View {
    let host: HostState
    let onConnect: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: host.config.isLocal ? "laptopcomputer" : "server.rack")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(host.config.name).font(.title2).fontWeight(.semibold)

            switch host.connectionState {
            case .connecting:
                ProgressView("Connecting…").controlSize(.small)
            case .reconnecting(let attempt, let seconds):
                ProgressView("Reconnecting (attempt \(attempt), retrying in \(Int(seconds))s)…")
                    .controlSize(.small)
            case .failed(let reason), .degraded(let reason):
                // §7 — show what ssh or tmux actually said, not a paraphrase.
                ScrollView {
                    Text(reason)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 560, maxHeight: 160)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                Button("Retry", action: onConnect).buttonStyle(.borderedProminent)
            case .connected:
                Text("Connected — no sessions yet.").foregroundStyle(.secondary)
            case .disconnected:
                Button("Connect", action: onConnect).buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    let onAddHost: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("tetmux").font(.title).fontWeight(.semibold)
            Text("Select a host in the sidebar, or press ⌘K.")
                .foregroundStyle(.secondary)
            Button("Add SSH Host…", action: onAddHost)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MenuBarContent: View {
    @Bindable var model: AppModel

    var body: some View {
        ForEach(model.hosts) { host in
            Section(host.config.name) {
                if host.sessions.isEmpty {
                    Button("Connect") { model.connect(host.id) }
                } else {
                    ForEach(host.sessions) { session in
                        Button(session.name) {
                            model.select(host: host.id, session: session.id, window: session.activeWindow?.id)
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                }
            }
        }
        Divider()
        Button("Quit tetmux") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
