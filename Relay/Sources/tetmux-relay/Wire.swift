import Foundation
import tetmuxCore
import tetmuxPolicy

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
    ///
    /// | `t` | fields | |
    /// |---|---|---|
    /// | `view` | `host`, `session`, `window`, `pane`, all optional | what to show |
    /// | `in`, `paste` | `d` | to the pane being shown |
    /// | `resize` | `cols`, `rows` | the size the browser would like (§3.3) |
    /// | `newWindow` | | in the session being shown; the view follows it |
    /// | `split` | `dir`: `right` or `down` | the pane being shown; the view follows the new one |
    /// | `closePane` | | the pane being shown — a window's last pane closes the window, below |
    /// | `closeWindow` | `window`, `confirm` | F4.9/F4.10, decided by `ClosePolicy` |
    /// | `renameWindow` | `window`, `name` | |
    /// | `newSession` | `host`, `name` | the view follows it |
    /// | `answer`, `cancelPrompt` | `host`, `d` | what ssh is waiting on |
    /// | `addHost` | `destination`, `port`, `name` | saved to `hosts.json` |
    struct Inbound: Decodable {
        let t: String
        let d: String?
        let cols: Int?
        let rows: Int?
        let host: String?
        let session: String?
        let window: String?
        let pane: String?
        let name: String?
        let dir: String?
        /// The page showed `closeText` and the user said yes. Without it a window whose close
        /// `kills` is refused, so a page that skipped the question cannot end a shell by accident.
        let confirm: Bool?
        let destination: String?
        let port: Int?
    }

    /// Something the relay refused or could not do, for the page to show and forget.
    struct Notice: Encodable {
        var t = "notice"
        let text: String
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
            /// What ssh is waiting on, when the page can answer it.
            let prompt: Prompt?
            /// tmux's refusal of the last command, verbatim (§7). The id lets the page show each
            /// one once.
            let failure: Failure?
            let sessions: [Session]
        }

        struct Prompt: Encodable, Equatable {
            let text: String
            /// Typed into a password field, and never echoed back by anyone.
            let secret: Bool
        }

        struct Failure: Encodable, Equatable {
            let id: String
            let text: String
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
            /// `unlink` or `kill` (F4.9): whether closing it here ends what is running in it.
            let close: String
            /// The sentence a confirmation shows, from `ClosePolicy` so it reads as the Mac's does.
            let closeText: String
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
                    prompt: host.authenticationPrompt.map { Prompt(text: $0.text, secret: $0.answerIsSecret) },
                    failure: host.lastCommandFailure.map {
                        Failure(id: $0.id.uuidString, text: "\($0.action): \($0.message)")
                    },
                    sessions: host.browsableSessions.map { session in
                        Session(id: session.id, name: session.name, windows: session.windows.map { window in
                            let outcome = ClosePolicy.outcome(
                                in: hosts, hostId: host.id, windowId: window.id, closingIn: session.id
                            )
                            return Window(
                                id: window.id, label: window.displayLabel, activity: window.hasActivity,
                                close: outcome == .kills ? "kill" : "unlink",
                                closeText: ClosePolicy.description(of: outcome, windowName: window.displayLabel),
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
