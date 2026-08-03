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

/// An ssh port forward carried by a host's control channel — `-L`, `-R`, or `-D`.
///
/// §1.2 rules out a port-forward *management* UI, and this is not one: a forward is a property of how
/// a host is connected, established with the channel and gone with it. There is no live forward
/// inspector, no per-forward state, and nothing that outlives the ssh process.
public struct PortForward: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        /// `-L` — a local port reaching a service on the far side.
        case local
        /// `-R` — a port on the far side reaching a service here.
        case remote
        /// `-D` — a local SOCKS proxy.
        case dynamic

        public var id: String { rawValue }

        public var flag: String {
            switch self {
            case .local: return "-L"
            case .remote: return "-R"
            case .dynamic: return "-D"
            }
        }

        public var title: String {
            switch self {
            case .local: return "Local (-L)"
            case .remote: return "Remote (-R)"
            case .dynamic: return "SOCKS proxy (-D)"
            }
        }

        /// A SOCKS proxy has no fixed destination; it decides per connection.
        public var needsDestination: Bool { self != .dynamic }
    }

    public var id: UUID
    public var kind: Kind
    /// Which local (or, for `-R`, remote) interface to listen on. Empty means ssh's default, which
    /// is loopback unless `GatewayPorts` says otherwise — deliberately not overridden here.
    public var bindAddress: String
    public var listenPort: Int
    public var destinationHost: String
    public var destinationPort: Int

    public init(
        id: UUID = UUID(),
        kind: Kind = .local,
        bindAddress: String = "",
        listenPort: Int = 0,
        destinationHost: String = "localhost",
        destinationPort: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.bindAddress = bindAddress
        self.listenPort = listenPort
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
    }

    /// Whether this forward is complete enough to hand to ssh. Incomplete rows are skipped rather
        /// than passed through: a malformed `-L` makes ssh exit before tmux ever starts, which the user
    /// would see as "the host stopped working" long after they half-filled a form.
    public var isValid: Bool {
        guard Self.isValidPort(listenPort) else { return false }
        guard Self.isPlausibleAddress(bindAddress) else { return false }
        guard kind.needsDestination else { return true }
        return Self.isValidPort(destinationPort)
            && !destinationHost.isEmpty
            && Self.isPlausibleAddress(destinationHost)
    }

    /// The value for the flag: `[bind:]port` for `-D`, `[bind:]port:host:hostport` otherwise.
    public var specification: String {
        let bind = bindAddress.isEmpty ? "" : "\(Self.bracketIfNeeded(bindAddress)):"
        switch kind {
        case .dynamic:
            return "\(bind)\(listenPort)"
        case .local, .remote:
            return "\(bind)\(listenPort):\(Self.bracketIfNeeded(destinationHost)):\(destinationPort)"
        }
    }

    public var displayDescription: String {
        switch kind {
        case .local:
            return "localhost:\(listenPort) → \(destinationHost):\(destinationPort) on the host"
        case .remote:
            return "host:\(listenPort) → \(destinationHost):\(destinationPort) from here"
        case .dynamic:
            return "SOCKS proxy on localhost:\(listenPort)"
        }
    }

    /// An IPv6 literal has to be bracketed, or its colons are read as field separators.
    private static func bracketIfNeeded(_ address: String) -> String {
        guard address.contains(":"), !address.hasPrefix("[") else { return address }
        return "[\(address)]"
    }

    private static func isValidPort(_ port: Int) -> Bool { (1...65535).contains(port) }

    /// Whitespace would split the specification into two argv words, and a control character would
    /// mean something no host name legitimately means.
    private static func isPlausibleAddress(_ address: String) -> Bool {
        !address.contains(where: { $0.isWhitespace })
            && !address.unicodeScalars.contains { $0.properties.generalCategory == .control }
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
    /// Whether this host is expected to authenticate with a password, so ssh's prompt is answered
    /// rather than left to time out behind a GUI that never shows it. Keys remain ssh's first
    /// choice either way — this only decides what happens when a prompt actually appears.
    public let usesPassword: Bool
    /// Whether the password is expected in the Keychain. The Keychain, not this flag, is the source
    /// of truth for the secret; the flag only says what the UI should offer. No password is ever
    /// stored in `hosts.json`.
    public let storesPasswordInKeychain: Bool
    public let forwards: [PortForward]

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
        customCommand: String? = nil,
        usesPassword: Bool = false,
        storesPasswordInKeychain: Bool = false,
        forwards: [PortForward] = []
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.user = user
        self.port = port
        self.isLocal = isLocal
        self.customCommand = customCommand
        self.usesPassword = usesPassword
        self.storesPasswordInKeychain = storesPasswordInKeychain
        self.forwards = forwards
    }
}

/// A prompt ssh wrote to the channel before the tmux protocol started.
///
/// Surfaced on `HostState` rather than folded into `ConnectionState`: a prompt is a request for
/// input, not a connection state, and every exhaustive switch over `ConnectionState` in the UI would
/// otherwise have to grow a case that has nothing to say about being connected.
/// A command the user asked for that tmux refused (§7).
///
/// Control mode answers a failed command with `%error` and a body, and that body is the only
/// explanation there is — "duplicate session: work", "window only linked to one session",
/// "can't find pane %7". Without this the command simply appeared not to happen: the failure went to
/// the diagnostic logger, which only `--diagnose` ever installs, so in the app nothing happened at
/// all and nothing said why.
///
/// Only commands the user initiated get here. tmux refusing an internal `resize-window` on an old
/// server is our problem to handle, not a sentence to put in front of somebody.
public struct CommandFailure: Equatable, Sendable, Identifiable {
    /// Distinct per occurrence, so the same failure twice reads as two attempts rather than one
    /// banner that never went away.
    public var id: UUID
    /// What was being attempted, to introduce tmux's own words: "Rename window failed: …".
    public var action: String
    /// What tmux said, verbatim (§7). Never paraphrased — tmux names the thing it could not find.
    public var message: String

    public init(id: UUID = UUID(), action: String, message: String) {
        self.id = id
        self.action = action
        self.message = message
    }
}

public struct AuthenticationPrompt: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// An account password, which is the one thing a per-host Keychain entry can answer.
        case password
        /// A private key's passphrase. Belongs to the key, not the host, so it is never filled from
        /// the host's stored password and is never offered for storage.
        case keyPassphrase
    }

    /// Distinct per prompt occurrence, so a second prompt after a rejected password is not mistaken
    /// for the first one still being on screen.
    public var id: UUID
    public var kind: Kind
    /// What ssh actually asked, verbatim (§7) — it names the account and host, which is the only way
    /// the user can tell which of several prompts they are answering.
    public var text: String

    public init(id: UUID = UUID(), kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
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
    /// Set while ssh is waiting for a secret on this host's channel. Cleared as soon as it is
    /// answered or the channel goes away.
    public var authenticationPrompt: AuthenticationPrompt?
    /// The most recent command of the user's that tmux refused (§7). Cleared when dismissed, and on
    /// each connect so a reconnect never opens showing a failure from the previous channel.
    public var lastCommandFailure: CommandFailure?

    public var activeSession: TmuxSession? {
        sessions.first { $0.id == activeSessionId } ?? sessions.first
    }

    public init(
        config: HostConfig,
        connectionState: ConnectionState = .disconnected,
        sessions: [TmuxSession] = [],
        activeSessionId: String? = nil,
        tmuxVersion: String? = nil,
        rttMilliseconds: Double? = nil,
        authenticationPrompt: AuthenticationPrompt? = nil,
        lastCommandFailure: CommandFailure? = nil
    ) {
        self.config = config
        self.connectionState = connectionState
        self.sessions = sessions
        self.activeSessionId = activeSessionId
        self.tmuxVersion = tmuxVersion
        self.rttMilliseconds = rttMilliseconds
        self.authenticationPrompt = authenticationPrompt
        self.lastCommandFailure = lastCommandFailure
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
    /// Control-mode flow control — `refresh-client -f pause-after=`, `refresh-client -A`, and the
    /// `%pause`/`%continue` notifications that go with them — landed in 3.2 (P6.5).
    public var supportsFlowControl: Bool { self >= TmuxVersion("3.2")! }
    /// Below this, control mode is too different to drive; §4.6 passthrough applies.
    public var supportsControlMode: Bool { self >= TmuxVersion("2.4")! }
}
