import Foundation

/// Building blocks for the command plane of a control-mode channel.
///
/// Every string that reaches tmux or a remote shell goes through the quoting helpers here.
/// A session or window name containing a space, a quote, or a `$` is ordinary, and unquoted
/// interpolation turns those into command injection or, more often, a silent no-op.
public enum TmuxCommand {
    /// Single-quotes a value for tmux's command parser (which follows sh rules for quoting).
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Encodes a value as a tmux **double-quoted** literal, for the one case that needs it: content
    /// that legitimately contains newlines.
    ///
    /// `quote` is the right default everywhere else and cannot do this. Control-mode commands are
    /// newline-framed and a single-quoted tmux string has no escape for a line break, so the command
    /// ends at the first one and the remainder of the value arrives as a *new command* — which is how a
    /// multi-line paste wedged the channel. Double quotes have `\n`, at the price of tmux expanding
    /// `$VAR` inside them, so every `$` is escaped as well.
    ///
    /// Verified against tmux 3.7b's own lexer over a control-mode channel. A shell cannot answer this
    /// question: argv arrives pre-split there, so no tmux quoting is parsed at all.
    /// - `\` → `\\`, `"` → `\"`, `$` → `\$`, `#` → `\#`, LF → `\n`, CR → `\r`.
    /// - Every other byte, control characters included, survives verbatim — checked for ESC, 0x01, and
    ///   0x7f. `\xHH` is *not* a tmux escape (it yields a literal `x`), so nothing relies on it.
    /// - NUL is dropped: tmux reads commands as C strings, so it would truncate the value silently.
    public static func doubleQuoted(_ value: String) -> String {
        var result = "\""
        for character in value {
            switch character {
            case "\\": result += #"\\"#
            case "\"": result += #"\""#
            // tmux expands `$VAR` and `${VAR}` inside double quotes.
            case "$": result += #"\$"#
            // `#{…}` is not expanded in this position today, but escaping it costs nothing and keeps a
            // pasted format string from becoming a format string.
            // Not a raw string: `\#` is the escape introducer inside `#"…"#`.
            case "#": result += "\\#"
            case "\n": result += #"\n"#
            case "\r": result += #"\r"#
            // A single grapheme cluster in Swift, and distinct from either half.
            case "\r\n": result += #"\r\n"#
            case "\0": continue
            default: result.append(character)
            }
        }
        return result + "\""
    }

    /// Splits text so that no single command line grows to the size of the clipboard.
    ///
    /// Splits between `Character`s, never inside one: a chunk boundary through a multi-byte scalar or a
    /// grapheme cluster would put mojibake in the middle of the paste. The budget is measured against
    /// the *escaped* size, using the worst case of two bytes per source byte.
    public static func chunk(_ text: String, maxEscapedBytes: Int = 4096) -> [String] {
        precondition(maxEscapedBytes > 8, "a chunk must be able to hold at least one escaped character")
        var chunks: [String] = []
        var current = ""
        var budget = 0

        for character in text {
            let worstCase = String(character).utf8.count * 2
            if budget + worstCase > maxEscapedBytes, !current.isEmpty {
                chunks.append(current)
                current = ""
                budget = 0
            }
            current.append(character)
            budget += worstCase
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Collapses anything that would end a control-mode command early.
    ///
    /// Commands are newline-delimited on the channel, so a value containing a line break ends the
    /// command before tmux's parser ever reaches the closing quote — the remainder of the value then
    /// arrives as a *new* command. `quote` cannot defend against that, because the framing is
    /// resolved a layer below the parser. Names come from text fields, and text fields accept pasted
    /// multi-line text, so every name is put through this first.
    public static func singleLine(_ value: String) -> String {
        let collapsed = String(value.map { character in
            character.unicodeScalars.contains { $0.properties.generalCategory == .control } ? " " : character
        })
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    /// Field separator for `-F` format strings. Variable-length fields (names, paths, layouts)
    /// always go last so the parser can split with a bounded `maxSplits` and keep the remainder.
    public static let fieldSeparator = "|"

    public static let sessionsFormat = "#{session_id}|#{session_attached}|#{session_name}"
    /// `automatic-rename` is how tmux says whether a window's name is its own invention or the user's:
    /// it is `1` while tmux is naming the window after the running command, and renaming a window
    /// explicitly turns it `0`. There is no `#{window_...}` variable for this — the option name itself
    /// is the format — and it is the only way to tell a deliberate name from a coincidental one.
    public static let windowsFormat =
        "#{session_id}|#{window_id}|#{window_active}|#{window_activity_flag}|#{automatic-rename}|#{window_layout}|#{window_name}"
    public static let panesFormat =
        "#{window_id}|#{pane_id}|#{pane_active}|#{pane_width}|#{pane_height}|#{pane_current_command}|#{pane_current_path}"
    public static let clientsFormat = "#{client_name}|#{client_session}|#{client_flags}"

    // MARK: - Flow control (P6.5)

    /// Asks tmux to pause a pane once its output is `seconds` behind on this channel.
    ///
    /// This is the far half of backpressure: it bounds what a fast producer can queue up *inside tmux*
    /// for a client on a slow link, which nothing on our side of the pty can otherwise limit. Setting
    /// it also switches the server from `%output` to `%extended-output` — same payload with an age
    /// field, which `ControlCodec` already handles.
    ///
    /// The flag is per client, not per session, so it needs re-applying on each attach and nothing has
    /// to be restored on the way out.
    public static func pauseAfterFlag(seconds: Int) -> String {
        "refresh-client -f pause-after=\(max(seconds, 1))"
    }

    /// Pauses or resumes one pane on this channel.
    ///
    /// The near half of backpressure: a viewer that cannot keep up is a local condition tmux has no
    /// way to observe, so we pause the pane ourselves rather than letting the queue between the two
    /// grow without bound. tmux keeps running the pane and discards what we did not take, which is why
    /// resuming has to be followed by a repaint.
    public static func flowControl(paneId: String, paused: Bool) -> String {
        "refresh-client -A \(quote("\(paneId):\(paused ? "pause" : "continue")"))"
    }

    // MARK: - Transport invocation

    /// What a channel should do about a session when it opens.
    ///
    /// A three-way choice rather than a flag, because the third case is the one that keeps a
    /// deliberately ended session from coming back: after tmux says `%exit`, the session that was
    /// named is *gone*, and asking for it by name either fails or — with `new-session -A` — quietly
    /// recreates the thing the user just closed.
    public enum AttachMode: Equatable, Sendable {
        /// `new-session -A -s <name>`: attach if it exists, create it otherwise. The launcher's case.
        case createOrAttach(sessionName: String)
        /// `attach-session -t <name>`: that session or nothing.
        case attach(sessionName: String)
        /// `attach-session`: whatever the server still has, most recently used first. Fails outright
        /// when the server is gone, which is exactly the signal that there is nothing left to show.
        case attachAny

        /// The tmux sub-command and its arguments, already quoted for a remote shell.
        var arguments: [String] {
            switch self {
            case .createOrAttach(let name): return ["new-session", "-A", "-s", name]
            case .attach(let name): return ["attach-session", "-t", name]
            case .attachAny: return ["attach-session"]
            }
        }
    }

    /// Local channel: `tmux -CC -2 -u new-session -A -s <name>`.
    ///
    /// `-2` forces 256-colour and `-u` UTF-8 (T5.1/T5.2); `new-session -A` attaches if the session
    /// exists and creates it otherwise, which is the behaviour the launcher wants.
    public static func localArguments(mode: AttachMode) -> [String] {
        ["-CC", "-2", "-u"] + mode.arguments
    }

    /// The single shell command string handed to the remote login shell.
    ///
    /// This must be **one** argv element. `ssh host -- sh -c "a b c"` does not do what it looks
    /// like: ssh joins everything after the destination with spaces and hands the result to the
    /// remote login shell, so `sh -c` receives only the next word and the rest becomes positional
    /// arguments — the tmux invocation never runs at all.
    public static func remoteCommand(mode: AttachMode) -> String {
        // Homebrew and ~/.local are common tmux locations that a non-interactive shell misses.
        let path = "PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin\""
        // The sub-command and its flags are ours; only the session name is user data, and it is the
        // one thing quoted. Spelling that out per case rather than filtering the argument list keeps
        // the rule visible — a name that happens to look like a flag must still be a name.
        let tmuxArgs: String
        switch mode {
        case .createOrAttach(let name): tmuxArgs = "new-session -A -s \(quote(name))"
        case .attach(let name): tmuxArgs = "attach-session -t \(quote(name))"
        case .attachAny: tmuxArgs = "attach-session"
        }
        // `exec` so the shell does not linger between us and tmux, and `command -v` so a missing
        // remote tmux produces a clear message on stderr instead of a generic 127.
        return """
        \(path); export PATH; \
        command -v tmux >/dev/null 2>&1 || { echo "tetmux: tmux not found on remote host" >&2; exit 127; }; \
        exec tmux -CC -2 -u \(tmuxArgs)
        """
    }

    /// Standard ssh invocation from §2.3. Never weakens host-key checking.
    ///
    /// `forwards` become `-L`/`-R`/`-D` arguments. `ExitOnForwardFailure` is deliberately left at
    /// ssh's default of `no`: a local port that happens to be taken would otherwise kill the whole
    /// session, and the session is what the user came for. ssh's complaint about the forward lands in
    /// the pre-handshake transcript instead.
    ///
    /// `expectsPasswordPrompt` caps ssh at a single password attempt. Answering the same rejected
    /// password repeatedly is how accounts get locked out, and F4.14 already refuses to retry an
    /// authentication failure at the connection level — this is the same rule one layer down.
    public static func sshArguments(
        destination: String,
        port: Int?,
        controlPath: String,
        remoteCommand: String,
        forwards: [PortForward] = [],
        expectsPasswordPrompt: Bool = false,
        extraArguments: [String] = [],
        forwardsX11: Bool = false
    ) -> [String] {
        // The user's own options come *first*, and that placement is the whole point of them. ssh
        // resolves each parameter to the first value it obtains, so an `-o` after ours would be
        // silently discarded — a host needing `ServerAliveInterval=60` could not say so. Ahead of
        // ours they win, which is what an escape hatch is for.
        var args = extraArguments
        if forwardsX11 {
            args += ["-X"]
        }
        args += [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=300",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ]
        if expectsPasswordPrompt {
            args += ["-o", "NumberOfPasswordPrompts=1"]
        }
        // Without a tty tmux refuses to attach; -tt forces one even though our stdin is a pipe
        // from tmux's point of view.
        args += ["-tt"]
        args += forwardArguments(forwards)
        if let port, port != 22 {
            args += ["-p", "\(port)"]
        }
        args += [destination, "--", remoteCommand]
        return args
    }

    /// Flag/value pairs for a host's forwards, skipping any that are incomplete.
    ///
    /// Each specification is its own argv element, so nothing here needs shell quoting — but a value
    /// containing whitespace would still confuse ssh's own parser, which is what `PortForward.isValid`
    /// rejects.
    ///
    /// With `ControlMaster=auto` a second connection to an already-mastered host asks the existing
    /// master to set these up rather than opening its own transport. That works, and it also means a
    /// forward can fail because the *previous* connection already bound the port.
    public static func forwardArguments(_ forwards: [PortForward]) -> [String] {
        forwards.filter(\.isValid).flatMap { [$0.kind.flag, $0.specification] }
    }

    /// Splits a typed-in option string into argv elements the way a shell would — and then hands
    /// them to `execve`, not to a shell.
    ///
    /// The distinction matters. The user types these into a text field, so they type shell syntax:
    /// `-o "ProxyCommand=nc %h %p"` has to arrive as two elements with the quotes gone, or ssh sees
    /// a stray `"nc` and exits. But splitting is *all* that happens here — no globbing, no `$VAR`,
    /// no command substitution — so a value cannot become a command however it is written. That is
    /// the difference between this and `customCommand`, which really is handed to `/bin/sh`.
    ///
    /// Quotes group, a backslash escapes the next character, and an unterminated quote simply runs
    /// to the end rather than being an error: the field is edited a keystroke at a time, and half a
    /// quoted value is a normal thing to be holding.
    public static func splitArguments(_ text: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var started = false
        var quote: Character?
        var iterator = text.makeIterator()

        while let character = iterator.next() {
            if character == "\\", let escaped = iterator.next() {
                current.append(escaped)
                started = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                // An empty quoted string is still an argument: `-o ""` is two of them.
                started = true
            } else if character.isWhitespace {
                if started { arguments.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if started { arguments.append(current) }
        return arguments
    }
}
