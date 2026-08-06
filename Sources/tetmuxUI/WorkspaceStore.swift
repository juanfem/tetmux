import AppKit
import Foundation
import tetmuxCore

/// One macOS window's place in the tree, as it should come back on the next launch.
///
/// §4.3's framing is that tmux is the persistence layer and the application persists *view state* —
/// which windows pointed at which host and session, not what was in them. That is exactly this: no
/// pane contents, no scrollback, no layout. tmux still holds all of it, and reattaching is what
/// brings it back.
///
/// Both an id and a name are recorded for the session and the window, because the two answer
/// different questions. `$3` and `@7` are exact and are what a relaunch against a *still-running*
/// server should match on — the overwhelmingly common case, since quitting tetmux does not stop
/// tmux. The names are the fallback for the case where the server was restarted in between and every
/// id was reissued: `work` is still `work`, and landing on it is better than landing on whatever
/// happens to be `$3` now, which would be somebody else's session under the user's window title.
public struct WorkspaceWindow: Codable, Equatable, Sendable {
    public var hostId: String?
    /// `$id`, valid for as long as the tmux server that issued it is alive.
    public var sessionId: String?
    /// The same session by name, for when it is not.
    public var sessionName: String?
    /// `@id`
    public var windowId: String?
    public var windowName: String?
    /// Whether the host tree was showing. A window torn off onto one session has it collapsed, and
    /// restoring that window with the tree back is restoring a different window.
    public var sidebarShown: Bool
    /// `x`, `y`, `width`, `height` in screen coordinates, or `nil` for a window that had none yet.
    ///
    /// A flat array rather than a rect type: this file is documented as something a person may open,
    /// and `[100, 200, 1200, 800]` reads as well as four keys would without tying the format to an
    /// AppKit struct's encoding.
    public var frame: [Double]?

    public init(
        hostId: String? = nil,
        sessionId: String? = nil,
        sessionName: String? = nil,
        windowId: String? = nil,
        windowName: String? = nil,
        sidebarShown: Bool = true,
        frame: [Double]? = nil
    ) {
        self.hostId = hostId
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.windowId = windowId
        self.windowName = windowName
        self.sidebarShown = sidebarShown
        self.frame = frame
    }

    /// Field by field rather than through the synthesised initialiser, for the same reason
    /// `StoredHost` is: one missing key must not discard the whole workspace.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostId = try container.decodeIfPresent(String.self, forKey: .hostId)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName)
        windowId = try container.decodeIfPresent(String.self, forKey: .windowId)
        windowName = try container.decodeIfPresent(String.self, forKey: .windowName)
        sidebarShown = try container.decodeIfPresent(Bool.self, forKey: .sidebarShown) ?? true
        frame = try container.decodeIfPresent([Double].self, forKey: .frame)
    }

    /// The saved frame as a rect, if it is one. A frame with no area is discarded rather than
    /// applied: a zero-height window is not recoverable by dragging, and a saved one would come back
    /// invisible on every launch afterwards.
    public var rect: NSRect? {
        guard let frame, frame.count == 4, frame[2] > 1, frame[3] > 1 else { return nil }
        return NSRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
    }
}

/// One thing the user has picked out of the launcher, for F4.25's "ranked by recency".
///
/// Host-qualified, because tmux numbers and names sessions and windows **per server**: `work` and
/// `@1` exist on every host at once, and that is the common case rather than the odd one — the
/// ordinary way to reach a second host is to ssh into it, where tmux starts numbering from zero
/// exactly like the first one's. Without the host in the key, opening a window on this machine
/// would promote a stranger's window on another.
///
/// A session is keyed by **name** and a window by **id**, and neither is an oversight. A session
/// found by discovery (F4.4) has no id at all — the probe answers names — so the name is the only
/// key that fits both kinds of session row. A window's name is the opposite case: with
/// `automatic-rename` on it is whatever is *running* there and changes under the user's hands,
/// while `@3` is stable for as long as the server is. What both give up is a server restart, which
/// reissues every id, and that is why this is deliberately not `WorkspaceWindow`'s id-*and*-name
/// pair: a stale entry here costs one row's place in a list, where a stale one there would put a
/// window on a stranger's session.
public struct RecentTarget: Codable, Equatable, Hashable, Sendable {
    public var hostId: String
    /// The session's name, or `nil` when the row names a host and nothing under it.
    public var sessionName: String?
    /// `@id`, or `nil` when the row names no window.
    public var windowId: String?

    public init(hostId: String, sessionName: String? = nil, windowId: String? = nil) {
        self.hostId = hostId
        self.sessionName = sessionName
        self.windowId = windowId
    }
}

/// Everything `workspace.json` holds: the windows, the watches that belong to no window, and what
/// was used recently.
///
/// The file used to *be* the array of windows. It grew an envelope because F4.31's watched windows
/// are view state by the same definition — nothing in tmux records that somebody wants to be told
/// when `@7` prints something — but they are not a property of any one macOS window, so there was no
/// entry to put them in. F4.25's recency is the second thing of that shape. The legacy shape is
/// still read (see `WorkspaceStore.load`): a workspace is cheap to rebuild but not free, and
/// silently discarding one on the upgrade would be a worse introduction to the feature than not
/// having it.
public struct Workspace: Codable, Equatable, Sendable {
    public var windows: [WorkspaceWindow]
    public var watchedWindows: [WatchedWindow]
    /// Most recently used first.
    ///
    /// An order rather than a set of timestamps, because ranking needs to know which came first and
    /// nothing else: a stamp would be a wall clock in a file that outlives sleep, a timezone change
    /// and a clock correction, all to answer a question the array position already answers. It also
    /// keeps the file readable, which is §2.3's whole argument for JSON over a database.
    public var recents: [RecentTarget]

    public init(
        windows: [WorkspaceWindow] = [],
        watchedWindows: [WatchedWindow] = [],
        recents: [RecentTarget] = []
    ) {
        self.windows = windows
        self.watchedWindows = watchedWindows
        self.recents = recents
    }

    /// Field by field, for the same reason `WorkspaceWindow` decodes that way: one missing key must
    /// not discard the rest.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windows = try container.decodeIfPresent([WorkspaceWindow].self, forKey: .windows) ?? []
        watchedWindows = try container.decodeIfPresent([WatchedWindow].self, forKey: .watchedWindows) ?? []
        recents = try container.decodeIfPresent([RecentTarget].self, forKey: .recents) ?? []
    }

    /// How many uses the file remembers. Enough that a day's work is all in it, small enough that
    /// nothing here grows without bound: a window opened and closed every few minutes would
    /// otherwise leave an entry per window for the life of the install.
    public static let recentsLimit = 50

    /// The list with one target moved to the front, and no duplicate of it left behind.
    ///
    /// Static and pure because it is the half that can be silently wrong: leave the old copy in
    /// place and the second use of anything ranks it *lower* than the first, which reads as the
    /// list being random rather than as a bug.
    public static func promoting(_ target: RecentTarget, in recents: [RecentTarget]) -> [RecentTarget] {
        var promoted = recents.filter { $0 != target }
        promoted.insert(target, at: 0)
        return Array(promoted.prefix(recentsLimit))
    }
}

/// `workspace.json` beside `hosts.json` (§2.3).
///
/// Deliberately not `@SceneStorage`. That restores a scene's *own* value into the same scene, and
/// what has to be restored here is a relationship between a macOS window and a tmux session that
/// only exists once the host has connected and answered `list-sessions` — a round trip after the
/// window is already on screen. So the file is read once at launch and each window carries its entry
/// until the topology can satisfy it.
///
/// An unreadable file is treated as an empty workspace and left alone. Unlike `hosts.json`, nothing
/// here is the user's data — every window it describes can be reopened in a couple of clicks — so
/// moving it aside would be ceremony over something worth less than the file it would leave behind.
public actor WorkspaceStore {
    private let storeURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? HostConfigStore.applicationSupportDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.storeURL = base.appendingPathComponent("workspace.json")
    }

    public func load() -> Workspace {
        guard let data = try? Data(contentsOf: storeURL), !data.isEmpty else { return Workspace() }
        return Self.decode(data)
    }

    /// The envelope first, then the bare array the file used to be. Tried in that order because the
    /// envelope is what is written from now on and the array is the one-way upgrade — a file in the
    /// old shape is read once and rewritten in the new one by the next save.
    nonisolated static func decode(_ data: Data) -> Workspace {
        let decoder = JSONDecoder()
        if let workspace = try? decoder.decode(Workspace.self, from: data) { return workspace }
        if let windows = try? decoder.decode([WorkspaceWindow].self, from: data) {
            return Workspace(windows: windows)
        }
        return Workspace()
    }

    public func save(_ workspace: Workspace) {
        guard let data = Self.encode(workspace) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    nonisolated static func encode(_ workspace: Workspace) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(workspace)
    }

    /// The synchronous form, for `applicationShouldTerminate`.
    ///
    /// Quitting is the moment the workspace is most worth recording and the one moment there is no
    /// time to await an actor: the debounced save may not have fired since the last window moved, and
    /// the process is about to go. Writing the file is a few hundred bytes to Application Support, so
    /// doing it on the main thread costs less than arranging not to.
    public nonisolated static func saveNow(_ workspace: Workspace, directory: URL? = nil) {
        let base = directory ?? HostConfigStore.applicationSupportDirectory()
        guard let data = encode(workspace) else { return }
        try? data.write(to: base.appendingPathComponent("workspace.json"), options: .atomic)
    }
}
