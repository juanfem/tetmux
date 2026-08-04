1. Ctrl+D on a terminal reopens a new window in the current session if that is the last one. I think it should close the session. Also the kill session button on the context menu of a session does not always kill the session, but it creates a new window on the session.
1. Move the add [+] button to appear always on the right of the last window name to show that it will open a new tab. Also move the close [x] button next to the name of the tabs.
1. The add button for windows in the current session should go on the left pane as well. Also a button to add a new session on a host and buttons to close windows and sessions.
1. I want to be able to open multiple instances of the application.
1. double click on a session on the left pane opens the first window of the session (if no window from that session is currently open) and collapses the left pane.
1. the tmux session should appear on the top, where it currently says "tetmux"
1. the app needs an icon. I put it on the top path, move it where it corresponds.
1. when a tmux window is split, sometimes the separators flicker and redraws continuosly
1. when clicking on a session on the system tray icon, if more than one application window is open, bring forward the application that is currently attached to that session, if any, otherwise the one that was last used.
1. on the system tray icon, add options to create a new session on a host. Also, holding the option key should open a new application window instead of the currently open one
1. on the system menu, clicking on New Window opens a new tmux window on the current session, but I think an user would expect a new application window instead.
1. the "Open in new window" option on the context menu opens a different type of window which has a button to convert to the normal application window. I want to change that to opening a normal applicaiton window, but with the left pane collapsed. Also add a button on the toolbar that has the split buttons to open the session in a new window.
1. when more than one app window is open, clicking on add host opens a dialog per app instance (bug). Same for new session.
1. create session with a default name using an index (e.g. tetmux_1, tetmux_2,...) then user renames when needed.
1. when more than one window is open, clicking on the left panel changes view on all instance (e.g., changing to a different window).

## Status

Done: all of it, including the split-separator flicker.

**Separator flicker — fixed.** Not the geometry-owner loop it looked like. Each pane reported a cell
size of its own frame width divided by its own cell count, which is circular: frame ← layout ← the
size we asked for ← the cell size. One pane is stable and nobody notices; three panes disagree
(8.31, 8.39, 8.46 for the `work` window), whichever reported last won, and the requested width
oscillated 111 ↔ 112 columns forever. The cell size now comes from the font, which depends on nothing
else. Verified against the real `work` session: 30/30 layout samples identical, where before it
alternated every frame.

**Verified on screen.** The sidebar redesign, the stable three-pane split, and double-click focus mode
were all confirmed against the running app. Not exercised live: the multi-host cases, which need two
hosts connected at once — those are covered by unit tests instead.

## Second round

Done: window double-click focus mode; expand/collapse all at both levels; explicit window names
beating pane commands; live label refresh; tabs and sidebar sharing one label; ⌥-click opening a real
window; new sessions arriving expanded; draggable pane separators.

**Draggable separators** took three attempts, each failing in a way that looked like it worked. A
SwiftUI `DragGesture` never receives events over SwiftTerm's `NSView`, so the handle is an `NSView`.
Nesting each handle in its own container put it underneath the sibling subtree's pane surfaces, so
only the outermost split dragged — they all live in one overlay now. And the `ForEach` id has to be
the seam's place in the tree: keyed on the target pane, a left/right seam and the top/bottom seam in
its leading column collide and one disappears; keyed on position, the id changes the moment a drag
resizes anything and the view is rebuilt mid-gesture, so a 100px drag moved the pane exactly one cell.
Verified on both axes: 58 → 46 columns and 25 → 32 rows.

**Still not reported by tmux:** a background pane changing its command while nobody switches panes or
triggers a rename. There is no notification for it, so that label waits for the next refresh.

## Third round

Done and verified live: "open in new window" carrying the tmux window that is on screen; new
sessions and new windows being selected and shown as soon as tmux confirms them (sidebar `+`, tab-bar
`+`, host `+`, menu bar); focusing a window attaching it automatically; the not-attached banner kept
but stripped of its button.

Auto-attach was checked by alternating focus between two windows on two sessions — the attached
session followed every time, in both directions.
