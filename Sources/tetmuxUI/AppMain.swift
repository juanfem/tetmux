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
                .task {
                    // The Dock menu is AppKit's, built outside any scene, so it reaches the model
                    // through the delegate rather than through an environment it does not have.
                    appDelegate.model = model
                    await model.bootstrap()
                }
        }
        .windowToolbarStyle(.unified)
        .commands { menuCommands }

        // F4.30 — every known session, attachable without bringing the main window forward.
        MenuBarExtra("tetmux", systemImage: "terminal.fill") {
            MenuBarContent(model: model)
        }

        // Without a `Settings` scene macOS shows no "Settings…" item at all, so `TerminalTheme` —
        // whose own comment called itself the thing "the eventual settings pane" would write to —
        // had no way of ever being written to. ⌘, is AppKit's, not ours to bind.
        Settings {
            SettingsView(model: model)
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
        // Replacing `.pasteboard` rather than `.textEditing`: AppKit's own Paste lives in the
        // pasteboard group and comes first in menu order, so leaving it there put two ⌘V items in the
        // Edit menu and let the standard one win. SwiftTerm validates `paste(_:)` as always enabled,
        // so that route fed the clipboard through per-keystroke `send-keys` and bypassed the buffer
        // chunking whose own comment says a megabyte of `send-keys` will wedge the channel.
        CommandGroup(replacing: .pasteboard) {
            Button(ApplicationShortcut.paste.title) { model.pasteIntoFocusedPane() }
                .keyboardShortcut(.paste, in: keymap)
        }
        // Find lives in `.textEditing`, which used to be replaced wholesale by the Paste button
        // above — which is what unplugged SwiftTerm's find bar. It is reachable only through the
        // standard `performTextFinderAction` responder chain, so this hands it back.
        CommandGroup(replacing: .textEditing) {
            Button(ApplicationShortcut.find.title) { model.showFindBar() }
                .keyboardShortcut(.find, in: keymap)
        }
        CommandGroup(after: .toolbar) {
            Button(ApplicationShortcut.increaseFontSize.title) { model.adjustFontSize(by: 1) }
                .keyboardShortcut(.increaseFontSize, in: keymap)
            Button(ApplicationShortcut.decreaseFontSize.title) { model.adjustFontSize(by: -1) }
                .keyboardShortcut(.decreaseFontSize, in: keymap)
            Button(ApplicationShortcut.resetFontSize.title) { model.resetFontSize() }
                .keyboardShortcut(.resetFontSize, in: keymap)
            Divider()
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
        CommandMenu("Pane") {
            Button(ApplicationShortcut.zoomPane.title) { model.toggleZoom() }
                .keyboardShortcut(.zoomPane, in: keymap)
            Divider()
            Button(ApplicationShortcut.focusNextPane.title) { model.focusAdjacentPane(offset: 1) }
                .keyboardShortcut(.focusNextPane, in: keymap)
            Button(ApplicationShortcut.focusPreviousPane.title) { model.focusAdjacentPane(offset: -1) }
                .keyboardShortcut(.focusPreviousPane, in: keymap)
            Divider()
            Button(ApplicationShortcut.nextWindow.title) { model.selectAdjacentWindow(offset: 1) }
                .keyboardShortcut(.nextWindow, in: keymap)
            Button(ApplicationShortcut.previousWindow.title) { model.selectAdjacentWindow(offset: -1) }
                .keyboardShortcut(.previousWindow, in: keymap)
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
@MainActor
public final class TetmuxAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the scene as it comes up. Weak, because the delegate outlives nothing but the process
    /// and must not be the reason the model is kept alive.
    public weak var model: AppModel?

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

    /// Hands `window-size` back before the process goes.
    ///
    /// tetmux sets `window-size manual` on each session it displays so that a torn-off macOS window
    /// can size its tmux window independently — a change to the *user's* session, which persists
    /// after tetmux is gone. `disconnectHost` puts it back and waits for tmux's own `%end` before
    /// hanging the channel up, but until now only a deliberate per-host disconnect reached it. ⌘Q,
    /// which is how a Mac application is normally closed, skipped all of it and left every attached
    /// session `manual` for the next plain `tmux attach` to find.
    ///
    /// `.terminateLater` because the work is a round trip per host and `applicationWillTerminate`
    /// cannot wait for one. The timeout is the point of the whole arrangement being here rather than
    /// in the model: a channel can accept a write and never answer, and a quit that hangs is worse
    /// than an option left set. `sendAndAwait` already bounds each command; this bounds the lot, so a
    /// host that is wedged at the transport layer cannot hold the app open either.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { @MainActor in
            let cleanup = Task { await model.service.shutdown() }
            let deadline = Task { try? await Task.sleep(for: .seconds(3)) }
            // A race, not a wait-then-check: quitting must cost whatever the cleanup actually costs
            // — a few milliseconds against local tmux — and the deadline exists only for the channel
            // that never answers. Cancelling `cleanup` is not enough on its own to guarantee that,
            // since a task parked on a continuation does not resume on cancellation, so the reply is
            // sent by whichever of the two finishes first.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = await cleanup.result }
                group.addTask { _ = await deadline.result }
                await group.next()
                group.cancelAll()
            }
            cleanup.cancel()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The Dock icon's menu.
    ///
    /// One item, and it is the one the Dock cannot otherwise offer: with every window closed the app
    /// is still running — `applicationShouldTerminateAfterLastWindowClosed` above says so — and the
    /// Dock's own menu has nothing in it that brings a window back. Sessions are deliberately not
    /// listed here; that is the menu bar extra's job, and it can say what ⌥ would do, which a Dock
    /// menu cannot.
    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: ApplicationShortcut.newAppWindow.title,
            action: #selector(openNewAppWindow),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func openNewAppWindow() {
        model?.openNewAppWindow()
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
            // Handed over rather than claimed: the model has to be able to open a window when there
            // is none left to observe `requestedWindow`, and `openWindow` can only be read here.
            model.openAppWindow = { openWindow(id: RootScene.mainWindowId) }
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
                // Every window of the session is built, and the ones that are not selected are hidden
                // rather than omitted.
                //
                // Building only the selected one tore down its `TerminalView`s on every tab switch,
                // and with them the entire local scrollback — the return trip replays `capture-pane`,
                // whose payload begins `ESC[H ESC[2J ESC[3J`: screen *and* scrollback, capped at the
                // capture budget. So "scroll up to see what that build printed" worked until you
                // looked at another tab, which is when you would want it.
                //
                // Hidden with `opacity`, never with `if`: a ZStack hands every child the same frame,
                // so a background tab keeps measuring the size it would really have and keeps asking
                // tmux for that grid. Dropping it from the tree instead would resize its tmux window
                // to nothing and reflow everything running in it.
                ZStack {
                    ForEach(session.windows) { candidate in
                        terminalContainer(host: host, window: candidate, state: state)
                            .opacity(candidate.id == window.id ? 1 : 0)
                            .allowsHitTesting(candidate.id == window.id)
                            // Keeps AppKit from moving focus into a pane nobody can see.
                            .accessibilityHidden(candidate.id != window.id)
                            .id(candidate.id)
                    }
                }
                Divider()
                StatusBarView(host: host, session: session, window: window, focusedPaneId: state.focusedPaneId)
            }
        } else if let host {
            HostPlaceholderView(host: host) { model.reconnect(host.id) }
        } else {
            EmptyStateView { model.presentNewHost(in: state) }
        }
    }

    private func terminalContainer(host: HostState, window: TmuxWindow, state: WindowState) -> some View {
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
            //
            // Below 2.9 that also has to mean the *selected* tab and not merely the focused macOS
            // window, now that every tab is built: the hidden ones are real views with real frames,
            // and letting them drive the one client size would put the last one laid out in charge.
            drivesClientSize: model.activeWindowState?.id == state.id
                && state.selectedWindowId == window.id
        )
    }
}

/// F4.6 — one application tab per tmux window.
struct WindowTabBar: View {
    @Bindable var model: AppModel
    let state: WindowState
    let session: TmuxSession
    @Environment(\.openWindow) private var openWindow
    /// §7 — Reduce Motion is a system preference about vestibular comfort, not a style choice, so
    /// the movement is dropped and the outcome kept: the tab still ends up on screen.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            // The selected tab has to be brought into view, because the selection moves from places
            // that are nowhere near the tab strip — the launcher, the sidebar, ⇧⌘], the reveal after
            // creating a window. With a dozen tmux windows the strip scrolls, and a plain `ScrollView`
            // left the newly selected one off-screen with nothing to say it had moved.
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(session.windows) { window in
                            tab(window).id(window.id)
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
                .onChange(of: state.selectedWindowId) { _, selected in
                    guard let selected else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                        scroller.scrollTo(selected, anchor: .center)
                    }
                }
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
    /// ⌥ skips the close confirmation here for the same reason it does in the tree — this is the same
    /// action on the same window, and a modifier that worked in one of the two places would read as a
    /// bug in the other.
    @State private var modifiers = ModifierKeyMonitor()

    private func select() {
        model.select(in: state, host: state.selectedHostId ?? "", session: session.id, window: window.id)
    }

    /// The window's label, with the focused pane's part in medium.
    ///
    /// A split window is labelled by what is running in *every* pane — `zsh · vim · tail` — which says
    /// what the window holds but not which of them the keyboard is pointing at. Weight rather than
    /// colour: the tab strip already spends colour on selection and on the activity dot, and a third
    /// colour there would be one signal too many. Medium is also the smallest step that survives the
    /// tab's size, where a colour shift would not.
    ///
    /// One `Text` built by concatenation rather than an `HStack` of several, so the label truncates as
    /// a single run — an HStack would shrink the parts independently and put an ellipsis in the middle
    /// of each.
    private var title: Text {
        guard let segments = window.displayLabelSegments, segments.count > 1 else {
            return Text(window.displayLabel)
        }
        // For the tab in front, the pane the user is actually typing into; for the others, the pane
        // tmux considers current, which is where typing would go if the tab were selected.
        let focused = isSelected
            ? (state.focusedPaneId ?? window.activePaneId)
            : window.activePaneId

        return segments.enumerated().reduce(Text("")) { partial, entry in
            let (index, segment) = entry
            let separator = index > 0 ? Text(TmuxWindow.labelSeparator) : Text("")
            let piece = segment.paneId == focused
                ? Text(segment.text).fontWeight(.medium)
                : Text(segment.text)
            return partial + separator + piece
        }
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
                    title.lineLimit(1).truncationMode(.tail)
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
                model.requestCloseWindow(in: state, skippingConfirmation: OptionKey.isHeld)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 13, height: 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(modifiers.isOptionHeld ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
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

/// Says that this session's panes are a photograph, on the rare occasions that is still true.
///
/// Every session on screen gets a client of its own now, so the ordinary reasons this used to appear
/// — a second window on a second session, or the moment between picking a session and tmux answering
/// `switch-client` — are gone. `liveSessionIds` counts a channel that is still connecting as live
/// precisely so the second case cannot flash a banner and withdraw it.
///
/// What is left is the honest case: tmux refused the attach, or the client for this session died and
/// the host is still up. Stating it is all this does; the next reconcile is already trying again, so
/// a button here would offer an action that is running.
struct NotAttachedBanner: View {
    let host: HostState
    let session: TmuxSession

    /// `session_attached` counts every client of the server, including terminals elsewhere on the
    /// machine that have nothing to do with this app, so what *tetmux* is attached to is the only
    /// trustworthy signal.
    private var isLive: Bool { host.isLive(session.id) }

    var body: some View {
        // Only while the host itself is up. A host that is reconnecting has its own banner saying so,
        // and two of them stacked would describe one problem twice.
        if !isLive, host.connectionState.isActive {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Not attached — these panes are a snapshot. tetmux has no tmux client on this session.")
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
    @Environment(\.openWindow) private var openWindow
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
                        Label(session.name, systemImage: icon(live: host.isLive(session.id)))
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

    private func icon(live: Bool) -> String {
        if optionKey.isHeld { return newWindowIcon }
        return live ? "macwindow.badge.plus" : "macwindow"
    }

    /// Leaves the model able to open a window on its own.
    ///
    /// The menu bar outlives every window, so this menu is the one view still around when the last
    /// one closes — and `openWindow` is readable only from a view. Re-set on each use rather than
    /// once, because the action a closed window handed over is the one thing here that could have
    /// gone stale, and this costs nothing.
    private func adoptWindowOpener() {
        model.openAppWindow = { openWindow(id: RootScene.mainWindowId) }
    }

    private func open(host: HostState, session: TmuxSession) {
        adoptWindowOpener()
        // Read at click time, not from `optionKey`, which is a poll and so can be a frame behind:
        // `MenuBarExtra` gives no event, but the flags are current while the item's action runs.
        let wantsNewWindow = OptionKey.isHeld
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
        adoptWindowOpener()
        let wantsNewWindow = OptionKey.isHeld
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

/// ⌥ as it is *at this instant*, for an action that has already been triggered.
///
/// Every control that treats ⌥ as part of the click reads it here rather than from either monitor
/// below: both of those exist to keep a *display* current and are allowed to be a frame behind, and
/// a button whose behaviour disagreed with its own icon by one frame would be the one bug this is
/// least able to explain to the person it happened to. The flags are live and correct for as long as
/// the action's own call stack, wherever it was triggered from.
@MainActor
enum OptionKey {
    static var isHeld: Bool { NSEvent.modifierFlags.contains(.option) }
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
        let held = OptionKey.isHeld
        guard held != isHeld else { return }
        isHeld = held
    }
}

/// The same question for an ordinary window: is ⌥ down, so a close button can say that clicking it
/// will not stop to ask?
///
/// Separate from `OptionKeyMonitor` because the two have opposite constraints. A window's events go
/// through the normal responder chain, so `.flagsChanged` simply arrives — no Accessibility
/// permission, no timer, and nothing running while the key is not being pressed. That monitor cannot
/// use this mechanism (a menu tracks events in a run loop where a local monitor sees nothing), and
/// this must not use that one: its 20 Hz timer is bounded by how long a menu stays open, whereas a
/// window is open for as long as the app runs.
///
/// One instance per window, which is what SwiftUI ownership gives; the monitor is app-wide either
/// way, so several simply agree.
@MainActor
@Observable
final class ModifierKeyMonitor {
    private(set) var isOptionHeld = false

    /// `nonisolated(unsafe)` so `deinit` can take it back. It is written once in `init` and read once
    /// in `deinit`, and `NSEvent.removeMonitor` is safe from either.
    @ObservationIgnored nonisolated(unsafe) private var monitor: Any?

    init() {
        // `.flagsChanged` alone would go stale while the app is in the background, where a modifier
        // pressed elsewhere is never reported. `.mouseEntered` corrects it at the one moment that
        // matters: the buttons this drives are revealed by hovering the row in the first place, so
        // the pointer crossing into one is always the event before the click.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .mouseEntered]) {
            [weak self] event in
            MainActor.assumeIsolated {
                let held = event.modifierFlags.contains(.option)
                if let self, held != self.isOptionHeld { self.isOptionHeld = held }
            }
            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
