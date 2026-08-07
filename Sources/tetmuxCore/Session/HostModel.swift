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

    /// What tmux mode this pane is in — `copy-mode`, `view-mode`, or empty for none.
    ///
    /// A mode is a per-client screen *overlay*, and control mode is never streamed one: the bytes for
    /// what is now on the pane simply do not arrive. So a pane somebody put into copy mode from
    /// another client, or with a `prefix [` that reached tmux, keeps painting what was there before
    /// and then stops moving, with nothing to say why. That is the same picture as a dead channel.
    ///
    /// The mode's *name* rather than a `Bool`, because `%pane-mode-changed` says only that something
    /// changed — not which mode, and not whether it was entered or left — so this is read from
    /// `list-panes` and the string is what tmux gives. `view-mode` is what a pane showing command
    /// output (`display-message`, `list-keys`) is in, and it is not copy mode; conflating them would
    /// offer copy-mode commands to a pane that has none.
    public var mode: String

    /// tmux 3.7b: `#{pane_in_mode}` is 1 and `#{pane_mode}` is `copy-mode`.
    public var isInCopyMode: Bool { mode == "copy-mode" }
    /// Any mode at all, which is what "this pane is showing an overlay we cannot see" means.
    public var isInMode: Bool { !mode.isEmpty }

    public init(
        id: String,
        command: String = "",
        currentPath: String = "",
        isActive: Bool = false,
        cols: Int = 80,
        rows: Int = 24,
        mode: String = ""
    ) {
        self.id = id
        self.command = command
        self.currentPath = currentPath
        self.isActive = isActive
        self.cols = cols
        self.rows = rows
        self.mode = mode
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
    /// Whether the user named this window, rather than tmux naming it after what is running.
    public var hasExplicitName: Bool

    /// What is actually on screen, which differs from `layoutString` exactly when a pane is zoomed.
    ///
    /// `%layout-change` has carried three fields since tmux 2.5 and the third is the window's flags;
    /// the second is this. tmux keeps `window_layout` as the layout the window would have *unzoomed*,
    /// so a client that renders it while a pane is zoomed paints the wrong grid — and worse, forces
    /// each surface to its unzoomed cell size while tmux is emitting output sized to the whole
    /// window. The result is wrapped and truncated content that cannot be recovered without
    /// unzooming from somewhere else.
    public var visibleLayoutString: String = ""
    public var visibleLayoutTree: LayoutNode?
    /// `Z` in the window flags. Also carried in `#{window_flags}` from `list-windows`, because a
    /// window that was already zoomed when tetmux attached never sends a `%layout-change` at all.
    public var isZoomed: Bool = false

    /// The tree a view should render: what tmux is actually drawing, falling back to the full layout.
    public var renderTree: LayoutNode? {
        isZoomed ? (visibleLayoutTree ?? layoutTree) : layoutTree
    }

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

    /// How this window should be listed, in the sidebar and on its tab.
    ///
    /// A name the user chose always wins — that is the whole point of having named it. Otherwise the
    /// window is identified by what is *running* in it, which for a split window means every pane, not
    /// just the active one: tmux's automatic name follows whichever pane is current, so a split
    /// window's label used to change as the user moved between panes, and two split windows read
    /// identically whenever their active panes happened to match.
    public var displayLabel: String {
        guard !hasExplicitName, paneCount > 1 else { return name }
        let commands = panes.map(\.command).filter { !$0.isEmpty }
        return commands.isEmpty ? name : commands.joined(separator: " · ")
    }

    /// One label part per pane, when the label is made of what is running rather than of a name.
    ///
    /// `nil` whenever `displayLabel` is a single name — a window the user named, or one with a single
    /// pane — because there is nothing to attribute to a pane in that case.
    ///
    /// Exists so a tab can weight the part belonging to the focused pane without deciding for itself
    /// what a window is called. Built from the same panes and the same filter as `displayLabel`, and
    /// joined with the same separator, so the two cannot describe a window differently.
    public var displayLabelSegments: [LabelSegment]? {
        guard !hasExplicitName, paneCount > 1 else { return nil }
        let segments = panes
            .filter { !$0.command.isEmpty }
            .map { LabelSegment(paneId: $0.id, text: $0.command) }
        return segments.isEmpty ? nil : segments
    }

    public static let labelSeparator = " · "

    public struct LabelSegment: Equatable, Sendable, Identifiable {
        public let paneId: String
        public let text: String
        public var id: String { paneId }
    }

    public init(
        id: String,
        name: String,
        isActive: Bool = false,
        hasActivity: Bool = false,
        layoutString: String = "",
        panes: [TmuxPane] = [],
        activePaneId: String? = nil,
        hasExplicitName: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.hasActivity = hasActivity
        self.hasExplicitName = hasExplicitName
        self.layoutString = layoutString
        self.layoutTree = layoutString.isEmpty ? nil : try? LayoutParser.parse(layoutString, verifyChecksum: true)
        self.visibleLayoutString = layoutString
        self.visibleLayoutTree = self.layoutTree
        self.panes = panes
        self.activePaneId = activePaneId ?? self.layoutTree?.paneIds.first
    }

    /// What `apply` did with a layout tmux sent, so a caller with a logger can say when one was
    /// thrown away — the model has no way to report it and a silently ignored layout is exactly the
    /// kind of failure this codebase keeps finding.
    public enum LayoutApplyResult: Equatable, Sendable {
        case applied
        /// Same layout, same visible layout, same zoom: nothing to do.
        case unchanged
        /// Neither the layout nor the pane list moved. `reason` is the parse failure.
        case rejected(reason: String)
    }

    /// Applies a layout string from `%layout-change` or `list-windows`, keeping the pane list and
    /// the active pane consistent with the tree tmux just told us about.
    ///
    /// Both fields are parsed with **checksum verification on** (R3.5), and an update that fails
    /// either parse is rejected *whole*: the window keeps the last layout that did parse, string and
    /// tree together, rather than being left holding a tree of `nil`. That is the only reason
    /// switching validation on here is safe — `layoutTree == nil` renders an empty window, so a
    /// checksum quirk in some tmux build would otherwise cost the user their panes on the first
    /// `%layout-change`, which is what kept this off. Keeping the previous tree loses nothing that
    /// was not already lost: it is a grid that was right a moment ago rather than no grid at all,
    /// and the next layout tmux sends replaces it.
    ///
    /// Rejecting *both* fields on one bad parse matters while zoomed. They describe one window and
    /// arrive in one notification; applying the full layout with no visible tree would set `isZoomed`
    /// while `renderTree` fell back to the unzoomed grid, which is precisely the wrapped-and-
    /// truncated failure `visibleLayoutString` exists to prevent.
    ///
    /// - Parameters:
    ///   - visibleLayout: `#{window_visible_layout}`, which differs only while a pane is zoomed.
    ///   - flags: `#{window_flags}`; `Z` is the zoom.
    @discardableResult
    public mutating func apply(
        layoutString newLayout: String,
        visibleLayout: String? = nil,
        flags: String? = nil
    ) -> LayoutApplyResult {
        let newVisible = visibleLayout ?? newLayout
        let newZoomed = flags.map { $0.contains("Z") } ?? isZoomed
        let unchanged = newLayout == layoutString
            && newVisible == visibleLayoutString
            && newZoomed == isZoomed
            && layoutTree != nil
        guard !unchanged else { return .unchanged }

        let newTree: LayoutNode
        let newVisibleTree: LayoutNode
        do {
            newTree = try LayoutParser.parse(newLayout, verifyChecksum: true)
            // Only worth a second parse when it actually differs, which is only while zoomed.
            newVisibleTree = newVisible == newLayout
                ? newTree
                : try LayoutParser.parse(newVisible, verifyChecksum: true)
        } catch {
            return .rejected(reason: "\(error)")
        }

        layoutString = newLayout
        layoutTree = newTree
        isZoomed = newZoomed
        visibleLayoutString = newVisible
        visibleLayoutTree = newVisibleTree

        // Membership comes from the *full* layout even while zoomed: the other panes still exist, and
        // taking the visible tree here would drop them from `paneCount` and from `displayLabel`, so a
        // zoomed split window would relabel itself and claim to hold one pane.
        let ids = newTree.paneIds
        panes.removeAll { !ids.contains($0.id) }
        for id in ids where !panes.contains(where: { $0.id == id }) {
            panes.append(TmuxPane(id: id))
        }
        // Keep pane order matching the layout so the inspector and the view agree.
        panes.sort { a, b in (ids.firstIndex(of: a.id) ?? 0) < (ids.firstIndex(of: b.id) ?? 0) }
        // Sizes, though, come from what is on screen — that is what tmux is emitting output for. A
        // hidden pane keeps whatever it last had; nothing is painting it.
        let sizing = renderTree ?? newTree
        for index in panes.indices {
            if let size = sizing.cellSize(ofPane: panes[index].id) {
                panes[index].cols = size.cols
                panes[index].rows = size.rows
            }
        }
        if activePaneId == nil || !ids.contains(activePaneId!) {
            activePaneId = ids.first
        }
        return .applied
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

/// A tmux client attached to this server — one row of `list-clients`.
///
/// It exists because killing is not a private act. `kill-session` ends the session for everyone
/// attached to it, and closing the last link of a window kills the window in every client showing it
/// — so the confirmation that asks about it has to be able to say who else is there. Before this it
/// described the panes and said nothing about the people.
///
/// What tmux can say about a stranger is here and no more: the unix user, the tty, the terminal type,
/// and when they last did something. There is no client hostname or address in tmux's model — see
/// `TmuxCommand.clientsFormat` — so this deliberately carries none rather than inventing one.
public struct TmuxClient: Identifiable, Equatable, Sendable {
    /// The tty is tmux's own name for a client: `client_name` *is* the tty, and `detach-client -t`
    /// takes it. Unique per client for as long as the client exists, which is the whole lifetime of
    /// anything the model does with one.
    public var id: String { tty }
    public let tty: String
    /// The `$id` of the session this client is attached to.
    public let sessionId: String
    /// Empty below tmux 3.3, which has no `client_user`.
    public let user: String
    /// `client_termname`, e.g. `xterm-256color`. Empty for a control-mode client on some versions.
    public let terminal: String
    /// A `tmux -CC` client: tetmux's own channels, and anything else speaking control mode.
    public let isControlMode: Bool
    /// One of *this* tetmux's channels, matched by tty against the ttys our channels reported.
    ///
    /// A channel that has not yet answered `#{client_tty}` cannot be recognised, so a client can
    /// briefly look like a stranger — the same window F4.17's reconciliation skips itself in. It is
    /// visible rather than hidden: the row says "control mode", which is what tells the two apart.
    public let isOurs: Bool
    /// `client_activity` — when this client last did anything. The difference between a colleague at
    /// work in the session and a terminal somebody left open in another space last Tuesday.
    public let lastActivity: Date?

    public init(
        tty: String,
        sessionId: String,
        user: String = "",
        terminal: String = "",
        isControlMode: Bool = false,
        isOurs: Bool = false,
        lastActivity: Date? = nil
    ) {
        self.tty = tty
        self.sessionId = sessionId
        self.user = user
        self.terminal = terminal
        self.isControlMode = isControlMode
        self.isOurs = isOurs
        self.lastActivity = lastActivity
    }

    /// How the client is named in a sentence: the user when tmux knows it, and the tty either way.
    ///
    /// The tty is never dropped. It is the only field that distinguishes two clients of the same
    /// user, which on a personal machine is *every* pair of them.
    public var displayName: String {
        user.isEmpty ? tty : "\(user) on \(tty)"
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
    /// Extra `ssh` options, exactly as the user would type them on a command line.
    ///
    /// Held as one string because that is how it is typed and how it reads back; it is split into
    /// argv elements by `TmuxCommand.splitArguments`, which understands quotes so a value containing
    /// a space survives. No shell is involved at any point.
    public let extraSshArguments: String
    /// `ssh -X`. A checkbox rather than something to remember to type, because it is the one extra
    /// option with a reason to be discoverable.
    public let forwardsX11: Bool
    /// Where a new session's first pane starts, as `new-session -c` (F4.11).
    ///
    /// A property of the host rather than something asked for at creation time, which is the whole
    /// reason it can exist at all: `createSessionWithDefaultName` deliberately puts *no* dialog
    /// between wanting a shell and having one, and a start directory is a thing you decide once per
    /// machine rather than once per session. Resolved by tmux on the far side, so `~` and a path that
    /// only exists remotely both work.
    public let startDirectory: String?

    /// What a new session's first pane runs instead of a shell — `new-session`'s trailing
    /// `shell-command` (F4.11).
    ///
    /// A property of the host for the same reason `startDirectory` is, and it is the same argument:
    /// `createSessionWithDefaultName` puts nothing between wanting a shell and having one, so
    /// anything asked at creation time cannot exist at all. "This box is reached through
    /// `srun --pty bash`" or "start a login shell here" is decided once per machine in any case.
    /// tmux hands the string to the shell on the far side, so it is written in the *remote* machine's
    /// terms and nothing here tries to resolve it.
    ///
    /// Sessions only, never windows opened afterwards. That is tmux's own division — `new-window`
    /// takes `default-command` — and a wrapper answering "how do I get a shell on this host" belongs
    /// at the point a session is made rather than on every tab.
    ///
    /// A command that *exits* takes its window with it, and tmux destroys a session with no windows
    /// left. That is what `new-session <command>` does for anyone, and it is deliberately not papered
    /// over: `remain-on-exit` is an option on the user's server, not ours to set from here.
    public let initialCommand: String?

    /// T5.6 — whether a program in this host's panes may write the Mac's clipboard with OSC 52.
    ///
    /// Per host and denied by default, which is the whole of what T5.6 asks for and what the flag on
    /// `TerminalTheme` could not express: an application-wide setting is a decision about a machine
    /// you trust and a machine you do not at the same time. A pane's contents are remote text, and a
    /// sequence in them can replace whatever the user was about to paste — including into a shell.
    /// Clipboard *reads* are never permitted at any setting and have no field here to turn on.
    public let allowRemoteClipboardWrite: Bool

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
        forwards: [PortForward] = [],
        extraSshArguments: String = "",
        forwardsX11: Bool = false,
        startDirectory: String? = nil,
        initialCommand: String? = nil,
        allowRemoteClipboardWrite: Bool = false
    ) {
        self.allowRemoteClipboardWrite = allowRemoteClipboardWrite
        self.initialCommand = initialCommand
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
        self.extraSshArguments = extraSshArguments
        self.forwardsX11 = forwardsX11
        self.startDirectory = startDirectory
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
        /// The first-contact host-key confirmation — `Are you sure you want to continue connecting
        /// (yes/no/[fingerprint])?`.
        ///
        /// Not a secret and not a text field: a decision, with the fingerprint in front of the person
        /// making it. §2.3 forbids the *application* accepting a host key, which this does not do —
        /// it puts ssh's own question on screen and sends the user's answer, which is what a terminal
        /// does. A key that has *changed* never reaches here: ssh refuses that outright rather than
        /// asking, so this can only ever be a host nobody has met before.
        case hostKey
        /// Anything else ssh has stopped to ask: a one-time code, a PAM challenge, a question from a
        /// `ProxyCommand`. Unclassifiable by construction — the shapes vary per site — so it is shown
        /// verbatim and whatever is typed goes back. Treated as a secret (never echoed, never stored)
        /// because the commonest case is a second factor.
        case question
    }

    /// Distinct per prompt occurrence, so a second prompt after a rejected password is not mistaken
    /// for the first one still being on screen.
    public var id: UUID
    public var kind: Kind
    /// What ssh actually asked, verbatim (§7) — it names the account and host, which is the only way
    /// the user can tell which of several prompts they are answering.
    public var text: String
    /// The lines leading up to the question, when the question is meaningless without them.
    ///
    /// A host-key confirmation is the case: the fingerprint the user is being asked to trust is on a
    /// different line from the question, and a dialog that showed only "Are you sure you want to
    /// continue connecting?" would be asking somebody to approve something it had not shown them.
    public var context: String?

    public init(id: UUID = UUID(), kind: Kind, text: String, context: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.context = context
    }

    /// Whether the answer is a secret — which decides both that the field is obscured and that a
    /// wrong answer must not be retried automatically.
    public var answerIsSecret: Bool {
        switch kind {
        case .password, .keyPassphrase, .question: return true
        case .hostKey: return false
        }
    }
}

/// §4.6 / F4.27 — what a host falls back to when control mode is not available on it.
///
/// Passthrough is not a degraded control-mode channel; it is a different channel. One tmux client
/// runs on a pty and paints itself into a single terminal surface, with tmux's own status bar,
/// borders and prefix key on screen — the three things tetmux otherwise replaces. Nothing above the
/// transport knows the protocol, because there is no protocol: bytes go out as keystrokes and come
/// back as pixels. So there is no session tree, no tab per window, and no GUI split, and this state
/// existing is what tells every surface to stop offering them.
///
/// The SRD calls this first-class rather than a courtesy, and the reason is institutional: HPC and
/// long-lived enterprise images run tmux versions from years ago, and an application that refuses to
/// connect to them is useless in exactly the environment where session persistence matters most.
public struct PassthroughState: Equatable, Sendable {
    /// Why control mode is not being used. The two are not the same fallback: one still runs tmux and
    /// keeps the user's sessions, the other has no tmux to run at all and is a plain login shell with
    /// nothing persistent behind it.
    public enum Reason: Equatable, Sendable {
        /// R3.8's `< 2.4` row. The server speaks control mode, but not one this client can drive.
        case belowControlModeFloor(version: String)
        /// R3.8's last row: no tmux on the far side. A shell is all that can be offered, and it is
        /// offered rather than started — there are no sessions to come back to, so opening one
        /// unbidden would be a decision nobody made.
        case tmuxUnavailable
    }

    public enum Phase: Equatable, Sendable {
        /// Available and not started. Only `tmuxUnavailable` waits here.
        case offered
        case connecting
        case running
        /// The process ended — `exit` at the shell, the link dropping, tmux being killed. Deliberately
        /// not restarted: in a mode with no protocol there is nothing to tell an orderly exit from a
        /// failure, and reopening a shell somebody just closed is the F4.15 mistake in a new place.
        case ended(reason: String)
    }

    public var reason: Reason
    public var phase: Phase
    /// §7 — what the far end actually said, verbatim. The version string, or ssh's own complaint.
    public var detail: String

    public init(reason: Reason, phase: Phase, detail: String) {
        self.reason = reason
        self.phase = phase
        self.detail = detail
    }

    /// Whether tmux is in the loop at all. Derived rather than stored, so it cannot disagree with the
    /// reason it follows from — and it is the difference between "your sessions are still there" and
    /// "this window is all there is".
    public var usesTmux: Bool {
        if case .belowControlModeFloor = reason { return true }
        return false
    }

    public var isRunning: Bool {
        switch phase {
        case .connecting, .running: return true
        case .offered, .ended: return false
        }
    }

    /// The mode indicator's own sentence (F4.27 — "the mode is clearly indicated").
    ///
    /// Here rather than in the view because three surfaces say it — the banner over the terminal, the
    /// sidebar row, and the placeholder that offers to start it — and a mode named differently in
    /// each of them is a mode the user has to work out for themselves.
    public var summary: String {
        switch reason {
        case .belowControlModeFloor(let version):
            return "Passthrough — tmux \(version) on this host is below the control-mode floor (2.4)."
        case .tmuxUnavailable:
            return "Plain shell — there is no tmux on this host."
        }
    }

    /// What the user loses, said once, where it belongs: beside the mode it is true of.
    public var consequence: String {
        usesTmux
            ? "This is one tmux client in one surface, with tmux's own status bar and prefix key. Tabs, splits and the session tree are tmux's here, not tetmux's."
            : "A login shell on this host, with nothing to reattach to. Install tmux there to get sessions that survive the connection."
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
    /// Sessions this host has a control-mode client for, and which therefore stream `%output`.
    ///
    /// Not the same as `TmuxSession.isAttached`, which is tmux's own count of clients and includes
    /// every terminal elsewhere on the machine that happens to be attached. This is what *tetmux*
    /// is attached to, and so the only honest answer to "are these panes live or a photograph?".
    /// A session whose channel is still connecting is included: it is about to be live, and a
    /// banner that appears for a moment and withdraws is worse than no banner at all.
    public var liveSessionIds: Set<String> = []
    /// Every client attached to this server, tetmux's own channels included and marked as such.
    ///
    /// Re-read on each topology refresh and whenever tmux says a client came or went, so the
    /// destructive confirmations can name who else is in the session they are about to end. It is not
    /// the same fact as `TmuxSession.isAttached`, which is a count with nobody's name on it, nor as
    /// `liveSessionIds`, which is only ever about us.
    public var clients: [TmuxClient] = []
    /// F4.15's second half — the name of the session that *ended*, as opposed to a link that dropped.
    ///
    /// Deliberately its own field rather than a `ConnectionState` case, for the same reason
    /// `authenticationPrompt` is not one: every switch over the state would grow an arm that means
    /// nothing to it. Without this, a session ending presents as a bare `.disconnected` — visually
    /// identical to "you were never connected" — and the Connect beside it lands on whatever session
    /// the server used most recently, which is not the one the user was in.
    ///
    /// Set where the `%exit` handler distinguishes an announced end from a dropped link, and cleared
    /// on any successful attach and on any explicit connect. It is the one place recreation *by
    /// remembered name* is legitimate: the user is reading the name and pressing the button beside it.
    public var endedSessionName: String?

    /// §4.6 — set when control mode is not what this host is being driven with. Non-nil is the one
    /// signal every surface asks: there is no session tree behind a passthrough host, so a view that
    /// went on drawing one would be drawing a tree of nothing.
    public var passthrough: PassthroughState?

    /// F4.4 — what a `tmux -C list-sessions` found on this host, with nothing attached to it.
    ///
    /// Kept apart from `sessions` rather than merged into it, and the distinction is the point.
    /// `sessions` is what a channel reported: those sessions have windows, have panes, and can be
    /// switched to. A probe answers one question — which sessions exist — so a discovered session is
    /// a *leaf*, and code that assumed otherwise would silently render an empty tree or issue
    /// commands down a channel that is not there.
    ///
    /// `nil` means nobody has asked yet, which is not the same as an empty list: an empty list is a
    /// host that answered "no sessions", and that answer is worth having. Without the distinction a
    /// server that has gone away is indistinguishable from one nobody has probed.
    public var discoveredSessions: [TmuxSession]?

    /// The sessions to *offer* on this host, whichever way we learned them.
    ///
    /// One place, because the sidebar, the launcher and the menu bar all ask and disagreeing about
    /// what a host contains is the sort of thing that makes a tree feel unrelated to the app. A live
    /// channel always wins — it knows about windows, and it is current by notification rather than by
    /// probe. Otherwise the probe wins over whatever a dead channel left behind, including when it
    /// found nothing: the sessions listed after a link drops are deliberately kept ("out of reach,
    /// not gone"), and a probe that says the server is empty is the evidence that they really are.
    public var browsableSessions: [TmuxSession] {
        if connectionState.isActive { return sessions }
        return discoveredSessions ?? sessions
    }

    public var activeSession: TmuxSession? {
        sessions.first { $0.id == activeSessionId } ?? sessions.first
    }

    /// The clients attached to a session that are *not* ours — the ones a kill would throw out.
    ///
    /// Ours are excluded because they are this application: telling the user that killing a session
    /// will detach the window they are killing it from is noise, and counting them would turn "you
    /// are alone in here" into "3 clients attached".
    public func otherClients(attachedTo sessionId: String) -> [TmuxClient] {
        clients.filter { $0.sessionId == sessionId && !$0.isOurs }
    }

    /// Whether this host is streaming a session's panes rather than showing a still frame of them.
    public func isLive(_ sessionId: String?) -> Bool {
        guard let sessionId else { return false }
        return liveSessionIds.contains(sessionId)
    }

    public init(
        config: HostConfig,
        connectionState: ConnectionState = .disconnected,
        sessions: [TmuxSession] = [],
        activeSessionId: String? = nil,
        tmuxVersion: String? = nil,
        rttMilliseconds: Double? = nil,
        authenticationPrompt: AuthenticationPrompt? = nil,
        lastCommandFailure: CommandFailure? = nil,
        liveSessionIds: Set<String> = [],
        clients: [TmuxClient] = []
    ) {
        self.config = config
        self.connectionState = connectionState
        self.sessions = sessions
        self.activeSessionId = activeSessionId
        self.tmuxVersion = tmuxVersion
        self.rttMilliseconds = rttMilliseconds
        self.authenticationPrompt = authenticationPrompt
        self.lastCommandFailure = lastCommandFailure
        self.liveSessionIds = liveSessionIds
        self.clients = clients
    }

    public func window(_ windowId: String) -> TmuxWindow? {
        for session in sessions {
            if let window = session.windows.first(where: { $0.id == windowId }) { return window }
        }
        return nil
    }

    /// A pane anywhere on this host. Pane ids are unique per server, so the search is over the whole
    /// host rather than one session — and a window linked into several sessions would otherwise be
    /// found or missed depending on which session was asked.
    public func pane(_ paneId: String) -> TmuxPane? {
        for session in sessions {
            for window in session.windows {
                if let pane = window.panes.first(where: { $0.id == paneId }) { return pane }
            }
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
    /// `move-window -a`/`-b`, which places a window next to another one instead of at a numbered
    /// index. Added in 3.2; 3.0 answers `move-window: illegal option -- b` and offers only `[-dkr]`.
    /// Below it, the same reordering is built out of `swap-window`.
    public var movesWindowsRelatively: Bool { self >= TmuxVersion("3.2")! }
    /// `window-size manual` plus `resize-window -t @id`, which is what lets one macOS window size its
    /// tmux window independently of another's. Below it, `window-size latest` and `refresh-client -C`
    /// are the only mechanism and every client's size is a vote (F4.17).
    public var sizesWindowsIndividually: Bool { self >= TmuxVersion("2.9")! }
}

/// What tetmux calls a session it made itself.
///
/// One rule, in the layer both callers can reach. There used to be two: the sidebar's New Session
/// counted up a `tetmux_N` series, while anything the *connection* created — a first connect to a
/// host, or an empty server the user asked to open — was hardcoded to `tetmux-main`, from a function
/// that took a `HostConfig` and ignored it. The seam showed on the placeholder F4.15 puts up when
/// the last session ends: "Recreate “tetmux-main”" sat beside a button that also made
/// `tetmux-main`, so two different-sounding choices did the same thing.
///
/// The index is the lowest free one rather than a count, so closing `tetmux_2` and making another
/// gives `tetmux_2` back instead of climbing forever.
public enum SessionNaming {

    public static let prefix = "tetmux_"

    public static func nextName(taken: Set<String>) -> String {
        var index = 1
        while taken.contains("\(prefix)\(index)") { index += 1 }
        return "\(prefix)\(index)"
    }
}
