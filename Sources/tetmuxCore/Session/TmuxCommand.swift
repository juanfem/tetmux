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

    /// Field separator for `-F` format strings. Variable-length fields (names, paths, layouts)
    /// always go last so the parser can split with a bounded `maxSplits` and keep the remainder.
    public static let fieldSeparator = "|"

    public static let sessionsFormat = "#{session_id}|#{session_attached}|#{session_name}"
    public static let windowsFormat =
        "#{session_id}|#{window_id}|#{window_active}|#{window_activity_flag}|#{window_layout}|#{window_name}"
    public static let panesFormat =
        "#{window_id}|#{pane_id}|#{pane_active}|#{pane_width}|#{pane_height}|#{pane_current_command}|#{pane_current_path}"
    public static let clientsFormat = "#{client_name}|#{client_session}|#{client_flags}"

    // MARK: - Transport invocation

    /// Local channel: `tmux -CC -2 -u new-session -A -s <name>`.
    ///
    /// `-2` forces 256-colour and `-u` UTF-8 (T5.1/T5.2); `new-session -A` attaches if the session
    /// exists and creates it otherwise, which is the behaviour the launcher wants.
    public static func localArguments(sessionName: String, attachOnly: Bool) -> [String] {
        var args = ["-CC", "-2", "-u"]
        if attachOnly {
            args += ["attach-session", "-t", sessionName]
        } else {
            args += ["new-session", "-A", "-s", sessionName]
        }
        return args
    }

    /// The single shell command string handed to the remote login shell.
    ///
    /// This must be **one** argv element. `ssh host -- sh -c "a b c"` does not do what it looks
    /// like: ssh joins everything after the destination with spaces and hands the result to the
    /// remote login shell, so `sh -c` receives only the next word and the rest becomes positional
    /// arguments — the tmux invocation never runs at all.
    public static func remoteCommand(sessionName: String, attachOnly: Bool) -> String {
        // Homebrew and ~/.local are common tmux locations that a non-interactive shell misses.
        let path = "PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin\""
        let quotedName = quote(sessionName)
        let tmuxArgs = attachOnly
            ? "attach-session -t \(quotedName)"
            : "new-session -A -s \(quotedName)"
        // `exec` so the shell does not linger between us and tmux, and `command -v` so a missing
        // remote tmux produces a clear message on stderr instead of a generic 127.
        return """
        \(path); export PATH; \
        command -v tmux >/dev/null 2>&1 || { echo "tetmux: tmux not found on remote host" >&2; exit 127; }; \
        exec tmux -CC -2 -u \(tmuxArgs)
        """
    }

    /// Standard ssh invocation from §2.3. Never weakens host-key checking.
    public static func sshArguments(
        destination: String,
        port: Int?,
        controlPath: String,
        remoteCommand: String
    ) -> [String] {
        var args = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=300",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            // Without a tty tmux refuses to attach; -tt forces one even though our stdin is a pipe
            // from tmux's point of view.
            "-tt",
        ]
        if let port, port != 22 {
            args += ["-p", "\(port)"]
        }
        args += [destination, "--", remoteCommand]
        return args
    }
}
