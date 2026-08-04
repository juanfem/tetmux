import Foundation

/// Identifiers are carried **with their tmux sigil** (`@3`, `%7`, `$1`) so they can be
/// interpolated straight into commands. Stripping and re-adding the sigil at each layer
/// was a recurring source of mismatched lookups.
public enum ControlEvent: Equatable, Sendable {
    /// Command execution started: `%begin <timestamp> <cmdNum> <flags>`
    case begin(timestamp: Int64, commandNumber: Int, flags: String)

    /// A line of a command's response, between `%begin` and `%end`/`%error`.
    ///
    /// `bytes` is the line exactly as tmux sent it. Response bodies are *not* octal-escaped,
    /// so `capture-pane -e` output arrives as raw escape sequences that must survive
    /// verbatim; `line` is a lossy convenience view for the many textual commands.
    case commandResultLine(commandNumber: Int, line: String, bytes: Data)

    /// Command completed successfully: `%end <timestamp> <cmdNum> <flags>`
    case end(timestamp: Int64, commandNumber: Int, flags: String)

    /// Command failed: `%error <timestamp> <cmdNum> <flags>`
    case error(timestamp: Int64, commandNumber: Int, flags: String)

    /// Pane output: `%output %<pane> <octal-escaped bytes>`
    case output(paneId: String, data: Data)

    /// Pane output with an age, tmux 3.2+: `%extended-output %<pane> <age> : <octal-escaped bytes>`
    case extendedOutput(paneId: String, age: Int, data: Data)

    /// `%layout-change @<window> <layout> [<visible-layout> <flags>]`
    ///
    /// tmux ≥ 2.5 sends three fields. Treating all three as one layout string makes the
    /// layout unparseable, which leaves a window with no pane tree at all.
    case layoutChange(windowId: String, layoutString: String, visibleLayout: String?, flags: String?)

    case windowAdd(windowId: String)
    case windowClose(windowId: String)
    case windowRenamed(windowId: String, name: String)
    case windowPaneChanged(windowId: String, paneId: String)

    case sessionChanged(sessionId: String, name: String)
    /// `%session-renamed $<id> <name>` on tmux ≥ 2.4; older builds send the name only.
    case sessionRenamed(sessionId: String?, name: String)
    case sessionWindowChanged(sessionId: String, windowId: String)
    case sessionsChanged

    case unlinkedWindowAdd(windowId: String)
    case unlinkedWindowClose(windowId: String)
    case unlinkedWindowRenamed(windowId: String, name: String)

    case clientDetached(client: String)
    case clientSessionChanged(client: String, sessionId: String, name: String)

    /// Flow control, tmux ≥ 3.2: output for a pane is suspended / resumed.
    case pause(paneId: String)
    case continuePane(paneId: String)

    /// `%pane-mode-changed %<pane>` — the pane entered or left copy/view mode.
    ///
    /// Modes are a per-client screen overlay and control mode is not streamed one, so a pane that
    /// another client puts into copy mode simply stops changing here. Without this the pane looks
    /// frozen and nothing ever repaints it; with it there is at least a repaint to ask for.
    case paneModeChanged(paneId: String)

    /// `%config-error <error>` — a syntax error in the user's `tmux.conf`, reported here and nowhere
    /// else. Ignoring it left the user with bindings and options that silently did not work.
    case configError(message: String)

    /// `%message <message>` — tmux's own message line, as other clients would see it.
    case message(text: String)

    /// `%exit [reason]` — the server is going away.
    case exit(reason: String?)

    /// Any other `%`-prefixed notification. Logged, never fatal: tmux adds these between versions.
    case unknownNotification(line: String)
}
