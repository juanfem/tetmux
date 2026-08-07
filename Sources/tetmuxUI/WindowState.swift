import AppKit
import Observation
import SwiftUI
import tetmuxCore

/// Where a newly opened window should start.
///
/// A window cannot be told what to show through `openWindow(id:)`, which carries no value, and the
/// value-carrying form keys windows *by* that value — re-opening the same one brings the existing
/// window forward instead of making a second. That is right for "show me this session" and wrong for
/// ⌘N, which must always produce a new window. So the seed is handed over through the model and the
/// next window to appear consumes it.
public struct WindowSeed: Equatable, Sendable {
    public var hostId: String?
    /// `$id`
    public var sessionId: String?
    /// `@id`
    public var windowId: String?
    /// What the new window's tree should do, which is not always "nothing".
    ///
    /// Three states rather than a `collapseSidebar` flag, because there are genuinely three answers.
    /// A window opened *onto a session* hides the tree (item 12) — it has one thing to show and the
    /// tree is in the way. A window opened to *navigate from* — New Window, from ⌘N or the Dock —
    /// must show it, and cannot rely on `.automatic` to decide, since that is AppKit's judgement and
    /// not an instruction. `.unchanged` is for a window that is being seeded with a session but not
    /// told what to do about its tree, and is the default the seed carries when nobody says.
    ///
    /// ⌘N used to be a fourth answer by accident: it opened a bare window with no seed at all, so
    /// the tree fell to `.automatic` and came up collapsed while the Dock's identically-titled item
    /// came up expanded. Both now go through `AppModel.openNewAppWindow`.
    public enum SidebarIntent: Equatable, Sendable {
        case unchanged
        case collapsed
        case shown
    }

    public var sidebar: SidebarIntent

    /// Item 12 — a window opened onto one session does not need the tree in front of it.
    public var collapseSidebar: Bool { sidebar == .collapsed }

    public init(
        hostId: String? = nil,
        sessionId: String? = nil,
        windowId: String? = nil,
        collapseSidebar: Bool = false
    ) {
        self.init(
            hostId: hostId, sessionId: sessionId, windowId: windowId,
            sidebar: collapseSidebar ? .collapsed : .unchanged
        )
    }

    public init(
        hostId: String? = nil,
        sessionId: String? = nil,
        windowId: String? = nil,
        sidebar: SidebarIntent
    ) {
        self.hostId = hostId
        self.sessionId = sessionId
        self.windowId = windowId
        self.sidebar = sidebar
    }
}

/// Everything that belongs to *one* macOS window rather than to the application.
///
/// This used to live on `AppModel`, which is shared by every scene, and the consequences were two
/// separate reported bugs with one cause: clicking a session in one window retargeted every other
/// window, and one `.sheet(item:)` bound to shared state opened the same dialog once per open window.
/// `DetachedWindowView` already worked around it by keeping private copies of the pieces it needed;
/// this is that workaround generalised so the main window is not a special case.
///
/// Holds no reference to `AppModel`: the derived accessors take the host list, which keeps the
/// reconciliation rules testable without a channel, a window, or AppKit.
@MainActor
@Observable
public final class WindowState: Identifiable {
    /// Also this window's identity for §3.3 size ownership, and what `AppModel` keys its window
    /// registry on.
    public let id = UUID()

    public var selectedHostId: String?
    /// `$id`
    public var selectedSessionId: String?
    /// `@id`
    public var selectedWindowId: String?
    /// `%id`
    public var focusedPaneId: String?

    // Sheets. Per window for the reason above — a sheet is a property of the window presenting it,
    // never of the model behind it.

    /// The host being added or edited, if this window's editor is open.
    public var hostDraft: AppModel.HostDraft?
    /// A window this window asked to close, pending confirmation (F4.10).
    public var pendingClose: AppModel.PendingClose?
    /// A session or window this window asked to rename, pending the new name.
    public var pendingRename: AppModel.PendingRename?
    /// A session this window asked to kill, pending confirmation. Killing a session ends every
    /// process in every one of its windows, so unlike closing a tab it always asks.
    public var pendingKillSession: AppModel.PendingKillSession?
    /// A copy-mode search this window asked for, pending its needle.
    public var pendingCopyModeSearch: AppModel.PendingCopyModeSearch?
    public var isLauncherPresented = false

    /// Whether the host tree is showing. Item 12: a window opened onto a single session starts
    /// without it.
    public var sidebarVisibility: NavigationSplitViewVisibility = .automatic

    /// The last session this window actually had on screen, by host and by *name*.
    ///
    /// Kept because a session that ends takes its id, its windows and its row in the tree with it, and
    /// by the time anyone can be told about it `selectedSessionId` refers to nothing. The name is what
    /// survives — it is also the only thing worth offering to recreate — and the host has to travel
    /// with it, since tmux numbers and names sessions per server and `work` on two machines is two
    /// different pieces of work.
    public private(set) var lastShownHostId: String?
    /// Companion to `lastShownHostId`. See there.
    public private(set) var lastShownSessionName: String?

    /// This window's `NSWindow`, captured by `WindowAccessor`.
    ///
    /// SwiftUI has no way to bring a *particular* window of a `WindowGroup` forward — `openWindow(id:)`
    /// makes a new one — so items 5 and 9 need the AppKit handle. Weak: the window owns itself, and a
    /// closed one must not be held open by this reference.
    @ObservationIgnored public weak var nsWindow: NSWindow? {
        didSet {
            applyRestoredFrame()
            if let nsWindow { liveResize.observe(nsWindow) } else { liveResize.stopObserving() }
        }
    }

    /// R3.7 — this window's panes stop asking tmux for sizes while its edge is being dragged. Per
    /// window, because another window's panes are not the ones moving.
    @ObservationIgnored public let liveResize = LiveResizeGate()

    /// Where this window belongs, as soon as tmux can say where that is.
    ///
    /// Held rather than applied, because at the moment it is set the host is not connected — at
    /// launch the local one is still handshaking and a remote one is waiting to be asked — so there
    /// is no session to select yet. `reconcile` retries it on every snapshot and clears it once it
    /// lands. There is deliberately **no expiry**: a remote host resolves the moment the user
    /// connects it, which may be minutes later, and a timeout would silently turn that into "the
    /// window came back on the wrong session" with nothing to explain why.
    ///
    /// Named for the workspace restore it was written for, which is still the common case, but the
    /// launcher sets it too (`showWhenAvailable`): picking a window on a host nobody is attached to
    /// is the same problem — a selection that cannot be made until a channel exists — and the
    /// no-expiry rule above is what makes an ssh round trip behind it safe.
    @ObservationIgnored public var pendingRestore: WorkspaceWindow?

    /// The saved frame, applied once the `NSWindow` exists. Cleared when it does, so a window later
    /// resized by the user is not snapped back by a second `WindowAccessor` pass.
    @ObservationIgnored private var restoredFrame: NSRect?

    public init() {}

    /// Takes a saved window as this window's starting point.
    ///
    /// The sidebar and the frame apply immediately — they need nothing from tmux. The selection
    /// cannot, so it waits in `pendingRestore`.
    public func beginRestore(_ saved: WorkspaceWindow) {
        pendingRestore = saved
        sidebarVisibility = saved.sidebarShown ? .all : .detailOnly
        restoredFrame = saved.rect
        applyRestoredFrame()
    }

    private func applyRestoredFrame() {
        guard let restoredFrame, let nsWindow else { return }
        self.restoredFrame = nil
        // Only if it is still somewhere a person can reach. A monitor unplugged since the last
        // launch leaves a frame off every screen, and a window restored there is gone as far as the
        // user is concerned — with no way to bring it back but deleting a file they do not know about.
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(restoredFrame) }) else { return }
        nsWindow.setFrame(restoredFrame, display: false)
    }

    /// Points this window at something no channel can select yet (F4.26).
    ///
    /// The launcher's window row on an unreachable host: the window is a fact from the last time
    /// that host answered, so there is nothing to select until it answers again. The target waits
    /// in `pendingRestore` and lands by the ordinary restore path, which resolves by id and then by
    /// name — the right rule here too, since a server restarted since that topology was read has
    /// reissued every id.
    ///
    /// It builds the entry from this window's own frame and tree rather than taking one, because an
    /// unresolved entry is what `workspaceEntry` writes to the file: assembled anywhere else, a
    /// quit between the click and the connection would save the window with no frame and put it
    /// somewhere else on the next launch.
    public func showWhenAvailable(
        hostId: String,
        sessionId: String?,
        sessionName: String?,
        windowId: String?,
        windowName: String?
    ) {
        selectedHostId = hostId
        // The ids this window was showing belong to the host it is leaving, and tmux numbers per
        // server — left in place they are a *different* session on the new host as far as
        // `displayedSessions` is concerned, which would ask the service for a client on a session
        // that does not exist. Nothing is lost on screen: the detail column resolves against the new
        // host, finds nothing, and shows its connect placeholder either way.
        selectedSessionId = nil
        selectedWindowId = nil
        focusedPaneId = nil
        pendingRestore = WorkspaceWindow(
            hostId: hostId,
            sessionId: sessionId,
            sessionName: sessionName,
            windowId: windowId,
            windowName: windowName,
            sidebarShown: sidebarVisibility != .detailOnly,
            frame: currentFrame
        )
    }

    /// This window's frame in the flat form the file keeps, or `nil` if it has no `NSWindow` yet.
    private var currentFrame: [Double]? {
        nsWindow.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] }
    }

    /// This window, in the form the workspace file keeps.
    public func workspaceEntry(in hosts: [HostState]) -> WorkspaceWindow {
        // An unresolved restore is written back unchanged rather than overwritten with where the
        // window has landed in the meantime. Quitting before a remote host was ever connected would
        // otherwise replace the session the user actually wants with whatever the reconciler picked.
        if let pendingRestore { return pendingRestore }
        let session = selectedSession(in: hosts)
        let window = selectedWindow(in: hosts)
        return WorkspaceWindow(
            hostId: selectedHostId,
            sessionId: session?.id,
            sessionName: session?.name,
            windowId: window?.id,
            windowName: window?.name,
            sidebarShown: sidebarVisibility != .detailOnly,
            frame: currentFrame
        )
    }

    /// Brings this window to the front. Item 9's "bring forward the one already attached".
    public func bringToFront() {
        guard let nsWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        nsWindow.makeKeyAndOrderFront(nil)
    }

    /// Applies a seed handed over at open time.
    public func apply(_ seed: WindowSeed) {
        if let hostId = seed.hostId { selectedHostId = hostId }
        if let sessionId = seed.sessionId { selectedSessionId = sessionId }
        if let windowId = seed.windowId { selectedWindowId = windowId }
        switch seed.sidebar {
        case .unchanged: break
        case .collapsed: sidebarVisibility = .detailOnly
        case .shown: sidebarVisibility = .all
        }
    }

    // MARK: - Derived selection

    public func selectedHost(in hosts: [HostState]) -> HostState? {
        hosts.first { $0.id == selectedHostId }
    }

    public func selectedSession(in hosts: [HostState]) -> TmuxSession? {
        guard let host = selectedHost(in: hosts) else { return nil }
        return host.sessions.first { $0.id == selectedSessionId } ?? host.activeSession
    }

    public func selectedWindow(in hosts: [HostState]) -> TmuxWindow? {
        guard let session = selectedSession(in: hosts) else { return nil }
        return session.windows.first { $0.id == selectedWindowId } ?? session.activeWindow
    }

    /// Whether a sidebar row is the one this window is showing.
    ///
    /// The host has to be part of the comparison. tmux numbers sessions and windows **per server**, so
    /// `$0` and `@1` exist on every host at once — and they genuinely collide in practice, because the
    /// obvious way to reach a second host is to ssh into it, and its tmux starts numbering from zero
    /// exactly like the first one's. Comparing only the tmux ids lit up the matching row on every host
    /// simultaneously.
    ///
    /// A method rather than an expression inside the view so the rule can be tested; getting it wrong
    /// is invisible until two hosts happen to be connected at once.
    public func isShowing(hostId: String, sessionId: String, windowId: String) -> Bool {
        hostId == selectedHostId && sessionId == selectedSessionId && windowId == selectedWindowId
    }

    /// The session-level equivalent.
    public func isShowing(hostId: String, sessionId: String) -> Bool {
        hostId == selectedHostId && sessionId == selectedSessionId
    }

    /// F4.15's second half — the name this window should be offered a **Recreate** button for, if any.
    ///
    /// A session ending and a link dropping both leave `.disconnected` behind, and they are not the
    /// same thing to the person looking at it: one is "your work is out of reach", the other is "your
    /// work is gone, and here is what it was called". `endedSessionName` is the host's answer to which
    /// happened; this is the window's answer to whether that session was *its* session, because a
    /// second window sitting on a different session of the same host must not be offered the recreation
    /// of somebody else's.
    ///
    /// A method rather than an expression in the view, because both halves of it are silently wrong
    /// in opposite directions: too loose and every window on the host offers to recreate one session,
    /// too strict and the offer never appears at all.
    public func recreatableSessionName(in host: HostState) -> String? {
        guard case .disconnected = host.connectionState else { return nil }
        guard let name = host.endedSessionName else { return nil }
        guard host.id == lastShownHostId, name == lastShownSessionName else { return nil }
        return name
    }

    /// What this window is showing, in the form every command takes.
    public func scope(in hosts: [HostState]) -> AppModel.Scope {
        let window = selectedWindow(in: hosts)
        return AppModel.Scope(
            hostId: selectedHostId,
            sessionId: selectedSession(in: hosts)?.id,
            windowId: window?.id,
            paneId: focusedPaneId ?? window?.preferredPaneId
        )
    }

    // MARK: - Reconciliation

    /// Moves this window's selection back onto things that still exist.
    ///
    /// Runs on every topology change. Previously this was `AppModel.apply`, mutating the one shared
    /// selection; now each window keeps its own place in the tree, which is the point — two windows
    /// showing two different sessions of one host is the ordinary case, not an edge case.
    public func reconcile(with hosts: [HostState]) {
        resolveRestore(with: hosts)
        if selectedHostId == nil || !hosts.contains(where: { $0.id == selectedHostId }) {
            selectedHostId = hosts.first?.id
        }
        guard let host = selectedHost(in: hosts) else { return }

        if selectedSessionId == nil || !host.sessions.contains(where: { $0.id == selectedSessionId }) {
            selectedSessionId = host.activeSession?.id
        }
        guard let session = selectedSession(in: hosts) else {
            selectedWindowId = nil
            focusedPaneId = nil
            return
        }
        // Recorded here and nowhere else: this is the one point that has both a host and a session
        // that really exist, which is what makes the remembered pair a fact rather than an intention.
        lastShownHostId = host.id
        lastShownSessionName = session.name
        if selectedWindowId == nil || !session.windows.contains(where: { $0.id == selectedWindowId }) {
            selectedWindowId = session.activeWindow?.id
        }
        // Keep the keyboard on a pane that still exists.
        guard let window = selectedWindow(in: hosts) else {
            focusedPaneId = nil
            return
        }
        let paneIds = window.layoutTree?.paneIds ?? window.panes.map(\.id)
        if let focused = focusedPaneId, paneIds.contains(focused) { return }
        focusedPaneId = window.preferredPaneId
    }

    /// Puts this window back where the last launch left it, as soon as tmux can say where that is.
    ///
    /// Runs ahead of the ordinary reconciliation on every snapshot and is a no-op once it has landed.
    /// The host is claimed as soon as it exists, even with no sessions yet, so a window restored onto
    /// a remote host waits *there* — showing that host's connect placeholder — rather than being
    /// pulled onto the first host in the list by the reconciler below and having to be dragged back.
    ///
    /// Non-private so the id-then-name rule can be asserted from a plain host list, with no window
    /// and no channel: it is the whole of the restoration that can be silently wrong.
    func resolveRestore(with hosts: [HostState]) {
        guard let saved = pendingRestore else { return }
        guard let host = hosts.first(where: { $0.id == saved.hostId }) else { return }
        selectedHostId = host.id

        // §4.6 — a passthrough host has no session tree and will not grow one while it is in that
        // mode, so there is nothing left for this entry to resolve *to*. Landing it here rather than
        // leaving it pending is what stops the restore re-asserting this host on every snapshot: an
        // entry that can never resolve pins the window to it, and clicking any other host in the
        // tree is silently undone by the next topology change. The window keeps the host, which is
        // as much of the entry as still means anything.
        if host.passthrough != nil {
            pendingRestore = nil
            return
        }

        // Id first, name second. The id is exact and is what a still-running server will still be
        // using; the name is what survives the server having been restarted in between, when every
        // id has been reissued and matching on one would land on a stranger's session.
        var session = host.sessions.first { $0.id == saved.sessionId }
        if session == nil, let name = saved.sessionName {
            session = host.sessions.first { $0.name == name }
        }
        guard let session else { return }

        var window = session.windows.first { $0.id == saved.windowId }
        if window == nil, let name = saved.windowName {
            window = session.windows.first { $0.name == name }
        }

        selectedSessionId = session.id
        selectedWindowId = window?.id ?? session.activeWindow?.id
        focusedPaneId = nil
        pendingRestore = nil
    }
}

/// Hands a SwiftUI view its own `NSWindow`.
///
/// There is no SwiftUI equivalent: a `WindowGroup` window can be opened but not addressed. Reading it
/// from the view hierarchy is the standard escape hatch, and it is done asynchronously because the
/// view is not in a window yet at the moment `makeNSView` returns.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // A window restored at launch, or one re-hosted by AppKit, can arrive after the first pass.
        guard let window = view.window else { return }
        onResolve(window)
    }
}
