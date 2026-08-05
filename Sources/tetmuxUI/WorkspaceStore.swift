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

    public func load() -> [WorkspaceWindow] {
        guard let data = try? Data(contentsOf: storeURL), !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([WorkspaceWindow].self, from: data)) ?? []
    }

    public func save(_ windows: [WorkspaceWindow]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(windows) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    /// The synchronous form, for `applicationShouldTerminate`.
    ///
    /// Quitting is the moment the workspace is most worth recording and the one moment there is no
    /// time to await an actor: the debounced save may not have fired since the last window moved, and
    /// the process is about to go. Writing the file is a few hundred bytes to Application Support, so
    /// doing it on the main thread costs less than arranging not to.
    public nonisolated static func saveNow(_ windows: [WorkspaceWindow], directory: URL? = nil) {
        let base = directory ?? HostConfigStore.applicationSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(windows) else { return }
        try? data.write(to: base.appendingPathComponent("workspace.json"), options: .atomic)
    }
}
