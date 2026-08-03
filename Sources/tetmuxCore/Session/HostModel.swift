import Foundation

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case degraded(reason: String)
    case reconnecting(attempt: Int, nextRetryInSeconds: Double)
    case failed(reason: String)

    public var isActive: Bool {
        switch self {
        case .connecting, .connected, .degraded: return true
        case .disconnected, .reconnecting, .failed: return false
        }
    }

    /// The underlying ssh/tmux message, shown verbatim (§7) rather than paraphrased.
    public var reason: String? {
        switch self {
        case .degraded(let reason), .failed(let reason): return reason
        default: return nil
        }
    }
}

public struct TmuxPane: Identifiable, Equatable, Sendable {
    /// Carries the sigil, e.g. `%19`.
    public let id: String
    public var command: String
    public var currentPath: String
    public var isActive: Bool
    public var cols: Int
    public var rows: Int

    public init(
        id: String,
        command: String = "",
        currentPath: String = "",
        isActive: Bool = false,
        cols: Int = 80,
        rows: Int = 24
    ) {
        self.id = id
        self.command = command
        self.currentPath = currentPath
        self.isActive = isActive
        self.cols = cols
        self.rows = rows
    }
}

public struct TmuxWindow: Identifiable, Equatable, Sendable {
    /// Carries the sigil, e.g. `@13`.
    public let id: String
    public var name: String
    public var isActive: Bool
    public var hasActivity: Bool
    public var layoutString: String
    public var layoutTree: LayoutNode?
    public var panes: [TmuxPane]
    public var activePaneId: String?

    public var paneCount: Int {
        panes.isEmpty ? (layoutTree?.paneIds.count ?? 0) : panes.count
    }

    /// The pane a new terminal surface should bind to when nothing else is selected.
    public var preferredPaneId: String? {
        activePaneId ?? layoutTree?.paneIds.first ?? panes.first?.id
    }

    public var activeCommand: String {
        panes.first { $0.id == activePaneId }?.command ?? panes.first?.command ?? ""
    }

    public init(
        id: String,
        name: String,
        isActive: Bool = false,
        hasActivity: Bool = false,
        layoutString: String = "",
        panes: [TmuxPane] = [],
        activePaneId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.hasActivity = hasActivity
        self.layoutString = layoutString
        self.layoutTree = layoutString.isEmpty ? nil : try? LayoutParser.parse(layoutString)
        self.panes = panes
        self.activePaneId = activePaneId ?? self.layoutTree?.paneIds.first
    }

    /// Applies a layout string from `%layout-change` or `list-windows`, keeping the pane list and
    /// the active pane consistent with the tree tmux just told us about.
    public mutating func apply(layoutString newLayout: String) {
        guard newLayout != layoutString || layoutTree == nil else { return }
        layoutString = newLayout
        layoutTree = try? LayoutParser.parse(newLayout)

        guard let tree = layoutTree else { return }
        let ids = tree.paneIds
        panes.removeAll { !ids.contains($0.id) }
        for id in ids where !panes.contains(where: { $0.id == id }) {
            panes.append(TmuxPane(id: id))
        }
        // Keep pane order matching the layout so the inspector and the view agree.
        panes.sort { a, b in (ids.firstIndex(of: a.id) ?? 0) < (ids.firstIndex(of: b.id) ?? 0) }
        for index in panes.indices {
            if let size = tree.cellSize(ofPane: panes[index].id) {
                panes[index].cols = size.cols
                panes[index].rows = size.rows
            }
        }
        if activePaneId == nil || !ids.contains(activePaneId!) {
            activePaneId = ids.first
        }
    }
}

public struct TmuxSession: Identifiable, Equatable, Sendable {
    /// Carries the sigil, e.g. `$7`.
    public let id: String
    public var name: String
    public var windows: [TmuxWindow]
    public var activeWindowId: String?
    public var isAttached: Bool

    public var activeWindow: TmuxWindow? {
        windows.first { $0.id == activeWindowId } ?? windows.first
    }

    public init(
        id: String,
        name: String,
        windows: [TmuxWindow] = [],
        activeWindowId: String? = nil,
        isAttached: Bool = false
    ) {
        self.id = id
        self.name = name
        self.windows = windows
        self.activeWindowId = activeWindowId
        self.isAttached = isAttached
    }
}

public struct HostConfig: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let hostname: String?
    public let user: String?
    public let port: Int?
    public let isLocal: Bool
    /// Escape hatch for transports the standard ssh invocation cannot express (jump scripts,
    /// container exec wrappers). Runs through `/bin/sh -c` with `tmux -CC …` appended.
    public let customCommand: String?

    /// What `ssh` should be given as the destination.
    public var sshDestination: String {
        let target = hostname ?? name
        if let user, !user.isEmpty { return "\(user)@\(target)" }
        return target
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        hostname: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        isLocal: Bool = false,
        customCommand: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.user = user
        self.port = port
        self.isLocal = isLocal
        self.customCommand = customCommand
    }
}

public struct HostState: Identifiable, Equatable, Sendable {
    public var id: String { config.id }
    public var config: HostConfig
    public var connectionState: ConnectionState
    public var sessions: [TmuxSession]
    public var activeSessionId: String?
    public var tmuxVersion: String?
    /// Round-trip time over the live control channel (F4.29), in milliseconds.
    public var rttMilliseconds: Double?

    public var activeSession: TmuxSession? {
        sessions.first { $0.id == activeSessionId } ?? sessions.first
    }

    public init(
        config: HostConfig,
        connectionState: ConnectionState = .disconnected,
        sessions: [TmuxSession] = [],
        activeSessionId: String? = nil,
        tmuxVersion: String? = nil,
        rttMilliseconds: Double? = nil
    ) {
        self.config = config
        self.connectionState = connectionState
        self.sessions = sessions
        self.activeSessionId = activeSessionId
        self.tmuxVersion = tmuxVersion
        self.rttMilliseconds = rttMilliseconds
    }

    public func window(_ windowId: String) -> TmuxWindow? {
        for session in sessions {
            if let window = session.windows.first(where: { $0.id == windowId }) { return window }
        }
        return nil
    }
}

/// tmux feature floor (§3.4). Parsed from `display-message -p '#{version}'`, which yields
/// strings like `3.4`, `3.7b`, or `next-3.6`.
public struct TmuxVersion: Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let raw: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let numeric = trimmed.drop { !$0.isNumber }
        let parts = numeric.split(separator: ".", maxSplits: 1)
        guard let major = Int(parts.first ?? "") else { return nil }
        let minorDigits = parts.count > 1 ? parts[1].prefix { $0.isNumber } : ""
        self.major = major
        self.minor = Int(minorDigits) ?? 0
        self.raw = trimmed
    }

    public static func < (lhs: TmuxVersion, rhs: TmuxVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public static func == (lhs: TmuxVersion, rhs: TmuxVersion) -> Bool {
        (lhs.major, lhs.minor) == (rhs.major, rhs.minor)
    }

    /// `refresh-client -B` subscriptions and `%extended-output` need 3.2.
    public var supportsSubscriptions: Bool { self >= TmuxVersion("3.2")! }
    /// Below this, control mode is too different to drive; §4.6 passthrough applies.
    public var supportsControlMode: Bool { self >= TmuxVersion("2.4")! }
}
