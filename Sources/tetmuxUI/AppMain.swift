import AppKit
import SwiftUI
import tetmuxCore

public struct TetmuxApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(TetmuxAppDelegate.self) private var appDelegate

    public init() {}

    public var body: some Scene {
        // A `WindowGroup` has always been able to open more than one window; what stopped it being
        // useful was that every one of them shared `AppModel`'s single selection and single set of
        // sheets. `RootView` owns a `WindowState` per window now, so ⌘N is a real second window
        // rather than a second view of the same one.
        WindowGroup(id: RootScene.mainWindowId) {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                .task { await model.bootstrap() }
        }
        .windowToolbarStyle(.unified)
        .commands { menuCommands }

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
            // A second window of the application, which is what ⌘N means everywhere else. The
            // `newWindow` item below it is the tmux one, which this app shows as a tab (item 11).
            NewAppWindowButton(title: ApplicationShortcut.newAppWindow.title)
                .keyboardShortcut(.newAppWindow, in: keymap)
            Divider()
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
            Button(ApplicationShortcut.launcher.title) { model.toggleLauncherFromMenu() }
                .keyboardShortcut(.launcher, in: keymap)
            Divider()
            Button(ApplicationShortcut.renameWindow.title) { model.requestRenameWindowFromMenu() }
                .keyboardShortcut(.renameWindow, in: keymap)
            Button(ApplicationShortcut.renameSession.title) { model.requestRenameSessionFromMenu() }
                .keyboardShortcut(.renameSession, in: keymap)
            Divider()
            // F4.12 — acts on the frontmost window's subject, like every other command here.
            Button("Open in New Window") { model.detachActiveWindow() }
            Divider()
            Button(ApplicationShortcut.closeWindow.title) { model.requestCloseWindowFromMenu() }
                .keyboardShortcut(.closeWindow, in: keymap)
            Button(ApplicationShortcut.closePane.title) { model.closePane() }
                .keyboardShortcut(.closePane, in: keymap)
        }
    }
}

/// ⌘N, as a view rather than a bare `Button`.
///
/// `openWindow` is an `@Environment` action and `Commands` has no environment to read it from, so the
/// menu item has to be something that does. `AppModel.requestedWindow` works around the same
/// restriction for windows the model asks for; this needs no round trip because it opens a plain
/// window with nothing to seed it with.
private struct NewAppWindowButton: View {
    let title: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) { openWindow(id: RootScene.mainWindowId) }
    }
}

/// A SwiftPM executable has no app bundle, so nothing sets the activation policy for us; without
/// this the window opens behind everything and never takes focus.
public final class TetmuxAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Otherwise a second window opens as a *tab* of the first, which is AppKit's default and is
        // wrong for this app twice over: ⌥-clicking a session in the menu bar asks for a window and got
        // a tab, and a tab bar full of macOS tabs sits directly above the tab bar of tmux windows,
        // which are the tabs this app is actually about.
        NSWindow.allowsAutomaticWindowTabbing = false

        // A packaged build gets its Dock icon from CFBundleIconFile, but `swift run` has no bundle to
        // read one from and comes up as a generic executable. Setting it by hand covers that case; in
        // the .app it just re-asserts the icon already on screen.
        if let url = Bundle.module.url(forResource: "tetmux", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The menu bar extra (F4.30) is the point of staying resident.
        false
    }
}

/// Scene identifiers. Explicit because windows are opened by id from the menu, from the sidebar, and
/// from the menu bar extra.
public enum RootScene {
    public static let mainWindowId = "tetmux.main"
}

struct RootView: View {
    @Bindable var model: AppModel

    /// This window's own selection, sheets, and §3.3 size-ownership identity. One per macOS window —
    /// see `WindowState` for why sharing it amounted to two separate bugs.
    @State private var state = WindowState()

    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openWindow) private var openWindow

    private var host: HostState? { state.selectedHost(in: model.hosts) }
    private var session: TmuxSession? { state.selectedSession(in: model.hosts) }
    private var window: TmuxWindow? { state.selectedWindow(in: model.hosts) }

    var body: some View {
        NavigationSplitView(columnVisibility: $state.sidebarVisibility) {
            SidebarView(model: model, state: state)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            detail
        }
        .overlay {
            LauncherOverlay(isPresented: $state.isLauncherPresented, items: model.launcherItems(for: state))
        }
        // Item 9 needs to bring a *particular* window forward, which SwiftUI cannot do.
        .background(WindowAccessor { state.nsWindow = $0 })
        .onAppear {
            model.registerWindow(state)
            // A window opened to show something specific starts there rather than on whatever the
            // reconciler would otherwise pick. Consumed once, so ⌘N's plain window is unaffected.
            if let seed = model.consumeSeed() { state.apply(seed) }
            state.reconcile(with: model.hosts)
            if controlActiveState == .key { model.focus(state) }
        }
        .onDisappear { model.unregisterWindow(state.id) }
        // Every window publishes what it is showing when it takes focus, main windows included. There
        // is no privileged window for menu commands to fall back to any more, because with several
        // main windows open there is no longer a "the" main window.
        .onChange(of: controlActiveState) { _, active in
            if active == .key { model.focus(state) }
        }
        // Each window keeps its own place in the tree as the topology changes.
        .onChange(of: model.hosts) { _, hosts in
            state.reconcile(with: hosts)
            if controlActiveState == .key { model.activeScope = state.scope(in: hosts) }
        }
        .onChange(of: state.focusedPaneId) { _, _ in
            if controlActiveState == .key { model.activeScope = state.scope(in: model.hosts) }
        }
        // The model can ask for a window but cannot open one, so whichever window sees the request
        // first performs it. Every open window observes this, hence the claim rather than a plain nil
        // check on the delivered value — otherwise one request opens one window per window.
        .onChange(of: model.requestedWindow) { _, _ in
            if model.claimWindowRequest() { openWindow(id: RootScene.mainWindowId) }
        }
        .sheet(item: $state.hostDraft) { draft in
            HostEditorView(
                draft: draft,
                onSave: { model.saveHost($0, password: $1, savePassword: $2, in: state) },
                onCancel: { state.hostDraft = nil }
            )
        }
        // Host-level and unrequested, so exactly one window presents it. Bound to a constant nil in
        // the others: an ssh prompt shown in four windows is a password typed four times.
        .sheet(item: model.presentsHostLevelSheets(state.id) ? $model.pendingAuthentication : .constant(nil)) { pending in
            AuthenticationSheet(
                pending: pending,
                onSubmit: { model.submitAuthentication(secret: $0, saveInKeychain: $1) },
                onCancel: { model.cancelAuthentication() }
            )
        }
        .sheet(item: $state.pendingClose) { pending in
            DestructiveActionModal(
                title: "Close Window",
                targetName: pending.windowName,
                paneCount: pending.paneCount,
                runningCommands: pending.runningCommands,
                onConfirm: { model.confirmCloseWindow(in: state) },
                onCancel: { state.pendingClose = nil }
            )
        }
        .sheet(item: $state.pendingRename) { pending in
            RenameSheet(
                pending: pending,
                onCommit: { model.commit(pending, to: $0); state.pendingRename = nil },
                onCancel: { state.pendingRename = nil }
            )
        }
        // Item 3 — killing a session ends everything in it, so it always asks.
        .sheet(item: $state.pendingKillSession) { pending in
            DestructiveActionModal(
                title: "Kill Session",
                targetName: pending.sessionName,
                paneCount: pending.windowCount,
                runningCommands: pending.runningCommands,
                onConfirm: { model.confirmKillSession(in: state) },
                onCancel: { state.pendingKillSession = nil }
            )
        }
        // The tmux session is what this window is *of*, so it is what the title bar says. The host is
        // the subtitle rather than part of the title: two hosts can each have a `work` session, and the
        // distinction only matters when it does.
        .navigationTitle(session?.name ?? "tetmux")
        .navigationSubtitle(host?.config.name ?? "")
    }

    @ViewBuilder
    private var detail: some View {
        if let host, let session, let window {
            VStack(spacing: 0) {
                // The panes stay on screen when a channel dies — they hold real scrollback and the
                // window list is still meaningful — so this is the only place the user is told the
                // terminal in front of them is frozen, and the only reconnect they can reach
                // without knowing the sidebar dot is clickable.
                ConnectionBanner(state: host.connectionState) { model.reconnect(host.id) }
                CommandFailureBanner(failure: host.lastCommandFailure) {
                    model.dismissCommandFailure(host.id)
                }
                // Only the attached session receives `%output`, and there is one channel per host, so
                // a second window showing a *different* session of the same host is looking at a
                // snapshot. That used to be impossible to reach in a main window and so lived only in
                // the torn-off one; with several main windows it is an ordinary situation, and panes
                // that quietly stop moving are the worst way to discover it.
                NotAttachedBanner(host: host, session: session)
                WindowTabBar(model: model, state: state, session: session)
                Divider()
                TerminalContainerView(
                    hostId: host.id,
                    window: window,
                    theme: model.theme,
                    service: model.service,
                    focusedPaneId: $state.focusedPaneId,
                    owner: state.id,
                    // §3.3 — a client has exactly one size, so exactly one window may drive it. The
                    // per-*window* size is owned per tmux window by `windowSizeOwners`; this is the
                    // client-wide fallback that matters below tmux 2.9, where it is the only sizing
                    // mechanism there is. Two windows driving it trade `%layout-change`es forever.
                    // Keyed on the last-focused window rather than on `controlActiveState`, which is
                    // false for every window when the app itself is not frontmost — that would leave
                    // the client size with no owner at all.
                    drivesClientSize: model.activeWindowState?.id == state.id
                )
                Divider()
                StatusBarView(host: host, session: session, window: window, focusedPaneId: state.focusedPaneId)
            }
        } else if let host {
            HostPlaceholderView(host: host) { model.reconnect(host.id) }
        } else {
            EmptyStateView { model.presentNewHost(in: state) }
        }
    }

}

/// F4.6 — one application tab per tmux window.
struct WindowTabBar: View {
    @Bindable var model: AppModel
    let state: WindowState
    let session: TmuxSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(session.windows) { window in
                        tab(window)
                    }
                    // Inside the scroller and after the last tab, not pinned to the far right: the
                    // button means "another one of these", and it only reads that way when it sits
                    // where the next tab would appear.
                    Button { model.newWindow() } label: {
                        Image(systemName: "plus").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .padding(.leading, 2)
                    .help("New window (⌘T)")
                    .accessibilityLabel("New window")
                }
                .padding(.horizontal, 6)
            }

            Divider().frame(height: 18)

            // What is left here acts on the *pane*, not on the tab strip. Closing a window moved onto
            // the tabs themselves, where the thing being closed is the thing under the pointer.
            Group {
                Button { model.split(leftRight: true) } label: { Image(systemName: "rectangle.split.2x1") }
                    .help("Split right (⌘D)")
                Button { model.split(leftRight: false) } label: { Image(systemName: "rectangle.split.1x2") }
                    .help("Split down (⇧⌘D)")
                // Item 12 — the same thing the context menu offers, where the split buttons are.
                Button {
                    model.showSession(
                        hostId: state.selectedHostId ?? "",
                        sessionId: session.id,
                        // The window in front, not the session's first: "open this in a new window"
                        // means *this*, and landing on some other window of the same session is a
                        // different request nobody made.
                        windowId: state.selectedWindowId,
                        collapseSidebar: true,
                        preferNewWindow: true
                    )
                } label: {
                    Image(systemName: "macwindow.badge.plus")
                }
                .help("Open this session in a new window")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 4)
        }
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func tab(_ window: TmuxWindow) -> some View {
        WindowTab(
            model: model,
            state: state,
            session: session,
            window: window,
            isSelected: window.id == state.selectedWindowId,
            openWindow: openWindow
        )
    }
}

/// One tab in the strip.
///
/// Its own view rather than a function on `WindowTabBar` because it needs hover state, and hover state
/// on the bar would be one value shared by every tab.
private struct WindowTab: View {
    @Bindable var model: AppModel
    let state: WindowState
    let session: TmuxSession
    let window: TmuxWindow
    let isSelected: Bool
    let openWindow: OpenWindowAction

    @State private var isHovering = false

    private func select() {
        model.select(in: state, host: state.selectedHostId ?? "", session: session.id, window: window.id)
    }

    var body: some View {
        HStack(spacing: 5) {
            Button(action: select) {
                HStack(spacing: 5) {
                    if window.hasActivity && !isSelected {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                    }
                    // The same text the sidebar shows. A tab and its row naming the window
                    // differently is the sort of thing that makes a tree feel unrelated to its content.
                    Text(window.displayLabel).lineLimit(1).truncationMode(.tail)
                    if window.paneCount > 1 {
                        Text("\(window.paneCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Double-click to rename, as a tab bar is expected to. `simultaneousGesture` rather than
            // `onTapGesture`, so the button's own click handling is not replaced — the first click
            // still selects the tab, which is what makes renaming the tab you just double-clicked
            // correct.
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                model.requestRenameWindow(in: state, hostId: state.selectedHostId, windowId: window.id)
            })

            // Selecting first is what makes this close *this* tab: every command acts on the active
            // scope, and the pointer being over a tab is not something the scope knows about.
            Button {
                select()
                model.requestCloseWindow(in: state)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 13, height: 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            // Always laid out, only sometimes visible: hiding it outright would resize the tab under
            // the pointer on hover, and the strip would shuffle as the mouse crossed it.
            .opacity(isHovering || isSelected ? 1 : 0)
            .accessibilityLabel("Close window \(window.name)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .onHover { isHovering = $0 }
        .help(window.displayLabel)
        .accessibilityLabel("Window \(window.displayLabel), \(window.paneCount) panes")
        .contextMenu {
            Button("Rename Window…") {
                model.requestRenameWindow(in: state, hostId: state.selectedHostId, windowId: window.id)
            }
            Button("Open in New Window") {
                guard let hostId = state.selectedHostId else { return }
                model.showSession(
                    hostId: hostId, sessionId: session.id, windowId: window.id,
                    collapseSidebar: true, preferNewWindow: true
                )
            }
            Divider()
            Button("Close Window…", role: .destructive) {
                select()
                model.requestCloseWindow(in: state)
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

/// The honest version of what a single channel can do: this session's panes are a snapshot until the
/// client moves here, and moving it freezes whatever session was attached before.
///
/// Stating the situation is all it does. Focusing the window is what resolves it — `AppModel.focus`
/// attaches — so a button here would only offer what clicking the window already did, and a banner
/// with an action that has just run is a banner nobody believes.
///
/// Making two sessions of one host live at once needs a second channel — see the F4.12 note in
/// CLAUDE.md for why that is deliberately not done.
struct NotAttachedBanner: View {
    let host: HostState
    let session: TmuxSession

    /// `session_attached` counts every client including other people's, so the attached *session id*
    /// this client reported is the only trustworthy signal.
    private var isLive: Bool { host.activeSessionId == session.id }

    var body: some View {
        if !isLive {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Not attached — these panes are a snapshot. tmux streams output for one session per connection.")
                        .font(.caption)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.14))
                Divider()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Not attached. These panes are a snapshot.")
        }
    }
}

/// §7 — a command the user asked for that tmux refused, in tmux's own words.
///
/// Separate from `ConnectionBanner` because it says something different: the channel is fine, and one
/// command did not happen. Folding the two together would either hide a refusal behind a healthy
/// connection or make a failed rename look like a connection problem.
struct CommandFailureBanner: View {
    let failure: CommandFailure?
    let onDismiss: () -> Void

    var body: some View {
        if let failure {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)

                    // "Rename window failed: duplicate session: work". The action is ours; everything
                    // after the colon is tmux's, unedited — it names the thing it could not find.
                    Text("\(failure.action) failed: ") .fontWeight(.medium)
                        + Text(failure.message)

                    Spacer(minLength: 8)

                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel("Dismiss")
                }
                .font(.caption)
                .lineLimit(3)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.12))
                Divider()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(failure.action) failed. \(failure.message)")
        }
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

/// F4.30 — every known session, reachable without going to the Dock.
///
/// Two rules make this useful once more than one window is open (items 9 and 10). Picking a session
/// brings forward the window that is *already showing it* rather than retargeting whichever window
/// happened to be used last — with several windows open, hijacking one of them to show a session
/// another window is already displaying is both surprising and destructive of what was there. And
/// holding Option opens a new window instead of reusing any, which is the standard macOS modifier for
/// "somewhere else, not here".
struct MenuBarContent: View {
    @Bindable var model: AppModel
    /// Owned here rather than by the app so it exists for as long as the menu can be opened, and so
    /// the items and the hint below them cannot disagree about what ⌥ is currently doing.
    @State private var optionKey = OptionKeyMonitor()

    /// What every item in this menu does while ⌥ is held, and the icon that says so.
    private var newWindowIcon: String { "macwindow.on.rectangle" }

    var body: some View {
        ForEach(model.hosts) { host in
            Section(host.config.name) {
                ForEach(host.sessions) { session in
                    Button {
                        open(host: host, session: session)
                    } label: {
                        Label(session.name, systemImage: icon(attached: session.isAttached))
                    }
                }
                // Item 10 — a host with no sessions still needs a way to get one, and a host with
                // sessions still needs another.
                if host.sessions.isEmpty && !host.connectionState.isActive {
                    Button("Connect") { model.connect(host.id) }
                }
                Button {
                    newSession(host: host)
                } label: {
                    Label("New Session", systemImage: optionKey.isHeld ? newWindowIcon : "plus")
                }
            }
        }
        Divider()
        // The modifier is not discoverable otherwise: a menu item cannot show its own alternate
        // behaviour the way AppKit's `isAlternate` does, so the icons above are swapped by hand
        // while ⌥ is down and this says what they mean.
        Label(
            optionKey.isHeld ? "Opening in a new window" : "Hold ⌥ to open sessions in a new window",
            systemImage: newWindowIcon
        )
        .font(.caption)
        Divider()
        Button("Quit tetmux") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func icon(attached: Bool) -> String {
        if optionKey.isHeld { return newWindowIcon }
        return attached ? "macwindow.badge.plus" : "macwindow"
    }

    private func open(host: HostState, session: TmuxSession) {
        // Read at click time, not from `optionKey`, which is a poll and so can be a frame behind:
        // `MenuBarExtra` gives no event, but the flags are current while the item's action runs.
        let wantsNewWindow = NSEvent.modifierFlags.contains(.option)
        // No `fallback:`, so this lands on the last-used window — item 9's "otherwise the one that
        // was last used".
        model.showSession(
            hostId: host.id,
            sessionId: session.id,
            windowId: session.activeWindow?.id,
            collapseSidebar: wantsNewWindow,
            preferNewWindow: wantsNewWindow
        )
        NSApp.activate(ignoringOtherApps: true)
    }

    /// ⌥ means the same thing here as it does on a session row: somewhere else, not here.
    ///
    /// The window cannot be opened now — `new-session` answers with no id — so the intent travels
    /// with the reveal request and the window appears when tmux confirms the session.
    private func newSession(host: HostState) {
        let wantsNewWindow = NSEvent.modifierFlags.contains(.option)
        // No window may be key — the menu bar is reachable with the app in the background — so name
        // the window explicitly rather than relying on focus.
        model.createSessionWithDefaultName(
            hostId: host.id,
            revealIn: model.activeWindowState ?? model.lastUsedWindow,
            preferNewWindow: wantsNewWindow
        )
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Whether ⌥ is down *right now*, so an open menu can show what clicking it would do.
///
/// Polled, which wants justifying. The modifier cannot come from the items themselves —
/// `MenuBarExtra` hands its content no event and SwiftUI has no equivalent of AppKit's
/// `isAlternate`. It cannot come from an event monitor either: a menu tracks events in a run loop
/// of its own, where a local monitor sees nothing, and a global monitor for a keyboard event needs
/// the Accessibility permission this app otherwise has no use for. So the hardware state is read on
/// a timer — scheduled in the *common* run-loop modes, which is the part that makes it fire during
/// menu tracking at all — and only between `NSMenu` beginning and ending its tracking, so nothing
/// wakes up while no menu is open.
@MainActor
@Observable
final class OptionKeyMonitor {
    private(set) var isHeld = false

    @ObservationIgnored private var timer: Timer?

    init() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
        center.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    private func start() {
        guard timer == nil else { return }
        sample()
        // 20 Hz: fast enough that pressing ⌥ looks instant, slow enough to be free.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        // The menu is gone; leaving this set would show the alternate icons the moment it reopens.
        isHeld = false
    }

    private func sample() {
        let held = NSEvent.modifierFlags.contains(.option)
        guard held != isHeld else { return }
        isHeld = held
    }
}
