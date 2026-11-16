import Foundation

/// The relay's WebSocket protocol, as it stands at step 2: one pane, its bytes, its size, and input.
///
/// Pane output travels as **binary** frames, unmodified — the browser's emulator decodes UTF-8 and
/// escape sequences itself, exactly as SwiftTerm does in the app. Everything else is a **text**
/// frame holding one JSON object whose `t` names it. Binary for the bytes because they are the
/// volume, and because a pane's output is not guaranteed to be valid UTF-8 at a chunk boundary.
enum Wire {
    /// Browser → relay.
    struct Inbound: Decodable {
        /// `in` (keystrokes, as xterm.js reports them), `paste`, or `resize`.
        let t: String
        let d: String?
        let cols: Int?
        let rows: Int?
    }

    /// A new pane stream starts. The browser resets its emulator on this, so that the repaint which
    /// follows lands on a clean screen rather than on the last pane's scrollback.
    struct Pane: Encodable {
        var t = "pane"
        let host: String
        let session: String
        let window: String
        let pane: String
        let label: String
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

    /// The host's connection state, and anything ssh is waiting on that the relay cannot answer.
    struct Status: Encodable {
        var t = "status"
        let state: String
        let text: String?
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        // An encoding failure here is a programming error in the structs above, not a runtime state.
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8), as: UTF8.self)
    }
}
