pressing down the option key while clicking on kill buttons should show no confirmation dialog (maybe change icon when pressing down the option key)

localhost should be connected from start 

when all macos windows are closed, the tray icon should open a new macos window when clicking on a session or new session. Also, right now, not even pressing the option key it opens a new macos window.

add also a new window button to the context menu of the app on the macos dock

add number of sessions on collapsed host on left pane.

## Status

Done: all five.

**⌥ skips the confirmation** on the sidebar's session ✕ and window ✕ and on the tab bar's ✕, and the
glyph turns red while it is held so the modifier says what it will do *before* the click rather than
after it. Not a "don't ask again" — nothing is remembered and the next window asks again. The
behaviour reads the flags at click time and the icon reads them from a monitor, which has to be a
second monitor: the menu bar's existing one polls because a menu tracks events in a run loop where a
local monitor sees nothing, and a poll bounded by how long a menu stays open cannot be reused by a
window that is open for as long as the app runs.

**The tray with no windows open** was three separate dead ends, not one. `requestedWindow` is only
observed from inside a window, so with none open nobody claimed it — and the request stayed set, so
the next ⌘N inherited it and came up on somebody's old session. ⌥ made no difference because it
reached the same dead end one branch later. And plain **New Session** never even queued a reveal when
there was no window to reveal in, so tmux got the session and nothing was shown. The model now owns
an `OpenWindowAction` handed to it by whichever view can read one, and uses it only when there is
genuinely nothing on screen.

**Verified live:** localhost auto-connect, by quitting (no `tmux list-clients` output), relaunching,
and finding a control-mode client attached with nothing clicked. The rest is covered by the four new
`AppModelTests` — the ⌥ skip at both levels, the request performed with nothing open and *not*
performed with something open, and New Session bringing its own window. The Dock menu is not
verifiable from a test or from the CLI; it is one item calling the same path as ⌘N.
