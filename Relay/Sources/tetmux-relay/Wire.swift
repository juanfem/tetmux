import Foundation
import tetmuxCore

/// The relay's WebSocket protocol.
///
/// Pane output travels as **binary** frames, unmodified — the browser's emulator decodes UTF-8 and
/// escape sequences itself, exactly as SwiftTerm does in the app. Everything else is a **text**
/// frame holding one JSON object whose `t` names it. Binary for the bytes because they are the
/// volume, and because a pane's output is not guaranteed to be valid UTF-8 at a chunk boundary.
///
/// The browser opens with `view` (possibly empty) and the relay shows nothing until it does, so a
/// page restoring the pane it was on never flashes the relay's default first.
enum Wire {
    /// Browser → relay.
    struct Inbound: Decodable {
        /// `view`, `in` (keystrokes, as xterm.js reports them), `paste`, or `resize`.
        let t: String
        let d: String?
        let cols: Int?
        let rows: Int?
        /// `view`'s target. Any of them may be missing or stale; the relay fills in the rest
        /// (`ViewResolver`).
        let host: String?
        let session: String?
        let window: String?
        let pane: String?
    }

    /// A new pane stream starts. The browser resets its emulator on this, so that the repaint which
    /// follows lands on a clean screen rather than on the last pane's scrollback. It is also how the
    /// browser learns which tabs to highlight: whatever it asked for, this is what it got.
    struct Pane: Encodable {
        var t = "pane"
        let host: String
        let session: String
        let window: String
        let pane: String
        let cols: Int
        let rows: Int
    }

    /// tmux's size for the pane, which the browser adopts (§3.3): it asks with `resize`, and lays out
    /// only what comes back here.
    struct Size: Encodable {
        var t = "size"
        let cols: Int
        let rows: Int
    }

    /// Everything the browser can switch to: hosts, their sessions, each session's windows (the first
    /// row of tabs) and each window's panes (the second). A whole snapshot each time, sent only when
    /// it differs from the last one this socket received — at phone scale it is a few kilobytes, and
    /// a snapshot cannot drift out of step with the relay the way a stream of diffs can.
    ///
    /// Sizes are left out on purpose: they change on every resize and the tabs do not care, so
    /// including them would resend the tree each time the keyboard shows or hides.
    struct Topology: Encodable, Equatable {
        var t = "topology"
        let hosts: [Host]

        struct Host: Encodable, Equatable {
            let id: String
            let name: String
            /// `connected`, `connecting`, `reconnecting`, `disconnected` or `failed`.
            let state: String
            /// Why the host is not usable, when it is not: ssh's own message (§7), or what ssh is
            /// waiting on that the relay cannot answer yet.
            let note: String?
            let sessions: [Session]
        }

        struct Session: Encodable, Equatable {
            let id: String
            let name: String
            let windows: [Window]
        }

        struct Window: Encodable, Equatable {
            let id: String
            let label: String
            let activity: Bool
            let panes: [Pane]
        }

        struct Pane: Encodable, Equatable {
            let id: String
            let label: String
        }

        init(_ hosts: [HostState]) {
            self.hosts = hosts.map { host in
                Host(
                    id: host.id,
                    name: host.config.name,
                    state: Self.state(host.connectionState),
                    note: Self.note(host),
                    sessions: host.browsableSessions.map { session in
                        Session(id: session.id, name: session.name, windows: session.windows.map { window in
                            Window(
                                id: window.id, label: window.displayLabel, activity: window.hasActivity,
                                panes: window.panes.map { Pane(id: $0.id, label: Self.label(of: $0)) }
                            )
                        })
                    }
                )
            }
        }

        static func state(_ state: ConnectionState) -> String {
            switch state {
            case .connected, .degraded: return "connected"
            case .connecting: return "connecting"
            case .reconnecting: return "reconnecting"
            case .disconnected: return "disconnected"
            case .failed: return "failed"
            }
        }

        static func note(_ host: HostState) -> String? {
            // ssh is waiting on something the relay has no way to answer yet — a password, a host
            // key. Said, so the page shows why nothing is happening, rather than looking hung.
            if let prompt = host.authenticationPrompt { return "ssh is waiting: \(prompt.text)" }
            if let passthrough = host.passthrough { return passthrough.summary }
            if host.serverIsEmpty { return "no tmux sessions" }
            return host.connectionState.reason
        }

        /// What is running, and where: `vim · src`. The directory is what tells two shells apart,
        /// which is the common case for a split.
        static func label(of pane: TmuxPane) -> String {
            let place = pane.currentPath.split(separator: "/").last.map(String.init) ?? ""
            switch (pane.command.isEmpty, place.isEmpty) {
            case (false, false): return "\(pane.command) · \(place)"
            case (false, true): return pane.command
            case (true, false): return place
            case (true, true): return pane.id
            }
        }
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        // An encoding failure here is a programming error in the structs above, not a runtime state.
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8), as: UTF8.self)
    }
}
