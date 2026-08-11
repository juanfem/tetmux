# Invariants that are easy to violate

Part of the project guidance; `CLAUDE.md` holds the orientation and the index. Every rule here,
when broken, fails *silently* — no crash, no log line, just wrong behaviour far from its cause —
and each has a regression test. Entries lead with the rule; what follows is the failure that taught
it and the details that keep the fix standing.

## Command correlation and framing

**Identifiers carry their tmux sigil.** `@3`, `%7`, `$1` — everywhere, from codec to view.
Stripping and re-adding sigils per layer was a recurring source of lookups that silently matched
nothing.

**Responses are matched to commands by order, because tmux command numbers cannot be predicted.**
Command numbers are server-wide and start at an arbitrary value, so `SessionService` keeps a FIFO
of pending commands and relies on responses being strictly ordered. tmux also emits one
`%begin`/`%end` block of its own on attach, before we can write anything; commands therefore queue
in an outbox until that handshake completes. Writing earlier misaligns the queue by one for the
life of the channel.

The number cannot schedule a match, but it can detect a bad one, and does: a `%begin` whose number
fails to increase, a `%begin` with nothing pending after the handshake, and a terminator closing a
block it did not open are each logged as a desync. Detecting is not recovering — there is still no
recovery — so everything below that can cause a misalignment treats it as fatal rather than as an
error to report.

**Not every block on the wire answers one of our commands.** Two kinds arrive unsolicited: tmux's
own block on attach, and one for every command a keystroke dispatches through a pane's mode table.
Verified on 3.7b: with a pane in copy mode, `send-keys -t %p Up` produces the response to
`send-keys` (flags `1`) *and then* an unsolicited block (flags `0`) for the `cursor-up` the key was
bound to; three `Up`s produce three of them. Taking one of those off the FIFO hands the next real
answer to the wrong command for the life of the channel — and no copy-mode feature of ours is
needed to trigger it: a `prefix [` typed into a pane is enough, which is why panes in copy mode had
a history of going strange. `ControlCodec.blockAnswersOurCommand` reads bit 0 of the flags field
rather than comparing it for equality, because it is a bitfield tmux may add to. An *absent* flags
field means a version this was never verified against (every one in the R3.6 matrix emits it) and
is read as ours, since the alternative is a block that answers no command at all.

**Framing outranks dispatch.** Inside a `%begin` block every line is response content — including a
line that starts with `%` — and only a `%end`/`%error` carrying the matching number may close the
block. Parsing `%`-prefixed lines as notifications first cost real data and admitted forgery:
`capture-pane` replays scrollback as result lines, so a zsh or tcsh `%` prompt vanished from every
repaint — and captured text containing `%exit` set `serverEnded`, after which a dropped link looked
like an orderly session end and nothing reconnected. `%output` for a pane could be injected the
same way.

**A partial PTY write is a dead channel, not a failed command.** A fragment with no newline sits in
front of tmux's parser, and the next command concatenates onto it: one `%begin` block answering two
commands, and the FIFO is misaligned for good. `PtyTransport` therefore distinguishes `.partial`
from `.nothingWritten`; `send` unqueues only for the latter, and `.partial` tears the channel down.
A large paste over a congested link is exactly the path that hits this.

**The reader thread owns the master fd and is the only thing that closes it.** `terminate()` used
to close the fd while the reader thread sat in a 1000 ms `poll` holding that number by value. A
fast reconnect could then be handed the same fd number, and the old, already-finished stream
consumed its bytes — a hole where the `%begin` should have been, or a handshake that never arrived
and a host stuck at "Connecting…". The fd outliving `terminate` by up to one poll interval is the
accepted cost.

## Topology and state broadcasts

**`list-windows` order is the window order, and the model has to be re-sorted into it.**
`applyWindows` updates known windows in place and appends new ones. That keeps identity stable but
says nothing about position: without an explicit sort, each session kept whatever order it first
learned its windows in, and a `move-window` or `swap-window` from anywhere — our own reorder,
another client, `movew` typed at a prompt — changed nothing visible.

Tab reordering itself is `move-window -b`/`-a` on tmux ≥ 3.2 and a run of adjacent `swap-window`s
below it (3.0 answers `illegal option -- b`). Both address windows by `@id`, never by index: a
session's indices are arbitrary and often not contiguous, so a position in the strip is not an
index. The *source* of a move carries its session (`-s $2:@7`), because a window linked into
several sessions is reachable by id from any of them, and an unqualified `-s` leaves tmux to choose
which one it leaves.

**…and a reorder has to ask for the topology back, because no notification means "the order
changed".** `move-window` looks as though one does: it emits `%window-add @2` then
`%window-close @2` for the same window — tmux implements the move by unlinking and relinking — and
those schedule a refresh. That is an accident of the implementation, and the fallback does not
share it: `swap-window` emits `%session-window-changed` alone, which says only which window is now
*active*. So below tmux 3.2 a dragged tab reordered the windows on the server and the strip never
moved — the model kept the order it last read until something unrelated refreshed it. Both branches
now schedule the refresh themselves. Found by `Scripts/test-matrix.sh` on 3.0; it is invisible on a
machine with one modern tmux, where the accident holds.

**State broadcasts are for topology changes only.** `SessionService.ingest` diffs `HostState` and
broadcasts only when it actually changed. Broadcasting on `%output` rebuilds the SwiftUI tree for
every chunk of terminal output, tearing down the very terminal views the output is painting into.

**…and a value that changes on a timer must stay out of that diff — and must not be read above a
leaf view.** F4.29's round-trip reading is a field on `HostState`, so every probe answer counted as
a real state change: once per host per ten seconds, `AppModel.hosts` was reassigned, which
invalidates every view that reads it — the sidebar, the tab strip, and every pane. That was the
whole of P6.6's miss. On 12 panes it measured a mean of 0.45–0.71% of one core with spikes to 5.4%,
against 0.04% and nothing above 0.8% once fixed — and an arm that kept *sending* `display-message`
while suppressing only the write was flat, so the round trip costs nothing and the rebuild costs
all of it.

The fix has two halves, and both are load-bearing. `differsBeyondRoundTrip` keeps the value out of
the broadcast decision by normalising it onto the later value — one comparison of two whole states,
rather than an allowlist a new field would fall out of — and `roundTripStream` carries it
separately. The first attempt shipped only the first half: published narrowly but *read* in
`AppMain`'s window body, the same body that builds the pane tree, so the ten-second rebuild came
straight back behind a channel change that looked like a fix. SwiftUI invalidates the views whose
body reads a property, which is why `RoundTripIndicator` exists to be the only reader. Anything
else that comes to depend on a timer-driven value wants the same shape — and wants it verified by
measuring, because the cost is a tree rebuild and no unit test can see one.

## Geometry

**tmux owns geometry (§3.3).** Views measure themselves, ask, and then lay out whatever
`%layout-change` returns. Nothing resizes a surface before tmux confirms. Pane surfaces are snapped
to the cell size tmux reported; letting the emulator pick its own drifts by a cell and
desynchronises the grid.

**A pane's usable width is its frame width, which is why SwiftTerm's scroller is hidden.** The view
reserves 17pt for a scroller and derives its own column count from
`frame.width - reservedScrollerWidth`, overriding the `resize(cols:rows:)` it is handed — while
`requestSizes` measures the container and subtracts nothing. tmux therefore sized panes to more
columns than the emulator could draw, and every full-width program wrapped early (at 12pt SF Mono:
96 columns requested, 93 drawn). The scroller is *hidden* rather than its width subtracted in
`requestSizes`, deliberately: every pane reserves its own gutter, so the correction would depend on
how many panes are across the widest row — a property of the layout, which is tmux's answer to the
size we asked for. That is the same self-feeding measurement as the pane-derived cell size below.
Hidden, the arithmetic has one owner again.

**A tmux window's size has exactly one owner.** On tmux ≥ 2.9 each displayed window is sized
individually — `set-option window-size manual` plus `resize-window -t @id -x -y` — which is what
lets a torn-off macOS window size its window independently of the main one. A client has only one
size, so `refresh-client -C` cannot do this; and two views driving the same window fight, each
`%layout-change` prompting the other to ask for its own size back, forever. `windowSizeOwners`
grants the right to the focused view; the loser renders the grid tmux gave the owner. Below 2.9
there is no per-window sizing at all, and `window-size latest` + `refresh-client -C` remains the
only mechanism — without *something* there, an old or small client clamps every window toward
80×24 (F4.17).

`window-size` is a session option, so it is re-applied after `%session-changed` and put back with
`set-option -u` on a deliberate disconnect — and **that last command must be waited for, not merely
written**. `teardown` hangs the channel up with `SIGHUP`, so the tmux client must have read the
line out of the pty before the signal lands. Writing and terminating in the same breath is a race
an idle machine wins and a loaded one loses — it passed here six runs in a row and failed in CI on
a commit that had passed there minutes earlier — leaving `manual` set on the user's session for the
next plain `tmux attach` to find. `sendAndAwait` waits for tmux's own `%end`, with a timeout,
because a channel can accept a write and never answer, and a disconnect that hangs is worse than an
option left set. `detach-client` is waited for against the same race, for the same reason.

**A zoomed window renders the visible layout, and is a member of the full one.** tmux keeps
`window_layout` as the layout the window would have *unzoomed*; `window_visible_layout` is what is
on screen. Render the wrong one while a pane is zoomed and every surface is forced to its unzoomed
cell size while tmux emits output sized to the whole window — wrapped, truncated, and unrecoverable
without unzooming from elsewhere. So `TmuxWindow.renderTree` prefers the visible tree when
`isZoomed`, and views must use it rather than `layoutTree` (pane cycling included). Membership and
labels still come from the *full* layout, or a zoomed split window relabels itself as holding one
pane. Nothing tracks zoom locally — tmux announces it in the `%layout-change` flags — but a window
**already zoomed when tetmux attaches never sends a `%layout-change` at all**, which is why
`windowsFormat` has to carry `#{window_visible_layout}` and `#{window_flags}` too.

**A repaint for a second viewer must be addressed to it alone.** `capture-pane`'s payload starts
with `ESC[H ESC[2J ESC[3J` — it clears screen *and* scrollback. The same pane can be on screen in
two macOS windows, and the late joiner needs a repaint because control mode resends nothing for a
pane that is merely sitting there; broadcasting that repaint would wipe the history the other
window is holding. Hence `Kind.capturePane(paneId:target:)` and
`deliver(_:hostId:paneId:target:)`.

**The cell size comes from the font, never from a pane.** A pane can only report its own frame
divided by its own cell count, and that measurement is circular: the frame comes from the layout,
the layout comes from the size we asked tmux for, and that size came from the cell size. With one
pane the circle is stable and invisible. With a split window, each pane divides a *different* frame
by a *different* cell count, so they report different cell sizes — 8.31, 8.39 and 8.46 for one
three-pane window. Whichever reported last won, and the requested width oscillated between 111 and
112 columns forever: that was the separator flicker, `%layout-change` on every frame and panes
relaid out on every one. `TerminalTheme.cellSize(backingScaleFactor:)` mirrors SwiftTerm's
`computeFontDimensions` and depends on nothing but the font, which breaks the loop at its source.
`sizeChanged` from the emulator is deliberately ignored for the same reason — it fires when
SwiftTerm re-derives its grid from the frame we just gave it, so acting on it is reacting to our
own last action.

**…and the scale factor it snaps to is the *window's*, which is not `NSScreen.main`.** The mirror
is only a mirror if both sides resolve the same pixel density: `ceil(w × scale) / scale` moves the
cell by a whole point between 1× and 2× — 12pt SF Mono advances `W` by 7.2, which snaps to 8.0 at
1× and 7.5 at 2×. `NSScreen.main` is *not* this window's screen; it is the screen holding whichever
window has keyboard focus anywhere on the system, so with a 1× monitor beside a 2× built-in it
changes answer every time you click into another application on the other display, while the window
has not moved. SwiftTerm resolves its own `cellDimension` from `window?.backingScaleFactor` and
gets the real one, so the two halves of §3.3 came apart: measured on that desk, a 572pt pane on the
Retina display asked tmux for 71 columns while its grid drew 76 — five columns tmux never writes
into — and the reverse arrangement is the early-wrapping failure the scroller gutter used to cause.
`@Environment(\.displayScale)` follows the window; nothing else does. It also has to *re-ask* on a
change: a window dragged to another display keeps its size in points, and `requestSizes` hangs off
`proxy.size`, so without `onChange(of:)` the panes keep the old display's grid until something
unrelated resizes them.

**A drag on a window edge asks tmux nothing until it ends (R3.7).** §3.3 asks for a debounce *and*
for suppression during live resize; only the debounce existed, so dragging an edge was a
`refresh-client -C` every 100 ms, each answered with a `%layout-change`, each relaying out every
pane. Nothing corrupts — tmux stays authoritative and the last answer wins — which is why it went
unnoticed as anything but a heavy drag. `LiveResizeGate` holds the ask instead, and the drag ends
with one request at the size the user let go of. Two details:

- The held request is **keyed by tmux window**. Every tab is built and measuring itself (unselected
  ones are hidden with `.opacity(0)`, not omitted), so one held closure would let the last tab laid
  out overwrite the rest — silently leaving every other tab on its old grid.
- The gate is **per macOS window**, observing one `NSWindow`: another window's panes are not the
  ones being dragged. It is unsubscribed from `onDisappear`, not from `deinit` — a `deinit` is
  nonisolated and cannot touch the state, and `WindowState.nsWindow` is weak, so a reference nilled
  by ARC never runs `didSet`.

**A resize handle has to be an `NSView`, and its identity must not move.** A pane surface is
SwiftTerm's `TerminalView`, a real `NSView` that tracks the mouse for selection; a SwiftUI
`DragGesture` layered over it in a `ZStack` never sees an event, whatever the z-order says. Hence
`PaneDivider` being an `NSViewRepresentable` with `mouseDown`/`mouseDragged` and a
`resetCursorRects` resize cursor. Two further traps, both of which produce a handle that *looks*
right and silently does almost nothing:

- Every divider is collected into **one overlay above the whole tree**, never nested in the
  container it belongs to. Nested, a handle sits underneath the pane surfaces of its sibling
  subtree — the outer split dragged and the inner one did not.
- The `ForEach` id must be the seam's **place in the tree** — never its position, and never the
  target pane. A left/right seam and the top/bottom seam inside its leading column resolve to the
  same first pane, so keying on the pane renders one seam where there should be two; and keying on
  position changes the id the instant a drag resizes anything, tearing the view down mid-gesture,
  so the pane moves exactly one cell however far the pointer travels.

The drag baseline is captured at `mouseDown` for the same reason: the layout moves underneath as
tmux answers, and re-reading it each frame measures from a moving origin.

## Output and flow control

**The byte handoff is batched per display frame — except the first chunk after a quiet moment
(P6.4).** tmux emits ~22 000 `%output` chunks a second for a busy pane — 219 per frame at 100 Hz —
and `Coordinator.hand` collapses them to one `feed` per frame behind an `NSView.displayLink`. Three
things about it:

- **The edge is the design.** A chunk arriving into an empty buffer more than a frame after the
  last handoff is fed immediately, so an echoed keystroke never waits out a window it has nothing
  to share — the same fix the keystroke coalescer needed, and the reason P6.1 measured 11.51 ms p95
  before and 11.37 after. Order is preserved by the `isEmpty` half of that condition: once anything
  is buffered, everything buffers, so nothing overtakes what is waiting.
- The link is **started on demand and stopped after 12 idle frames**, because a permanent per-frame
  callback in each of twenty panes is exactly the always-on timer P6.6 is about.
- Bytes are acknowledged where they are **fed**, not where they arrive, or P6.5's accounting would
  report a viewer as keeping up while a frame's worth sat unhanded — at 34 MB/s that is more than
  the high-water mark.

**It bought no CPU** (108.2% of one core before, 106.9% after), and nobody should later think it
did: SwiftTerm's per-byte work costs the same however few calls deliver the bytes. It is here
because the requirement is met by it, cheaply — and the feed rate was *counted* rather than
assumed, because a change that silently did nothing would have measured identically.

**Pane output is bounded in bytes, and the viewer is what reports progress (P6.5).** A pane
produces output whether or not anyone is painting it — `yes` is the one-word reproducer — and the
producer side of an `AsyncStream` cannot observe whether its consumer is keeping up. So the surface
acknowledges what it has fed (batched at 16 KiB; an actor hop per chunk costs more than the
accounting is worth), `SessionService` tracks undelivered bytes per subscriber, and the *slowest*
viewer of a pane decides: above 1 MiB it sends `refresh-client -A '%p:pause'`, below 256 KiB it
resumes. The gap between the two thresholds is deliberate — a single threshold would pause and
resume on alternate chunks, and each resume costs a full `capture-pane`.

Three things here are easy to get wrong:

- **The byte ceiling cannot be delegated to the stream's buffering policy**, which counts elements.
  `%output` chunk sizes vary by orders of magnitude with what the pane is doing, so a buffer deep
  enough to hold a megabyte of `cat` is also one a chatty pane fills long before the high-water
  mark trips — and then the pause that is supposed to be the mechanism never fires at all.
- **A dropped chunk must come back off the books.** It will never be fed and so never acknowledged;
  counting it inflates `outstanding` permanently and eventually wedges the pane paused with nothing
  left to drain.
- **A pane tmux paused on its own** (`pause-after`, which also switches the server to
  `%extended-output`) **is ours to resume** — nothing else will, and a pane left paused never moves
  again. It needs its own hold-down rather than the viewer's watermark: resuming it as soon as the
  local counter drains turns tmux's `pause-after` into a pause/resume cycle with a full repaint
  each time.

Anything lost is repaired by a repaint, never handed to the emulator as a hole in the byte stream.
All of it needs tmux 3.2; below that, the byte ceiling is the whole mechanism.

## SwiftUI identity, focus, and input

**Pane surfaces need explicit `.id(paneId)`.** The layout tree is rendered through `AnyView`, which
erases structural identity, so without an explicit id SwiftUI rebuilds every `NSView` on each
update and discards the terminal's contents.

**…and the id is not enough on its own: every pane is a row of *one* flat `ForEach`, positioned by
frame and offset — never nested one view per split.** SwiftUI identity is structural: a view keyed
`%3` inside a container of two children is a *different view* from one keyed `%3` at the top of the
tree. So the obvious rendering — a view per layout node — rebuilt the *surviving* panes' `NSView`s
on every split and every close, `.id` and all. The cost is invisible where it happens: the new view
starts with an empty grid, so the pane's scrollback goes, and the repaint it asks for races
whatever the program is drawing at that instant. Closing a split left a full-screen program (Claude
Code was the report) drawn at the old width until the macOS window was resized — tmux had resized
the pane and sent `SIGWINCH`, the program had redrawn, and the redraw went into a view being torn
down; the survivor kept the grid it had at half the width. Rendered flat, a layout change moves
frames and nothing else. `TerminalContainerView.geometry` walks the tree once for both the pane
placements and the divider specs, because those two have to agree to the point.
`PaneIdentityTests` drives an `NSHostingView` through a split and a close and asserts the same
`TerminalView` object comes out — the only way to see this, since nothing about the arithmetic was
ever wrong.

**Every tmux window of the session is built; unselected ones are hidden with `.opacity(0)`, never
omitted with `if`.** Two separate failures forced this, one visible and one not. Building only the
selected window tore down its `TerminalView`s on each tab switch, and with them the whole local
scrollback — the return trip replays `capture-pane`, which begins `ESC[H ESC[2J ESC[3J` and is
capped at the capture budget, so "scroll up to see what that build printed" worked right up until
you looked at another tab. And a `ZStack` hands every child the same frame, so a background tab
keeps measuring the size it would really have and keeps asking tmux for that grid; dropped from the
tree, it would resize its tmux window to nothing and reflow everything running in it.

**…and everything that follows focus has to be keyed on selection by hand.** A hidden tab's pane
surfaces are real `NSView`s in the hierarchy, and a transparent view can still be the window's
first responder. `opacity`, `allowsHitTesting` and `accessibilityHidden` were keyed on the selected
tab from the start; **first responder was not** — so a keyboard tab switch drew the new tab while
the old one kept the keyboard, and typing went into a pane nobody could see, with nothing on screen
saying so. Two halves fix it and both are needed: `TerminalContainerView` takes an `isSelectedTab`
and refuses focus without it, and `WindowState.selectedWindowId` clears `focusedPaneId` on a
change, since that id named a pane in the tab being left and no pane in the new one would ever
match it. Anything else that resolves "which pane is live" wants the same treatment.

**Not everything leaving the emulator is the user, and only the user may move the keyboard.**
`TerminalViewDelegate.send` is the single exit for every byte going back to a pane, and it carries
two things that are identical by the time they arrive: what was typed, and what the terminal
answered by itself — a cursor position report (`CSI 6n`), a device attributes reply, OSC 11's
background colour, a mouse report. Focusing the pane for both let a *program* take the keyboard by
asking its terminal a question, which is what any full-screen TUI does on a redraw. A split is
where it shows, because a split resizes every pane in the window: the program in a background pane
re-queries and takes the focus off the pane the split just made, a fraction of a second after tmux
gave it. It hid for as long as it did because the pane being split *from* is exempt by accident —
`focus` is a no-op for the pane that already has it — so it only ever reproduced with the querying
program somewhere other than the pane in front of you.

The two are tellable apart at the source and nowhere else: user input goes through
`TerminalView.send(data:)`, which calls the delegate directly, while everything the emulator
generates reaches it through the `TerminalDelegate` conformance, which is `Terminal.sendResponse`'s
only exit — hence `ComposingTerminalView.isAnsweringQuery`. Sniffing the bytes would be guessing,
since a reply is ordinary text. **And a click has to state the focus change itself**: with mouse
reporting on — every full-screen program — click-to-focus was riding on the mouse report reaching
that same `send`, so gating focus there would have taken the click with it.
`PaneTerminalView.mouseDown` states it explicitly, which is also the right answer for a shell pane
that reports no mouse — and it leaves *motion* over a background pane meaning nothing about where
the keyboard is.

**Pane subscriptions outlive the channel.** `outputSubscribers` is a registry of what is on screen,
not a property of the connection, so `teardown` must leave it alone — `completeHandshakeIfNeeded`
repaints those panes on the next attach instead. A view subscribes exactly once, when its `NSView`
is made, and pane ids survive on the server across a drop, so the view is never rebuilt and never
subscribes again. Finishing the streams on teardown therefore freezes every pane for the rest of
the app's life — silently, because keystrokes still reach tmux and only the output is gone. Only
`removeHost` ends the streams, via `finishSubscribers`.

## The sidebar

**Sidebar rows must be `Button`s, not `.onTapGesture`.** Tap gestures are not reliably hit-tested
inside `List` rows, and giving the `List` a `selection:` binding makes AppKit's selection gesture
claim every click. Either mistake leaves the tree looking fine and completely unclickable.

**A host and everything under it is one `List` row, so it gets one context menu.** The connection
rail spans the group, which is what makes it cost no row of its own — but AppKit resolves a context
menu at the *cell*, so several nested `.contextMenu`s inside one group collapse to one, and the
survivor was the host's. Right-clicking a session or window row showed Disconnect and Detach Other
Clients, while Rename Session, Rename Window, Kill Session and Close Window were unreachable from
the tree — silently, because a menu did appear. The menu is therefore one modifier on `hostGroup`
that dispatches on `hoveredRow`, which already knows which row the pointer is on because that is
what reveals a row's buttons; a right-click is always preceded by the pointer arriving. An
unresolved key falls back to the host. New sidebar rows add a case to `RowSubject`, never a
`.contextMenu` of their own.

**A new glyph is not free just because the tree has a shape that could be reused.** The
linked-window badge was first drawn as a smaller `SessionStackIcon`, on the reasoning that the tree
already says "layered rectangles = a thing containing windows", so two of them beside a count would
read as "in that many of those". In practice it put a near-copy of the session glyph two rows below
the session glyph at a similar size, and the similarity that was meant to carry the meaning read as
a stray icon instead. It also named the wrong thing: the badge's job is "this window is not an
ordinary one" — a claim about the *relationship* — while the reused shape names the unit. A chain
link says the former with nothing to learn. Reuse the vocabulary when the meaning is the same, not
when the shapes are convenient.

**The sidebar's glyphs are drawn, not set in SF Symbols, and its gaps are cut rather than filled.**
Two separate reasons, both of which look like fussiness until you try the obvious thing. SF Symbols
strokes are tuned per symbol, so `xmark` beside `plus` is optically heavier at every point size and
weight — a diagonal lays more ink across a row of pixels than an axis-aligned rule does. Both
glyphs are therefore the *same two rules*, one pair crossed at right angles and one pair rotated
45°; that also means the ✕ spans 8pt where the + spans 11, which is the optical match, not a bug.
And the session icon's two layered rectangles need clearance between them or they merge into a blob
at 13px — but a row has no single background to fill that clearance with: it is the sidebar
material, or a hover highlight, or the selection tint over either. `SessionStackIcon` punches the
gap out with `.blendMode(.destinationOut)` inside a `compositingGroup`, so whatever the row is
really sitting on shows through and the icon has to know nothing about it. Anything colour-derived
here is composited from `controlAccentColor` or a hierarchical style rather than written down as
the sketch's hex: the sidebar and the panes follow the system appearance, and a light-mode literal
inverts wrongly in dark.

## Processes, quoting, and secrets

**The child of a fork may touch nothing but syscalls before `exec`.** `PtyTransport` builds argv,
envp, termios, and the signal mask *before* forking; the child only issues syscalls. Swift
allocation or ARC traffic there deadlocks on the malloc lock in a process with a live concurrency
pool — intermittently, and with no diagnostic at all.

**The remote command must be exactly one argv element.** `ssh` joins everything after the
destination with spaces and hands the single result to the remote login shell, so
`ssh host -- sh -c "a b c"` does *not* run `a b c`. Build it with `TmuxCommand.remoteCommand`.

**Never weaken host-key checking.** No `StrictHostKeyChecking`, no `UserKnownHostsFile`. ssh errors
are surfaced verbatim (§7), which is what `Connection.preHandshakeLog` exists to capture — if a
channel dies before tmux ever speaks, that transcript is the real diagnosis.

**Quote every user-supplied value with `TmuxCommand.quote`.** Session and window names are user
data that reach a remote shell.

**Put every name through `TmuxCommand.singleLine` as well.** Control-mode commands are
newline-framed, so a value containing a line break ends the command before tmux's parser reaches
the closing quote — and the remainder arrives as a *new* command, which tmux then executes. Quoting
cannot defend against that: the framing is resolved a layer below the parser, and text fields
accept pasted multi-line text.

**Multi-line values use `TmuxCommand.doubleQuoted`, not `quote`.** A single-quoted tmux string has
no escape for a newline, so it cannot carry one at all; only double quotes have `\n`. That is why
`paste` builds its buffer with `doubleQuoted` — and why it escapes `$`, which tmux *does* expand
inside double quotes (`"cd $HOME"` arrived as `cd /Users/you`). Before this, a paste over the
512-byte threshold delivered only its first line and fed the rest to tmux as commands: 1 of 28
lines arrived in the regression test, and a clipboard containing a line like `kill-server` would
have run it. Small pastes go through `send-keys -H`, which is hex and newline-safe by construction.
Each paste gets its own buffer name, because the chunks are separate commands and two panes pasting
at once would otherwise append into each other's buffer.

**A secret never goes through `send`.** `answerAuthenticationPrompt` writes to the transport
directly: an ssh prompt is not a tmux command, an entry in the pending-command FIFO would misalign
every `%begin` for the life of the channel, and `send` before the handshake queues into the outbox,
which would deliver it far too late. One answer per channel (`answeredPrompt`) — a rejected
password resubmitted is how accounts get locked out. The secret is never logged and never enters
`preHandshakeLog`, which is shown to the user verbatim when a channel dies.

## Reconnecting, and sessions that end

**`reconnectTarget` follows renames.** It is a session *name*, so renaming the attached session
invalidates it — and a stale name is worse than a failed lookup, because the reconnect path runs
`new-session -A -s <old name>` and creates an empty session under it. `syncReconnectTarget` is
called from `%session-renamed` and after `list-sessions`.

**A reconnect attaches; it never creates (F4.15) — but a *click* is not a reconnect.** The backoff
must not create: if the server restarted while the link was down, creating manufactures an empty
session under the remembered name and presents it as the user's. A user click means the opposite,
and conflating the two made the app look broken for a year. Every user-initiated connect goes
through `openHost`: `attach-session` with **no target**, which lands on the server's most recently
used session and cannot create; only when there is nothing to attach to does a second attempt make
one.

The failure this replaced: `reconnectNow` (since deleted, because an entry point reachable only by
writing new code is a trap) attached by *remembered name*, and with nothing remembered that is a
generated name like `tetmux_1` — a session almost no server has. tmux answers
`can't find session`, `%error`, `%exit`, and the `%exit` handler reads that as "the server has
nothing left": `.disconnected`, no retry, nothing said. Clicking a host with three sessions on it
did nothing at all, while clicking one of those sessions in the tree worked, because that path
names a session that exists. It was invisible on localhost, where tetmux had created the remembered
session itself so the name always resolved. Both shapes of "nothing to attach to" have to be
handled: an empty server arrives as `%exit`, and a host with no tmux server running at all dies
before the handshake — and would otherwise fall into the backoff to retry, eight times, an attach
that cannot ever succeed.

**`%exit` is the only thing separating "the session ended" from "the link died".** A dropped ssh
connection produces EOF and nothing else; tmux ending a client always announces it first. Verified
on 3.7b: `kill-session` on the attached session and the last pane exiting both emit
`%sessions-changed` then a bare `%exit`. Without that distinction, the recovery path treats a
deliberate close as a network blip and reconnects with `new-session -A -s <reconnectTarget>` —
recreating, with a fresh window, the session the user just closed. That was Ctrl+D appearing to
open a new shell, and the Kill Session command appearing to add a window.

So `Connection.serverEnded` short-circuits the backoff: the dead name is dropped from
`reconnectTarget`, and recovery is one attempt at `attachAny` — `attach-session` with **no
target**, which can only land on something that already exists. `Connection.attachedToSession` is
what stops that from looping: attaching to a server that is gone is not a connection failure but a
*completed* handshake answering `no sessions` and exiting, so the second `%exit` has to be told
from the first. Nothing left to attach to means `.disconnected` with an empty session list — the
sessions are genuinely gone, unlike a dropped link where they are merely out of reach, and listing
them would offer rows that do nothing.

**…and the name it leaves behind is what makes the two tellable apart on screen (F4.15).**
`.disconnected` after a session ends and `.disconnected` after a link drops are one state and
completely different news, so the ended session's name is recorded on `HostState.endedSessionName`
and the placeholder says "Session '<name>' ended" with a **Recreate** button beside the ordinary
Connect. Three details:

- It is **not a `ConnectionState` case**, for the same reason `authenticationPrompt` is not one:
  every switch over the state would grow an arm that means nothing to it.
- It is cleared on `%session-changed` and **not** on handshake completion. Attaching to a server
  with nothing left is a *completed* handshake answering `no sessions` and exiting, so clearing on
  completion wiped the name on the one path that needs it.
- The offer is **the window's**, not the host's: `WindowState` remembers the last session it
  actually displayed, by host and by name, so a second window sitting on a different session of the
  same host gets the plain placeholder rather than an offer to recreate somebody else's session.

`recreateEndedSession` is the one legitimate creation-by-remembered-name — legitimate because the
name is on screen with a button beside it.

**A window whose session ends stops, rather than following the client.** tmux moves an attached
client when its session is destroyed, and `WindowState.reconcile` used to follow it — the window
silently became a view of another session. Closing the last tab of a session is the ordinary way to
reach that, since a session with no windows is destroyed, so the failure was routine: with the tree
open it read as a jumping selection, and with the tree collapsed the only signal was that the
contents changed, indistinguishable from the session being replaced under you. Now the window keeps
an `endedSessionName` of its own and shows F4.15's offer — Recreate, or New Session — the same
answer the whole-server case already gave; anything else the user might want is a click away in the
tree, and asking for it is a decision rather than somewhere they arrived.

Three things hold it up, and the first shipped broken without one of them:

- **`selectedSession(in:)` has to suppress its fallback.** It resolves a nil selection through
  `?? host.activeSession` — which is *exactly* the session tmux moved the client to. So clearing
  `selectedSessionId` in `reconcile` set the state correctly, and the window went on rendering the
  other session's tabs anyway. State and what the views ask are two different assertions, and a
  test on the first passed while the feature did not work. The fallback itself stays — a window
  that has never chosen a session shows what the host has active rather than an empty column — it
  is suppressed only while the offer is up.
- The offer is **the window's**, so `recreatableSessionName` answers from `WindowState` before it
  asks the host, and `HostPlaceholderView` reaches it from `.connected` as well as
  `.disconnected` — a live host with a dead session is the new case, and without that arm it said
  "Connected — no sessions yet." over a server with plenty.
- It is gated on the host being **connected**. A dropped link leaves sessions listed but
  unreachable, and a restarted server reissues its ids, so a `selectedSessionId` that stops
  matching there means only "we cannot see it from here" — claiming otherwise would put a Recreate
  button over a session that is still running. `pendingRestore` resolves that case, by id and then
  by name.

Two consequences that are easy to miss. **Unlinking a window can destroy its session**: a session
left with no windows is destroyed by tmux, so closing the last tab of a multi-linked window ends
that session and moves the client elsewhere —
`testUnlinkingAWindowLeavesItRunningInItsOtherSession` asserts the window left the session *or* the
session went with it. And **a test that waits on a model predicate must fail, not skip**:
`waitForHost` throws `XCTSkip` on timeout, which is exactly as green as a pass, so anything
asserting the absence of this bug uses `waitFor` plus an explicit assertion.

## App chrome and resources

**`Bundle.module` is banned outright; resources go through `PackageResources`.** SwiftPM's
generated accessor ends in `fatalError` — it aborts the process rather than returning nil — and
neither place it looks is where a shipped `.app` keeps its resource bundles. It tries
`Bundle.main.bundleURL` plus the bundle name, which resolves under `swift run` (the directory
holding the executable) but for an `.app` is the bundle *root* — a place nothing may live, since
everything belongs under `Contents` and `codesign` seals `Contents/Resources`. Then it tries the
absolute `.build/…` path of the machine that compiled the binary, baked in at compile time. **That
second candidate is why this shipped**: on the machine that built it — a laptop after
`package-dmg.sh`, or a CI runner — the path exists, the accessor resolves, and the app launches. On
anybody else's machine the same binary dies inside `applicationDidFinishLaunching`, before a
window, with `EXC_BREAKPOINT` in `variable initialization expression of static NSBundle.module`.
0.3.1 went out exactly that way: mounted, signature-checked and run in CI, and it aborted for every
user, naming `/Users/runner/work/tetmux/…` in the crash. SwiftTerm carries its own copy of this
workaround for its Metal shaders, against the same accessor. The guard is on the *source* —
`testNoSourceFileReachesForBundleModule` scans `Sources/` — because no runtime check can see it:
`swift test`, `swift run` and the packaging job all run the binary where it was built. For the same
reason, CI's packaged-app verification renames `.build` aside first, so the runner stands in for a
user's machine rather than for itself.

**Window tabbing is off (`NSWindow.allowsAutomaticWindowTabbing = false`).** Otherwise a second
window opens as a *tab* of the first, which is wrong here twice over: ⌥-clicking a session in the
menu bar asks for a window and got a tab, and a row of macOS tabs would sit directly above the tab
bar of tmux windows — which are the tabs this app is actually about.

**A multi-line label in the detail column takes `lineLimit`, never `fixedSize`.** The two banners
in `AppMain` always did; §4.6's did not. A `NavigationSplitView` detail column measures its content
with an *unspecified* width, which a fixed-size text answers by wrapping at one character per line
and reporting the height that implies: the split view grew to 1640pt inside a 612pt window, centred
itself, and pushed **both** columns' content off the top. What makes this worth its own entry is
how it presents: the window is *empty*, with a working menu bar, a correct title, no hang, no log
line, and a complete accessibility tree in which every row has a negative screen Y. `fixedSize` is
right everywhere it is currently used — those are all fixed-width sheets.
