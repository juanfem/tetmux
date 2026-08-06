# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`tetmux` is a native macOS **tmux client**, not a terminal emulator that runs tmux. It speaks tmux
control mode (`tmux -CC`) and renders the resulting model natively: tmux windows become app tabs,
tmux panes become app splits. tmux's own status bar, pane borders, and window list are never shown.

`tetmux-srd.md` is the requirements baseline (v2.1, amended against the implementation). It is
specific and worth consulting before changing behaviour — requirement IDs (`R3.4`, `F4.17`, `T5.6`,
`P6.3`) are cited throughout the source, and those citations are the fastest way to find the
rationale for code that looks odd. Existing IDs are frozen: amendments change their text, never
their number.

`TODO.md` holds what is **open** — each entry with the evidence that it is open and instructions
concrete enough to start from. Check it before concluding something is a new bug; anything the SRD
asks for that the tree does not do belongs there, because an unlisted requirement reads as done.

## Commands

```bash
swift build
swift run tetmux                       # launch the GUI

# Tests need Xcode's toolchain: XCTest is absent from CommandLineTools,
# which is what `xcode-select -p` points at on this machine.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter testLayoutChangeSeparatesItsThreeFields
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SessionIntegrationTests

# §8's ControlMaster chaos scenario needs a real ssh host, and skips without one.
TETMUX_SSH_HOST=user@host:port swift test --filter testDroppingTheControlMasterSocket

Scripts/package-dmg.sh                 # .app bundle inside a .dmg, in dist/
Scripts/package-dmg.sh --skip-build    # …from whatever is already in .build/release
Scripts/package-dmg.sh --version 1.2.3 --output dist

Scripts/measure-latency.sh             # P6.1 keypress→glyph p95, against a private tmux server
Scripts/measure-throughput.sh          # P6.3 %output parse rate, release build
Scripts/measure-idle.md                # P6.6/P6.7 by hand — the procedure, not a program

Scripts/build-tmux-matrix.sh           # tmux 3.0/3.2a/3.3a/3.4/3.5 from pinned tarballs
Scripts/test-matrix.sh                 # the integration suite against every one of them
Scripts/test-matrix.sh 3.0 --filter testDraggingATabReordersTheSession
```

`.github/workflows/ci.yml` runs **three** jobs on every push, and a fourth — the tmux version matrix
below — weekly, on demand, and on a `v*` tag. `swift test` on macOS with tmux
installed — otherwise the integration suite silently skips itself and a green check means nothing, so
the run fails if the skip fires. On Ubuntu, `swift build --target tetmuxCore` **and**
`swift test --filter tetmuxCoreTests`, which is what exercises the §2.4 portability hedge; every job
used to be macOS, and a core-only regression on glibc went uncaught. Then the packaging script, whose
result is mounted and launched before it is uploaded. A `v*` tag also publishes the image as a
release — and that is the one path where the matrix **gates** rather than reports, since a .dmg is
what somebody installs. `package` therefore needs `matrix` under an explicit
`success || skipped` condition: a skipped dependency skips its dependents by default, so the bare
`needs:` would stop producing a .dmg on every ordinary push and say nothing about why.

**The manifest declares the AppKit half of the package only on macOS**, and that is what makes the
Linux test job possible at all. `--filter` chooses which tests *run*, never which targets are built:
`swift test` builds one product out of every test target, so a Linux job asking only for
`tetmuxCoreTests` still has to compile `tetmuxTests`, which imports `tetmuxUI`, which is AppKit and
SwiftTerm by design. `Package.swift` is ordinary Swift evaluated on the host, so `tetmuxUI`, the
executable and `tetmuxTests` are appended inside `#if os(macOS)`.

The .dmg is **arm64-only by decision** (§2.5), and says so in its filename. A universal binary
needs SwiftPM's `--arch arm64 --arch x86_64`, which routes through xcbuild, which compiles
SwiftTerm's Metal shaders and so needs a Metal toolchain component that is a separate
multi-gigabyte download. The native path copies the `.metal` source into the resource bundle and
never invokes the compiler. Do not revisit universal as part of other packaging work.

Signing is ad-hoc (`codesign --sign -`): no Developer ID, no notarisation, no updater. That is a known
gap with an account behind it, not an oversight — see `TODO.md`.

### The diagnostic CLI

```bash
swift run tetmux --diagnose                    # local tmux
swift run tetmux --diagnose server.example.org   # a saved host, by id or name
```

Connects a real channel, prints the parsed event stream to stderr and the resulting topology, version
and RTT to stdout, then subscribes to a pane and round-trips a keystroke. **Reach for this first when
a host misbehaves** — it separates "the protocol layer is wrong" from "the views are wrong", which is
otherwise slow to establish. It resolves against the saved host list, so it exercises the exact user,
port, and custom command the UI would use, and it can answer a password prompt from the Keychain.

To ground a protocol question in reality, capture a live stream rather than reasoning about it:
drive `tmux -CC` under a PTY (Python's `pty.fork` is the quickest way) and read the raw bytes.
Several fixtures in `ControlCodecTests` were produced exactly that way.

## Architecture

Four layers. Everything below the UI is plain Swift with no AppKit dependency.

```
tetmux      app entry point + --diagnose CLI
tetmuxUI    SwiftUI/AppKit chrome; SwiftTerm pane surfaces; KeychainStore   (@MainActor)
tetmuxCore  SessionService (actor) · ControlCodec · LayoutParser · PtyTransport · SshPromptDetector
CUtil       systemLibrary shim, Linux only — `forkpty` lives in libutil on glibc
```

**`tetmuxCore` must not import AppKit, SwiftUI, or SwiftTerm.** That is the §2.4 portability hedge,
and its immediate payoff is that the interesting logic stays headlessly testable. `NetworkStateMonitor`
lives in `tetmuxUI` precisely because it needs `NSWorkspace`. `CUtil` and the Linux CI job are the
other half of that hedge: a hedge that is never exercised has already stopped being a hedge.

Where things are, since the invariants below name symbols without saying which file holds them:

| File | What it is |
|---|---|
| `Core/ControlCodec.swift` | Bytes → `[ControlEvent]`. Pure value type, no I/O. |
| `Core/LayoutParser.swift` | tmux layout strings → `LayoutNode` tree. |
| `Core/PtyTransport.swift` | `forkpty` + reader thread. The only spawner of anything a channel runs on. |
| `Core/CommandProbe.swift` | One question, one subprocess, no pty — F4.4's discovery and nothing else. |
| `Core/SshPromptDetector.swift` | Classifies a pre-handshake prompt ssh is sitting on. |
| `Session/SessionService.swift` | The actor. Channels, correlation, topology, flow control. |
| `Session/HostModel.swift` | `HostState`, `TmuxSession`, `TmuxWindow`, `TmuxVersion`. |
| `Session/TmuxCommand.swift` | Every command string and format, with its quoting rules. |
| `Session/HostConfigStore.swift` | `hosts.json`, `~/.ssh/config` discovery, `ssh -G` resolution. |
| `AppMain.swift` | Scenes, menus, tab strip, window chrome. |
| `AppModel.swift` | App-wide model; the decisions that need no channel. |
| `WindowState.swift` | Everything that belongs to one macOS window. |
| `TerminalContainerView.swift` | The pane-tree renderer and `PaneDivider`. |
| `TerminalSurface.swift` | `TerminalView` wrapper, `TerminalTheme`, bell, OSC handling, `PaneTerminalView`. |
| `PassthroughView.swift` | §4.6's whole surface: the mode indicator, the offer, and the one terminal. |
| `SidebarView.swift` · `StatusBarView.swift` | Host/session/window tree (drawn glyphs); F4.28 footer. |
| `LauncherOverlay.swift` | ⌘K fuzzy launcher over hosts, sessions and windows (F4.25/F4.26). |
| `SettingsView.swift` · `KeymapPolicy.swift` | The `Settings` scene; shortcut table. |
| `KeymapSettingsView.swift` · `ShortcutRecorder.swift` | The editable keymap and its chord recorder. |
| `KeyEventMonitor.swift` | The one `NSEvent` monitor: ⌥⌘V's literal escape (F4.21). |
| `WorkspaceStore.swift` · `SettingsStore.swift` | `workspace.json` and `settings.json`. |
| `ContrastPolicy.swift` | Increase Contrast, resolved once for every site that honours it. |
| `ColorScheme.swift` | Pane colour schemes: the 16 ANSI slots and the three named colours. |
| `LiveResizeGate.swift` | R3.7 — one macOS window's panes stop asking tmux while its edge is dragged. |
| `NotificationPolicy.swift` | F4.31 — which events earn a banner, and `WatchedWindow`. |
| `DestructiveActionModal.swift` | The F4.10 confirmation, which says *why* the close is a kill. |
| `CopyModeSearchSheet.swift` | Searches tmux's history, which is not what ⌘F searches. |
| `BellNotifier.swift` · `KeychainStore.swift` | F4.31 background bells; per-host passwords. |

### The central abstraction

Everything reduces to a **control-mode channel**: a bidirectional byte stream speaking the tmux
control protocol. Local and remote differ *only* in which process `PtyTransport` spawns:

| | Spawned process |
|---|---|
| Local | `tmux -CC -2 -u new-session -A -s <name>` |
| Remote | `ssh … -tt <host> -- <one argv element that execs tmux -CC>` |

There is no "remote code path". If you find yourself adding a remote branch above `PtyTransport`,
the design has gone wrong.

**§4.6's passthrough is the same sentence with `-CC` removed**, and that is the whole difference in
the invocation — `localPassthroughArguments` is asserted equal to `localArguments` minus that flag,
because a fallback that also dropped `-u` would present as a font bug. What differs is everything
*above* the transport: a `PassthroughChannel` has no codec, no pending-command FIFO, no handshake
and no flow control, since all of that exists to talk to a parser and there is no parser on the far
end. R3.8's last row is the same machinery with no tmux in it at all — a login shell. See the
passthrough entry under "Behaviour worth knowing".

## Invariants that are easy to violate

These are the ones that produce silent, hard-to-diagnose breakage. Each has a regression test.

**Identifiers carry their tmux sigil.** `@3`, `%7`, `$1` — everywhere, from codec to view. Stripping
and re-adding sigils per layer was a recurring source of lookups that silently matched nothing.

**tmux command numbers are server-wide and start at an arbitrary value.** They are not 0-based and
cannot be predicted, so correlation is by *order*: responses are strictly ordered, and
`SessionService` matches them against a FIFO of pending commands. tmux also emits one `%begin`/`%end`
block of its own on attach, before we can write anything; commands therefore queue in an outbox until
that handshake completes. Writing earlier misaligns the queue by one for the life of the channel.

The number that cannot schedule the match can still detect a bad one, and does: a `%begin` whose
number fails to increase, a `%begin` with nothing pending *after* the handshake, and a terminator
closing a block it did not open are each logged as a desync. Detecting is not recovering — there is
still no recovery — so everything below that can cause a misalignment treats it as fatal rather than
as an error to report.

**…and not every block on the wire is one of ours.** Correlation by order holds only while every
`%begin` answers something we sent, and two do not: tmux's own block on attach, and **one for every
command a keystroke dispatches through a pane's mode table**. Verified on 3.7b — with a pane in copy
mode, `send-keys -t %p Up` produces the response to `send-keys` (flags `1`) *and then* an unsolicited
block (flags `0`) for the `cursor-up` the key was bound to; three `Up`s produce three of them. Taking
one off the FIFO hands the next real answer to the wrong command for the life of the channel, and it
needs no copy-mode feature to happen — a `prefix [` typed into a pane is enough, which is why panes
in copy mode had a history of going strange. `ControlCodec.blockAnswersOurCommand` reads bit 0 of the
flags field, not equality, because it is a bitfield tmux may add to; an *absent* field means a version
this was never verified against (every one in the R3.6 matrix emits it) and is read as ours, since
the alternative answers no command at all.

**Framing outranks dispatch.** Inside a `%begin` block every line is response content, including one
that starts with `%`, and only a `%end`/`%error` **carrying the matching number** may close it.
Parsing `%`-prefixed lines as notifications first cost real data and admitted forgery: `capture-pane`
replays scrollback as result lines, so a zsh or tcsh `%` prompt vanished from every repaint — and
captured text containing `%exit` set `serverEnded`, after which a dropped link looked like an orderly
session end and nothing reconnected. `%output` for a pane could be injected the same way.

**A partial PTY write is a dead channel, not a failed command.** A fragment with no newline sits in
front of tmux's parser and the next command concatenates onto it: one `%begin` block answering two
commands, and the FIFO above is misaligned for good. So `PtyTransport` distinguishes `.partial` from
`.nothingWritten`, `send` unqueues only for the latter, and `.partial` tears the channel down. This is
exactly the path a large paste over a congested link takes.

**The reader thread owns the master fd and is the only thing that closes it.** `terminate()` used to
close it while the thread sat in a 1000 ms `poll` holding that number by value, so a fast reconnect
handed back the same fd had its bytes consumed by the old, already-finished stream — a hole where the
`%begin` should have been, or a handshake that never arrived and a host stuck at "Connecting…". The
fd outliving `terminate` by up to one poll interval is the accepted cost.

**`list-windows` order is the window order, and the model has to be re-sorted into it.**
`applyWindows` updates known windows in place and appends new ones, which keeps identity stable but
says nothing about position — so without an explicit sort each session kept whatever order it first
learned its windows in, and a `move-window` or `swap-window` from anywhere (our own reorder, another
client, `movew` typed at a prompt) changed nothing visible. Tab reordering is `move-window -b`/`-a`
on tmux ≥ 3.2 and a run of adjacent `swap-window`s below it — 3.0 answers `illegal option -- b` —
and both address windows by `@id`, never by index: a session's indices are arbitrary and often not
contiguous, so a position in the strip is not an index. The *source* of a move carries its session
(`-s $2:@7`), because a window linked into several sessions is reachable by id from any of them and
an unqualified `-s` leaves tmux to choose which one it leaves.

**…and a reorder has to ask for the topology back, because no notification means "the order
changed".** `move-window` looks as though one does: it emits `%window-add @2` then `%window-close @2`
for the same window, since tmux implements it by unlinking and relinking, and those schedule a
refresh. That is an accident of the implementation, and the fallback does not share it —
`swap-window` emits `%session-window-changed` alone, which says only which window is now *active*. So
below tmux 3.2 a dragged tab reordered the windows on the server and the strip never moved: the model
kept the order it last read until something unrelated refreshed it. Both branches now schedule the
refresh themselves. Found by `Scripts/test-matrix.sh` on 3.0 — it is invisible on a machine with one
modern tmux, where the accident holds.

**State broadcasts are for topology changes only.** `SessionService.ingest` diffs `HostState` and
broadcasts only when it actually changed. Broadcasting on `%output` rebuilds the SwiftUI tree for
every chunk of terminal output, tearing down the very terminal views the output is painting into.

**tmux owns geometry (§3.3).** Views measure themselves, ask, and then lay out whatever
`%layout-change` returns. Nothing resizes a surface before tmux confirms. Pane surfaces are snapped to
the cell size tmux reported; letting the emulator pick its own drifts by a cell and desynchronises the
grid.

**A pane's usable width is its frame width, which is why SwiftTerm's scroller is hidden.** The view
reserves 17pt for a scroller and derives its own column count from `frame.width - reservedScrollerWidth`,
overriding the `resize(cols:rows:)` it is handed — while `requestSizes` measures the container and
subtracts nothing. tmux therefore sized panes to more columns than the emulator could draw and every
full-width program wrapped early (at 12pt SF Mono: 96 columns requested, 93 drawn). It is *hidden*
rather than subtracted in `requestSizes`, deliberately: every pane reserves its own gutter, so the
correction depends on how many panes are across the widest row — a property of the layout, which is
tmux's answer to the size we asked for. That is the same self-feeding measurement as the pane-derived
cell size below. Hidden, the arithmetic has one owner again.

**A tmux window's size has exactly one owner.** On tmux ≥ 2.9 each displayed window is sized
individually — `set-option window-size manual` plus `resize-window -t @id -x -y` — which is what lets a
torn-off macOS window size its window independently of the main one. A client has only one size, so
`refresh-client -C` cannot do this, and two views driving the same window fight: each `%layout-change`
prompts the other to ask for its own size back, forever. `windowSizeOwners` keys that right to the
focused view; the loser renders the grid tmux gave the owner. Below 2.9 there is no per-window sizing
at all and `window-size latest` + `refresh-client -C` remains the only mechanism — without *something*
there an old or small client clamps every window toward 80×24 (F4.17). `window-size` is a session
option, so it is re-applied after `%session-changed` and put back with `set-option -u` on a deliberate
disconnect — and **that last command has to be waited for, not merely written**. `teardown` hangs the
channel up with `SIGHUP`, so the tmux client must have read the line out of the pty before that lands;
writing and terminating in the same breath is a race an idle machine wins and a loaded one loses,
leaving `manual` on the user's session for the next plain `tmux attach` to find. It passed here six
runs in a row and failed in CI on a commit that had passed there minutes earlier. `sendAndAwait` waits
for tmux's own `%end` — with a timeout, because a channel can accept a write and never answer, and a
disconnect that hangs is worse than an option left set. `detach-client` is waited for against the same
race, for the same reason.

**A zoomed window renders the visible layout, and is a member of the full one.** tmux keeps
`window_layout` as the layout the window would have *unzoomed*; `window_visible_layout` is what is on
screen. Render the wrong one while a pane is zoomed and every surface is forced to its unzoomed cell
size while tmux emits output sized to the whole window — wrapped, truncated, and unrecoverable without
unzooming from elsewhere. So `TmuxWindow.renderTree` prefers the visible tree when `isZoomed`, and
views must use it rather than `layoutTree` (pane cycling included). Membership and labels still come
from the full layout, or a zoomed split window relabels itself as holding one pane. Nothing tracks
zoom locally — tmux announces it in the `%layout-change` flags — but a window **already zoomed when
tetmux attaches never sends a `%layout-change` at all**, which is why `windowsFormat` has to carry
`#{window_visible_layout}` and `#{window_flags}` too.

**A repaint for a second viewer must be addressed to it alone.** `capture-pane`'s payload starts with
`ESC[H ESC[2J ESC[3J` — screen *and* scrollback. The same pane can be on screen in two macOS windows,
and the late joiner needs a repaint because control mode resends nothing for a pane that is merely
sitting there; broadcasting it would wipe the history the other window is holding. Hence
`Kind.capturePane(paneId:target:)` and `deliver(_:hostId:paneId:target:)`.

**Pane output is bounded in bytes, and the viewer is what reports progress (P6.5).** A pane produces
output whether or not anyone is painting it — `yes` is the one-word reproducer — and the producer side
of an `AsyncStream` cannot observe whether its consumer is keeping up. So the surface acknowledges
what it has fed (batched at 16 KiB; an actor hop per chunk costs more than the accounting is worth),
`SessionService` tracks undelivered bytes per subscriber, and the *slowest* viewer of a pane decides:
above 1 MiB it sends `refresh-client -A '%p:pause'`, below 256 KiB it resumes. The gap between the two
is deliberate — one threshold would pause and resume on alternate chunks, and each resume costs a full
`capture-pane`.

Three things about this are easy to get wrong. **The byte ceiling cannot be delegated to the stream's
buffering policy**, which counts elements: `%output` chunk sizes vary by orders of magnitude with what
the pane is doing, so a buffer deep enough to hold a megabyte of `cat` is also one a chatty pane fills
long before the high-water mark trips — and then the pause that is supposed to be the mechanism never
fires at all. **A dropped chunk must come back off the books**, because it will never be fed and so
never acknowledged; counting it inflates `outstanding` permanently and eventually wedges the pane
paused with nothing left to drain. And **a pane tmux paused on its own** (`pause-after`, which also
switches the server to `%extended-output`) **is ours to resume** — nothing else will, and a pane left
paused never moves again. That one needs its own hold-down rather than the viewer's watermark:
resuming it as soon as the local counter drains turns tmux's `pause-after` into a pause/resume cycle
with a full repaint each time. Anything lost is repaired by a repaint, never handed to the emulator as
a hole in the byte stream. All of it needs tmux 3.2; below that the byte ceiling is the whole mechanism.

**The cell size comes from the font, never from a pane.** A pane can only report its own frame
divided by its own cell count, and that measurement is circular: the frame comes from the layout, the
layout comes from the size we asked tmux for, and that size came from the cell size. With one pane the
circle is stable and invisible. With a split window each pane divides a *different* frame by a
*different* cell count, so they report different cell sizes — 8.31, 8.39 and 8.46 for one three-pane
window — whichever reported last won, and the requested width oscillated between 111 and 112 columns
forever. That was the separator flicker: `%layout-change` on every frame, panes relaid out on every
one. `TerminalTheme.cellSize(backingScaleFactor:)` mirrors SwiftTerm's `computeFontDimensions` and
depends on nothing but the font, which breaks the loop at its source. `sizeChanged` from the emulator
is deliberately ignored for the same reason — it fires when SwiftTerm re-derives its grid from the
frame we just gave it, so acting on it is reacting to our own last action.

**…and the scale factor it snaps to is the *window's*, which is not `NSScreen.main`.** The mirror is
only a mirror if both sides resolve the same density: `ceil(w × scale) / scale` moves the cell by a
whole point between 1× and 2× — 12pt SF Mono advances `W` by 7.2, which is 8.0 at 1× and 7.5 at 2×.
`NSScreen.main` is *not* this window's screen; it is the screen holding whichever window has keyboard
focus anywhere on the system, so with a 1× monitor beside a 2× built-in it changes answer every time
you click into another application on the other display, while the window has not moved. SwiftTerm
resolves its own `cellDimension` from `window?.backingScaleFactor` and gets the real one, so the two
halves of §3.3 came apart: measured on that desk, a 572pt pane on the Retina display asked tmux for
71 columns while its grid drew 76 — five columns tmux never writes into, and the reverse arrangement
is the early-wrapping failure the scroller gutter used to cause. `@Environment(\.displayScale)`
follows the window; nothing else does. It also has to *re-ask* on a change, because a window dragged
to another display keeps its size in points and `requestSizes` hangs off `proxy.size` — without
`onChange(of:)` the panes keep the old display's grid until something unrelated resizes them.

**A drag on a window edge asks tmux nothing until it ends (R3.7).** §3.3 asks for a debounce *and*
for suppression during live resize; only the debounce existed, so dragging an edge was a
`refresh-client -C` every 100 ms, each answered with a `%layout-change`, each relaying out every pane.
Nothing corrupts — tmux stays authoritative and the last answer wins — which is why it went unnoticed
as anything but a heavy drag. `LiveResizeGate` holds the ask instead, and the drag ends with one
request at the size the user let go of. Two things about it. The held request is **keyed by tmux
window**, because every tab is built and measuring itself (the unselected ones are hidden with
`.opacity(0)`, not omitted) and one held closure would let the last tab laid out overwrite the rest —
every other tab would leave the drag still holding its old grid, silently. And the gate is **per macOS
window**, observing one `NSWindow`: another window's panes are not the ones being dragged. It is
unsubscribed from `onDisappear`, not from `deinit` — a `deinit` is nonisolated and cannot touch the
state, and `WindowState.nsWindow` is weak, so a reference nilled by ARC never runs `didSet`.

**A resize handle has to be an `NSView`, and its identity must not move.** A pane surface is
SwiftTerm's `TerminalView`, a real `NSView` that tracks the mouse for selection; a SwiftUI
`DragGesture` layered over it in a `ZStack` never sees an event, whatever the z-order says. Hence
`PaneDivider` being an `NSViewRepresentable` with `mouseDown`/`mouseDragged` and a `resetCursorRects`
resize cursor. Two further traps, both of which produce a handle that *looks* right and silently does
almost nothing. Every divider is collected into **one overlay above the whole tree** rather than
nested in the container it belongs to — nested, a handle sits underneath the pane surfaces of its
sibling subtree, so the outer split dragged and the inner one did not. And the `ForEach` id must be
the seam's **place in the tree**, never its position and never the target pane: a left/right seam and
the top/bottom seam inside its leading column resolve to the same first pane, so keying on the pane
renders one seam where there should be two — and keying on position changes the id the instant a drag
resizes anything, tearing the view down mid-gesture so the pane moves exactly one cell however far the
pointer travels. The drag baseline is captured at `mouseDown` for the same reason: the layout moves
underneath as tmux answers, and re-reading it each frame measures from a moving origin.

**Window tabbing is off (`NSWindow.allowsAutomaticWindowTabbing = false`).** Otherwise a second window
opens as a *tab* of the first, which is wrong here twice over: ⌥-clicking a session in the menu bar
asks for a window and got a tab, and a row of macOS tabs sits directly above the tab bar of tmux
windows, which are the tabs this app is actually about.

**A multi-line label in the detail column takes `lineLimit`, never `fixedSize`.** The two banners in
`AppMain` always did; §4.6's did not, and the difference is that a `NavigationSplitView` detail
column measures its content with an *unspecified* width — which a fixed-size text answers by wrapping
at one character per line and reporting the height that implies. The split view grew to 1640pt inside
a 612pt window, centred itself, and pushed **both** columns' content off the top. What makes this
worth its own entry is how it presents: the window is *empty*, with a working menu bar, a correct
title, no hang, no log line, and a complete accessibility tree in which every row has a negative
screen Y. `fixedSize` is right everywhere it is currently used — those are all fixed-width sheets.

**Pane surfaces need explicit `.id(paneId)`.** The layout tree is rendered through `AnyView`, which
erases structural identity, so without an explicit id SwiftUI rebuilds every `NSView` on each update
and discards the terminal's contents.

**Every tmux window of the session is built; unselected ones are hidden with `.opacity(0)`, never
omitted with `if`.** Two separate failures, one visible and one not. Building only the selected window
tore down its `TerminalView`s on each tab switch and with them the whole local scrollback — the return
trip replays `capture-pane`, which begins `ESC[H ESC[2J ESC[3J` and is capped at the capture budget,
so "scroll up to see what that build printed" worked right up until you looked at another tab. And a
`ZStack` hands every child the same frame, so a background tab keeps measuring the size it would
really have and keeps asking tmux for that grid; dropped from the tree it would resize its tmux window
to nothing and reflow everything running in it.

**Pane subscriptions outlive the channel.** `outputSubscribers` is a registry of what is on screen,
not a property of the connection, so `teardown` must leave it alone — `completeHandshakeIfNeeded`
repaints those panes on the next attach instead. A view subscribes exactly once, when its `NSView` is
made, and pane ids survive on the server across a drop, so the view is never rebuilt and never
subscribes again: finishing the streams on teardown freezes every pane for the rest of the app's
life, and does it silently, because keystrokes still reach tmux and only the output is gone. Only
`removeHost` ends them, via `finishSubscribers`.

**Sidebar rows must be `Button`s, not `.onTapGesture`.** Tap gestures are not reliably hit-tested
inside `List` rows, and giving the `List` a `selection:` binding makes AppKit's selection gesture
claim every click. Either mistake leaves the tree looking fine and completely unclickable.

**A host and everything under it is one `List` row, so it gets one context menu.** The rail spans the
group, which is what makes it cost no row of its own — but AppKit resolves a context menu at the
*cell*, so several nested `.contextMenu`s inside one group collapse to one, and the survivor was the
host's. Right-clicking a session or a window row showed Disconnect and Detach Other Clients, and
Rename Session, Rename Window, Kill Session and Close Window were unreachable from the tree for as
long as the group has been a single row — silently, because a menu did appear. The menu is therefore
one modifier on `hostGroup` that dispatches on `hoveredRow`, which already knows which row the
pointer is on because that is what reveals a row's buttons; a right-click is always preceded by the
pointer arriving. An unresolved key falls back to the host. New sidebar rows add a case to
`RowSubject`, never a `.contextMenu` of their own.

**A new glyph is not free just because the tree has a shape that could be reused.** The linked-window
badge was first drawn as a smaller `SessionStackIcon`, reasoning that the tree already says "layered
rectangles = a thing containing windows" so two of them beside a count would read as "in that many of
those". It put a near-copy of the session glyph two rows below the session glyph at a similar size,
and the similarity that was meant to carry the meaning read as a stray icon instead. It also named
the wrong thing: the badge's job is "this window is not an ordinary one", which is a claim about the
*relationship*, and the shape being reused names the unit. A chain link says the former with nothing
to learn. Reuse the vocabulary when the meaning is the same, not when the shapes are convenient.

**The sidebar's glyphs are drawn, not set in SF Symbols, and its gaps are cut rather than filled.**
Two separate reasons, both of which look like fussiness until you try the obvious thing. SF Symbols
strokes are tuned per symbol, so `xmark` beside `plus` is optically heavier at every point size and
weight — a diagonal lays more ink across a row of pixels than an axis-aligned rule does. Both glyphs
are therefore the *same two rules*, one pair crossed at right angles and one pair rotated 45°, which
also means the ✕ spans 8pt where the + spans 11: that is the optical match, not a bug. And the
session icon's two layered rectangles need clearance between them or they merge into a blob at 13px,
but a row has no single background to fill that clearance with — it is the sidebar material, or a
hover highlight, or the selection tint over either. `SessionStackIcon` punches the gap out with
`.blendMode(.destinationOut)` inside a `compositingGroup`, so whatever the row is really sitting on
shows through and the icon has to know nothing about it. Anything colour-derived here is composited
from `controlAccentColor` or a hierarchical style rather than written down as the sketch's hex: the
sidebar and the panes follow the system appearance, and a light-mode literal inverts wrongly in dark.

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

**Quote every user-supplied value with `TmuxCommand.quote`.** Session and window names are user data
that reach a remote shell.

**Put every name through `TmuxCommand.singleLine` as well.** Control-mode commands are newline-framed,
so a value containing a line break ends the command before tmux's parser reaches the closing quote and
the remainder arrives as a *new* command — which tmux then executes. Quoting cannot defend against that:
the framing is resolved a layer below the parser, and text fields accept pasted multi-line text.

**Multi-line values use `TmuxCommand.doubleQuoted`, not `quote`.** A single-quoted tmux string has no
escape for a newline, so it cannot carry one at all; only double quotes have `\n`. That is why `paste`
builds its buffer with `doubleQuoted` — and why it escapes `$`, which tmux *does* expand inside double
quotes (`"cd $HOME"` arrived as `cd /Users/you`). Before this, a paste over the 512-byte threshold
delivered only its first line and fed the rest to tmux as commands: 1 of 28 lines arrived in the
regression test, and a clipboard containing a line like `kill-server` would have run it. Small pastes go
through `send-keys -H`, which is hex and newline-safe by construction. Each paste gets its own buffer
name, because the chunks are separate commands and two panes pasting at once would otherwise append into
each other's buffer.

**A secret never goes through `send`.** `answerAuthenticationPrompt` writes to the transport directly:
an ssh prompt is not a tmux command, an entry in the pending-command FIFO would misalign every `%begin`
for the life of the channel, and `send` before the handshake queues into the outbox and would deliver
it far too late. One answer per channel (`answeredPrompt`) — a rejected password resubmitted is how
accounts get locked out. The secret is never logged and never enters `preHandshakeLog`, which is shown
to the user verbatim when a channel dies.

**`reconnectTarget` follows renames.** It is a session *name*, so renaming the attached session
invalidates it — and a stale name is worse than a failed lookup, because the reconnect path runs
`new-session -A -s <old name>` and creates an empty session under it. `syncReconnectTarget` is called
from `%session-renamed` and after `list-sessions`.

**A reconnect attaches; it never creates (F4.15) — but a *click* is not a reconnect.** The backoff
must not create: if the server restarted while the link was down, creating manufactures an empty
session under the remembered name and presents it as the user's. What a user click means is the
opposite, and conflating the two was a bug that made the app look broken for a year. Every
user-initiated connect goes through `openHost`: `attach-session` with **no target**, which lands on
the server's most recently used session and cannot create, and only when there is nothing to attach
to does a second attempt make one. It replaced `reconnectNow` — since deleted, because an entry point
reachable only by writing new code is a trap — at those call sites because that path attached by
*remembered name*, and with nothing remembered the name is `tetmux-main` — a session almost no server
has. tmux answers `can't find session: tetmux-main`, `%error`, `%exit`, and the
`%exit` handler reads that as "the server has nothing left": `.disconnected`, no retry, nothing said.
Clicking a host with three sessions on it did nothing at all, while clicking one of those sessions in
the tree worked, because that path names a session that exists. It was invisible on localhost, where
tetmux creates `tetmux-main` itself so the hard-coded name always resolves. Both shapes of "nothing
to attach to" have to be handled: an empty server arrives as `%exit`, and a host with no tmux server
running at all dies before the handshake and otherwise falls into the backoff to retry, eight times,
an attach that cannot ever succeed.

**`%exit` is the only thing separating "the session ended" from "the link died".** A dropped ssh
connection produces EOF and nothing else; tmux ending a client always announces it first. Verified on
3.7b: `kill-session` on the attached session and the last pane exiting both emit `%sessions-changed`
then a bare `%exit`. Without that distinction the recovery path treats a deliberate close as a network
blip and reconnects with `new-session -A -s <reconnectTarget>` — recreating, with a fresh window, the
session the user just closed. That was Ctrl+D appearing to open a new shell and the Kill Session
command appearing to add a window. So `Connection.serverEnded` short-circuits the backoff: the dead
name is dropped from `reconnectTarget`, and recovery is one attempt at `attachAny` —
`attach-session` with **no target**, which can only ever land on something that already exists.
`Connection.attachedToSession` is what stops that from looping: attaching to a server that is gone is
not a connection failure but a completed handshake answering `no sessions` and exiting, so the second
`%exit` has to be told from the first. Nothing left to attach to means `.disconnected` with an empty
session list — the sessions are genuinely gone, unlike a dropped link where they are merely out of
reach, and listing them offers rows that do nothing.

**…and the name it leaves behind is what makes the two tellable apart on screen (F4.15).**
`.disconnected` after a session ends and `.disconnected` after a link drops are one state and
completely different news, so the ended session's name is recorded on `HostState.endedSessionName` and
the placeholder says "Session '<name>' ended" with a **Recreate** beside the ordinary Connect. Three
things about it. It is **not a `ConnectionState` case**, for the same reason `authenticationPrompt` is
not one: every switch over the state would grow an arm that means nothing to it. It is cleared on
`%session-changed` and **not** on handshake completion — attaching to a server with nothing left is a
*completed* handshake answering `no sessions` and exiting, so clearing it there wiped the name on the
one path that needs it. And the offer is **the window's**, not the host's: `WindowState` remembers the
last session it actually displayed, by host and by name, so a second window sitting on a different
session of the same host gets the plain placeholder rather than an offer to recreate somebody else's
session. `recreateEndedSession` is the one legitimate creation-by-remembered-name, and it is
legitimate because the name is on screen with a button beside it.

Two consequences that are easy to miss. **Unlinking a window can destroy its session**: a session left
with no windows is destroyed by tmux, so closing the last tab of a multi-linked window ends that
session and moves the client elsewhere — `testUnlinkingAWindowLeavesItRunningInItsOtherSession` asserts
the window left the session *or* the session went with it. And **a test that waits on a model
predicate must fail, not skip**: `waitForHost` throws `XCTSkip` on timeout, which is exactly as green
as a pass, so anything asserting the absence of this bug uses `waitFor` plus an explicit assertion.

## Protocol gotchas

`ControlCodec` is a pure value type: `mutating func feed(_:) -> [ControlEvent]`, no I/O, no async.
Keep it that way — it is the only reason the protocol layer is testable against fixtures.

- `%layout-change @w <layout> <visible-layout> <flags>` — **three** fields since tmux 2.5, and all
  three are load-bearing. Folding them into one string makes the layout unparseable and the window
  renders nothing; dropping the second and third instead parses fine and renders the wrong grid
  whenever a pane is zoomed.
- `%extended-output %p <age> : <data>` — the colon is a reserved field and must be skipped. A layout
  with no colon field must fail the parse rather than yield empty data, or a build that varies the
  field layout makes every pane go quietly dead.
- `%subscription-changed <name> <session> <window> <index> <pane> : <value>` — same reserved colon.
  The name must be checked: another control client can hold subscriptions of its own.
- **`#{session_attached}` does not count a control-mode client on tmux 3.0.** Verified across the
  built matrix: 3.0 answers `0` for the very session this client is attached to, and 3.2a onward
  answer `1`. So `TmuxSession.isAttached` is always false on a 3.0 server for tetmux's own sessions —
  cosmetic, because nothing decides anything from it. `HostState.liveSessionIds` is what answers "are
  these panes live", it is tetmux's own record, and it is the same on every version. Anything
  asserting that a client moved must use it.
- `%output` payloads are octal-escaped and arbitrary binary. Decode on bytes, never via `String`.
- Lines are bounded at 16 MiB, after which the buffer resets. A control stream that never sends a
  newline is otherwise unbounded memory growth.
- **Command *arguments* are parsed by tmux's own lexer, and a shell cannot tell you how.** Passing argv
  from a shell parses no tmux quoting at all, so probe questions like this over a real channel. Verified
  on 3.7b, inside double quotes: `\n`/`\r`/`\t`/`\e` work, `$VAR` **expands**, `\$` and `\#` are literal,
  raw ESC/0x01/0x7f pass through, octal `\101` works, and `\xHH` does *not* (it yields a literal `x`).
  NUL cannot survive at all — commands are C strings.
- Command response bodies are *not* escaped, so `capture-pane -e` output arrives as raw escape
  sequences; `commandResultLine` carries raw `bytes` alongside the lossy `line`.
- The stream opens with a DCS preamble (`ESC P 1000 p`) glued to the first `%begin`, and over ssh
  there may be banner text ahead of it. Anything before the first `%begin` is not protocol.
- Unknown `%` notifications are logged and ignored, never fatal — tmux adds them between versions.
- `LayoutParser` runs on bytes from the wire, so it must never trap: overflow is checked rather than
  arithmetic-trapped, and recursion is depth-capped. `try?` catches neither.
- **The layout checksum is verified (R3.5), and what makes that safe is that a rejection is
  all-or-nothing.** `layoutTree == nil` renders an *empty window*, so validation that blanks the tree
  on a mismatch would cost the user their panes on the first `%layout-change` — which is why it
  defaulted to off for so long. `TmuxWindow.apply` instead parses both fields up front and either
  commits both or keeps the previous layout, string and tree together: the worst case is a grid that
  was right a moment ago, and the next notification replaces it. Both fields go down together on one
  bad parse deliberately — they describe one window and arrive in one notification, and applying the
  full layout alone would set `isZoomed` with no visible tree, which is the wrapped-and-truncated
  failure `window_visible_layout` exists to prevent. `apply` returns a `LayoutApplyResult` because the
  model has no logger and a silently discarded layout is the exact shape of bug this list is made of.

## Behaviour worth knowing before changing it

- **Passthrough is a different channel, not control mode with features off (§4.6, F4.27).** A server
  below the floor gets `PassthroughChannel`: one `tmux` on a pty with no `-CC`, painting itself into
  one `TerminalView`, with tmux's own status bar and prefix key doing the jobs tetmux normally does.
  Four things about it are load-bearing. **The version probe ends the channel** — `complete(.version)`
  hands over and *returns*, because applying the window-size, flow-control and subscription policies
  to a server that has none of those commands is what the old "banner and carry on" did. **Geometry
  inverts**: §3.3 gives tmux geometry because tmux is laying panes out and reporting where they went,
  and here the surface *is* the client's terminal, so `sizeChanged` is acted on rather than ignored
  and `TIOCSWINSZ` is the entire mechanism — two macOS windows take turns, last one winning, exactly
  as two tmux clients of different sizes do. **There is nothing to repaint from**, so the channel
  keeps a 128 KiB replay buffer and hands it to each new subscriber: without it a second window is a
  black rectangle nothing will ever fill, and one line drawn wrongly from a mid-stream start is the
  better failure. Output is bounded by dropping chunks for the same reason — `refresh-client -A` is
  tmux 3.2, so there is no pause to ask for, and it is the one place in the app where bytes are
  discarded without owing a repaint. And **the plain shell (R3.8's last row) is offered, never
  started**: nothing on a host with no tmux persists, so opening one unbidden would invent the only
  promise this mode cannot make. A host in the mode is `.degraded`, which is *active* — so
  `connectHost` stops the passthrough channel itself, or an explicit "try control mode again" would
  be refused by the idempotence guard and there would be no way back. A workspace entry naming such a
  host also has to *land* rather than stay pending: an unresolved restore re-asserts its host on every
  snapshot, and since a passthrough host never gains a session, clicking any other host in the tree
  was silently undone by the next topology change.
- **Discovery asks `tmux -C list-sessions` and attaches nothing (F4.4).** The list is not the point:
  clicking an unconnected host runs `new-session -A -s tetmux-main`, so a host with the user's own
  work on it got a second, empty session made before anyone saw what was there. A discovered session
  attaches *by name* with `attach-session`, which cannot create. Four things are load-bearing.
  **`tmux -C` reads commands until its input ends** — `tmux -C list-sessions` prints the answer and
  then hangs forever, so every caller gives it `/dev/null`; a probe that hangs is worse than none,
  because nothing is watching it. **The answer is `%begin`-framed and the failures are not**, which
  is what lets `ControlCodec` find the list under an ssh banner and what separates "this host has
  nothing" (tmux's own `no server running`) from "we could not ask" — hence
  `discoveredSessions` being an *optional*: recording an unreachable host as empty tells somebody
  their sessions are gone because their laptop is on a train. **It runs through `CommandProbe`, not
  `PtyTransport`**, because a pty is somewhere ssh can prompt; a pipe plus `BatchMode=yes` is the
  whole of "this cannot interrupt anybody", and the price is that a password host with no live
  `ControlMaster` answers nothing until it has been connected once. And **`browsableSessions` is the
  one place that decides which list a surface shows**, because the sidebar, the launcher and the menu
  bar all ask.
- **Copy mode is a small documented vocabulary, not an emulation of tmux's key table.** Menu items
  drive `send-keys -X <command>` — `-X` names the *action*, so it means the same thing whether the
  user's `mode-keys` is emacs or vi, which a key name would not. The pane keeps working the way it
  always did: a key typed into a pane in a mode still reaches tmux and is still looked up in the
  user's own table (`Up` moves the copy cursor), so this adds a way in and a way out to the Mac's
  pasteboard without taking anything away. Four things are load-bearing. **The mode has to be
  visible** — control mode is never streamed a mode's overlay, so the pane is holding a
  `capture-pane` still frame that looks exactly like a dead process; hence `TmuxPane.mode`, the
  status-bar label and the per-pane badge, all naming the mode rather than hinting at it, because the
  name is what tells somebody to press `q`. **`%pane-mode-changed` says only that something
  changed** — not which mode, not whether it was entered or left — so it schedules a `list-panes`,
  where `#{pane_mode}` lives (identical on 3.0 through 3.7b, so no version branch). **An action sent
  to a pane that is not in a mode is an `%error`**, and these are user commands, so §7 would put a
  banner in front of somebody whose pane merely left the mode before they clicked; every action is
  guarded on the flag, and Search is the deliberate exception — it *enters* copy mode itself, which
  is what makes searching tmux's history one action from a live shell and also closes the race where
  the flag has not arrived yet. And **copy has to come back**: `copy-selection-and-cancel` fills a
  buffer on the *server*, which on a remote host is a machine the pasteboard has never heard of, so
  `show-buffer` reads it straight back and `tetmuxCore` returns the string for the UI to set —
  §2.4 again. A refusal returns `nil` and the pasteboard is left alone, because replacing somebody's
  clipboard with an empty string over an empty selection is a silent loss.
- **Control mode only streams `%output` for the attached session.** Selecting another session must
  issue `switch-client`, or its panes render once from `capture-pane` and then sit frozen.
- **Nothing repaints on its own.** Attaching to an existing session shows an empty terminal until
  `capture-pane -p -e -J` runs; that is what `subscribeToPane` triggers on first subscription, and
  what `completeHandshakeIfNeeded` re-triggers for every already-subscribed pane on reattach (F4.16).
- **Closing a tab unlinks; it must never kill** (F4.9). `AppModel.closeWindow` counts the sessions
  the window is linked to and sends `unlink-window` when there is more than one, so the window leaves
  this session and carries on in the others. tmux cannot do that for a window in its *only* session —
  removing it there is destroying it, and `unlink-window` refuses outright with "window only linked
  to one session" — so that case is the single path that reaches `kill-window`, behind a confirmation
  that says why (F4.10, no "don't ask again" escape). Both halves have a regression test, including
  one asserting tmux still refuses; if that ever stops being true the confirmation can go.
  `%window-close` cannot distinguish the two, so it schedules a topology refresh rather than guessing.
- **A kill is not private, so the confirmation names who else is attached (F4.10).** `kill-session`
  ends the session for every client attached to it, and a window killed because it was in one session
  goes out from under all of them too — the dialog described the panes and never the people, so
  "close this stale-looking session" and "close the session a colleague is working in" read
  identically. `HostState.clients` is `list-clients` kept in the model, and the *absence* of others is
  stated just as plainly, since that is what makes the section trustworthy when it says otherwise.
  Three things about it. **The detach pass belongs to an attach and nothing else**:
  `Kind.listClients(reconcileStale:)` splits F4.17's orphan hunt from the plain re-read, or a refresh
  on every window rename would turn a known blast radius (two live tetmuxen detaching each other once)
  into a fight. **Our own channels are marked and excluded** — matched by tty against what each channel
  answered for `#{client_tty}`, the same "ours" F4.17 uses — or the dialog warns the user about
  themselves every time. And **tmux does not know where a client connected from**: there is no
  `client_host`, `#{host}` is the *server's* hostname, and an ssh origin never enters tmux's model, so
  a client is named by unix user, tty and terminal type and the sheet says so rather than letting
  `ada on /dev/ttys004` be read as a claim about which machine that is. Freshness is `%client-detached`
  and `%client-session-changed` (verified on 3.7b; `%client-detached` needs 3.2, so the topology
  refresh re-reads the list as well), plus one more read on the way to raising the sheet — which the
  sheet picks up because it reads the model rather than a snapshot. `client_user` is empty below 3.3
  and the row keeps its tty.
- **A linked window says so, because the link is what decides whether closing it is reversible.**
  `AppModel.closeOutcome` is the single decision and both the action and the tooltips ask it, so a
  control cannot promise something the click will not do. That matters most with ⌥ held, which skips
  the confirmation that would otherwise be the first time anyone is told this close is a kill. The
  marker is a badge — a drawn chain link and a count — on the tab and the tree, and the
  words are in `help` and the accessibility label, which names the other sessions rather than
  counting them ("also in beta" is checkable; "linked into 3 sessions" is a number to go and
  resolve). On a tab the words are the *whole* answer: the strip shows one session's windows, so
  there is no second tab the badge could point at. Nothing here is carried by hue, so
  `differentiateWithoutColor` needs no branch.
- **Hovering a linked row marks every row that window appears on, and it does so by accident of the
  key.** The sidebar's `key(_:_:)` is host + *window*, not host + session + window, so the same
  linked window in two sessions is one key — which is why both rows' close buttons have always
  appeared together. The hover wash makes that explicable instead of mysterious, and it is drawn only
  for a linked window: washing every hovered row would change how the whole tree behaves and would
  say nothing, since the point is that one window is highlighted in two places. Selection is
  deliberately *not* the channel — `isShowing` is session-qualified and means "this is what this
  macOS window is showing", so marking the twins with it would assert something false.
- **⌥ on a close or kill button skips the confirmation, and is read at click time.** The confirmation
  exists because the user cannot be assumed to know that closing the last link of a window ends what
  is running in it; holding ⌥ *is* saying so, which is what the modifier means on a destructive
  control elsewhere in macOS, and it is what makes closing a run of them one click each rather than
  two. It is not a "don't ask again": nothing is remembered, so the assertion is made again for the
  next window. The flags come from `OptionKey.isHeld` inside the action and never from a monitor —
  `ModifierKeyMonitor` and `OptionKeyMonitor` keep a *display* current and are allowed to be a frame
  behind, and a button whose behaviour disagreed with its own icon for one frame is the least
  explicable bug on this list. The two monitors are separate because their constraints are opposite:
  a window's events reach a local `.flagsChanged` monitor, and a menu's do not (it tracks events in a
  run loop of its own), which is why the menu bar polls instead.
- **A command the user asked for that fails has to say so** (§7). `%error` bodies used to reach only
  the diagnostic logger, which only `--diagnose` installs — in the app the command simply did not
  happen and nothing said why. `PendingCommand.Kind.userCommand(_:)` labels the ones a person
  initiated, and only those become `HostState.lastCommandFailure` and a banner. Internal commands
  keep `.ignore`: a `resize-window` an old server refuses is ours to cope with, not a sentence to put
  in front of somebody. An `%error` matching *no* pending command is still logged — the one case where
  something has already gone wrong is the worst one to stay silent about.
- **Everything that can hang has a bound, because the failure of an unbounded one is "Connecting…"
  forever.** A 45 s handshake watchdog covers a blocking MOTD or a hung `ProxyCommand`; without it a
  version probe that never answered also left `connection.version` nil, and `applyWindowSizePolicy`
  returned at its first guard so every resize was silently dropped for the life of the channel. The
  pre-handshake outbox caps at 256 commands and drops the *oldest* — the newest is what the user just
  typed. `sendAndAwait` times out at 2 s, and every path that could strand a waiter (write failure,
  `%error`, `teardown`) resumes it.
- **The outbox is bounded by age as well as by size, and the clock is `ContinuousClock`.** The size
  cap says how much may wait and nothing about how long, so a host that came back after ten minutes
  of outage still replayed the survivors in one burst — keystrokes typed at a shell that had long
  moved on, executed rather than read. Each queued command is stamped on enqueue and anything older
  than 10 s is dropped at flush, with the count logged. Never `Date`: this is the one code path that
  lives on the sleep/wake boundary, which is exactly where a wall clock jumps. The clock is injected
  through `SessionService(now:)` so a test can move it — waiting ten real seconds to assert a
  ten-second rule is a test nobody runs. There is deliberately no distinction between kinds of
  command: the age alone disqualifies.
- **The local host connects itself at launch; remote ones wait to be asked.** Not a general
  auto-connect policy. Local tmux is always reachable, needs no credentials and cannot prompt for
  anything, so the click was a step with no decision in it. A remote host connecting unbidden can
  raise a password sheet, and several of them at launch is worse than a click.
- **OSC 52 clipboard writes are denied by default and reads are never permitted** (T5.6).
  `allowRemoteClipboardWrite` is a `HostConfig` field, not a `TerminalTheme` one, and that is the
  point: trusting the machine on your desk to set your clipboard is a different decision from
  trusting a shared box you ssh into, and an application-wide flag makes both at once. It is passed
  down to the pane from the host rather than read from the theme, and a missing key in `hosts.json`
  means denied — so a file written before the field existed gets the safe answer.
- **Workspace restoration is `pendingRestore` on each window, not `@SceneStorage`.** What has to come
  back is a relationship between a macOS window and a tmux session, and that session does not exist
  until the host has connected and answered `list-sessions` — a round trip after the window is
  already on screen, which is exactly what scene storage cannot express. So `workspace.json` is read
  once at launch, each window holds its entry, and `reconcile` retries it on every snapshot. The
  entry carries **both** an id and a name because they answer different questions: `$3` is exact and
  is what a still-running server is still using (the common case — quitting tetmux does not stop
  tmux), while the name is what survives a server restart, where matching a reissued id would land
  on a stranger's session. There is no expiry — a window restored onto a remote host waits there
  until someone connects it — and only an explicit `select` cancels one. An *unresolved* restore is
  written back unchanged, or quitting before that host was ever reached would replace the session the
  user wants with whatever the reconciler picked. Restoration is resolved in `AppModel.apply` and not
  only in each window's `onChange`, because `syncDisplayedSessions` reads the selections in the same
  pass and a SwiftUI `onChange` is not guaranteed to have run by then: a restored session otherwise
  got no tmux client until something unrelated changed the topology, i.e. panes on screen and frozen.
- **The backoff is for a connection that dropped, not for one that never started.** Authentication
  failures are not retried, and neither is a connect the *user* asked for that never reached a
  handshake: it failed at something they are standing there to read — a wrong hostname, a refused
  port, a host that is off — and eight silent attempts over ninety seconds neither fix that nor say
  what it is. The reason goes on screen with the Retry beside it. What does back off (1 s → 60 s with
  jitter, circuit breaker after 8 — F4.14) is a channel that handshaked and then died, and a recovery
  attempt that fails before its handshake, which is the lid closing on a train: failing is the
  expected state for the next several attempts. `Connection.isRecoveryAttempt` is the difference.
  An explicit connect clears the breaker, because a click is the user asserting the host is reachable
  and a host that spent its attempts must still come back. A pending backoff is a *task*, and both `disconnectHost` and `reconnectNow` cancel it: a host
  the user deliberately closed used to reconnect a minute later, possibly raising a password prompt,
  because `.disconnected.isActive` is false and `connectHost`'s guard never saw it.
- **A reconnect reattaches to `reconnectTarget`, not to the session it first connected with.** It is
  tracked from `%session-changed`, so it follows `switch-client`. Reattaching to the original target
  strands the user on a session that gets no `%output` — the frozen-panes failure above, one layer up.
- **A dead channel is not noticed promptly.** ssh takes `ServerAliveInterval` × `CountMax` (~45 s) to
  turn a dead link into EOF, and until then writes into the pty still succeed — which is why
  `probeAllConnections` cannot detect a stale-but-`.connected` host by writing to it. `ConnectionBanner`
  exists because automatic recovery is best-effort: the panes stay on screen holding real scrollback,
  so the user needs to be told they are a snapshot and given a button. A 10 s `display-message -p ''`
  round trip is what the status bar's RTT dot reports (F4.29).
- **ssh prompts on a pty nobody is looking at.** `SshPromptDetector` watches the pre-handshake stream
  for a prompt ssh is *sitting* on — the signal is a trailing line with no newline after it, so a
  banner mentioning a password is correctly ignored. The prompt is published on
  `HostState.authenticationPrompt` (not folded into `ConnectionState`, which every UI switch would then
  have to grow a meaningless case for) and either filled from the Keychain or shown in a sheet.
  Fixtures are real captures from OpenSSH under a pty.

  **Four kinds, and the last two exist because "not classified" meant "hangs for 45 seconds".** A
  password and a key passphrase are answered as before. A **host key** is a first-contact question,
  and it is a *decision* rather than a text field: ssh's own lines are shown verbatim — the
  fingerprint is on a different line from the question, hence `promptContext` — with Cancel as the
  default button and no "always trust". That is not §2.3's forbidden auto-accept; §2.3 forbids the
  *application* accepting a key, and this puts ssh's question in front of the person who has to
  answer it. A key that *changed* cannot arrive here at all: ssh refuses that outright instead of
  asking. Everything else — a one-time code, a PAM challenge, something a `ProxyCommand` wants — is a
  **question**: shown verbatim, answered, never stored, never filled from the Keychain.

  Two details are load-bearing. The host-key line ends in **`? `, not a colon**, which is exactly why
  the old colon rule returned nil and the channel then sat until the handshake watchdog killed it.
  And an unclassified question is believed only after the stream has been quiet for 700 ms, because a
  read can land mid-line and make an ordinary banner look like ssh waiting on a prompt. One *secret*
  per channel still holds — a rejected password resubmitted is how accounts get locked out — but a
  host-key answer is not a secret, so "yes" followed by a password now works; a hard ceiling of three
  answers bounds the case where a question was classified wrongly.
- **Keychain access lives in `tetmuxUI`, not `tetmuxCore`.** `Security.framework` is as macOS-only as
  AppKit (§2.4). `SessionService` never reads a credential — it publishes the prompt and is handed an
  answer — so the platform boundary stays put. Calls run on a detached task: `SecItemCopyMatching` can
  put a dialog on screen (an unsigned dev build is asked every rebuild, because the ACL is tied to the
  code signature), which would beachball the main thread or stall every host behind the actor.
- **`ssh -G` is for showing, never for connecting (F4.2).** `resolveEffectiveConfig` answers what an
  alias means — hostname, user, port, jump — and the host editor uses it for its placeholders, so a
  blank User field says `deploy` rather than "optional" and the user can see what leaving it blank
  will do. What it must not do is feed those values back to `ssh`: the connection is made with the
  *name*, so ssh applies its own file and every `Match` block resolves against the real invocation.
  Resolving here and passing the pieces explicitly would be re-deciding what ssh has already decided.
  The map keeps a repeated key's **first** value, ssh's own precedence for scalar options — and some
  keys are genuinely multi-valued and cannot be read out of it at all: `identityfile` lists every
  default when none was set, so a last-wins map named whichever default came last as though it were a
  choice. It runs debounced from `.task(id:)`, because a subprocess per keystroke is what the naive
  version costs.
- **The ssh escape hatch is split, not shell-quoted.** A host can carry extra `ssh` options typed as
  they would be on a command line, plus `-X` behind a checkbox. `TmuxCommand.splitArguments` splits
  them the way a shell would — quotes group, backslash escapes — and then they go straight to `execve`:
  no expansion, no substitution, no shell, unlike `customCommand` which really is handed to `/bin/sh`.
  They are placed **before** tetmux's own `-o` options, and that ordering is the point: ssh resolves
  each parameter to the *first* value it obtains, so options appended after ours would be accepted and
  silently ignored.
- **A start directory and an initial command are properties of the host, not questions at creation
  time.** `new-session` takes `-c` and a trailing `shell-command`, and both are fed from `HostConfig`
  rather than from a dialog: New Session deliberately puts nothing between wanting a shell and having
  one, which is why it has no name prompt either. tmux resolves both on its own side, so `~`, a
  directory that only exists remotely, and `srun --pty bash` all work — and that is also why there is
  no folder picker, which could only ever browse this machine. Both go through
  `TmuxCommand.singleLine` as well as `quote`, like every other user value: the fields take pasted
  text, and a line break ends the command before the closing quote and hands tmux the remainder to
  run. **The command goes last**, after every option — tmux stops reading flags at the first word
  that is not one, so a `-c` written after it is not an option at all and the directory silently does
  nothing. It is quoted whole rather than split, because the far-side shell is what parses it. A
  command that exits takes its window and then its session with it; that is `new-session <command>`
  for anybody, and `remain-on-exit` is an option on the user's server rather than ours to set.
- **The local host is persisted only as the difference from a baseline, and its editor is a different
  editor.** `HostConfigStore.localBaseline` is what "localhost, unedited" means; `saveHosts` keeps
  the `local` entry only when it differs, which is the same rule discovered `ssh-` hosts already had
  and for the same reason — its *existence* is not a stored fact. `loadHosts` takes only the fields
  that mean something without a connection (start directory, clipboard policy) and never the whole
  record, so a hand-edited `hosts.json` cannot flip `isLocal` or rename the host out of the places
  that look it up. `HostEditorView` branches on `isLocal` rather than disabling fields: hostname,
  user, port, password, tunnels and ssh options are all properties of a connection it does not make,
  and a form four-fifths greyed out is a worse answer than a form with two rows in it.
- **Tunnels are connection options, not a managed feature.** §1.2 rules out a port-forward management
  UI, and there isn't one: forwards are `-L`/`-R`/`-D` arguments that live and die with the channel.
  Incomplete rows are dropped rather than passed to ssh (a malformed `-L` makes ssh exit before tmux
  starts), and `ExitOnForwardFailure` is deliberately left at ssh's default — a taken local port must
  not kill the session. ssh's complaint lands in the pre-handshake transcript.
- **One tmux client per session on screen, and the extra ones are not the connection.** `%output`
  arrives only for the session a client is attached to, and a client has exactly one session — so with
  a single channel per host, every window on a second session was a `capture-pane` still frame, and the
  only cure (`switch-client`) moved the freeze to the other window rather than removing it. So a host
  has a **primary** channel and any number of **followers**: `connections[hostId]` is the primary and
  `followerChannels[hostId][sessionId]` is one client per additionally-displayed session.
  `setDisplayedSessions` is the only input — `AppModel` recomputes it from every open window's
  selection — and `reconcileChannels` makes reality match it.

  The two kinds are deliberately not symmetrical, and treating a follower as a connection is the way to
  break this. The primary *is* the host: its state is the host's `connectionState`, its `%exit` is the
  server ending, its prompt is the authentication sheet, it owns the reconnect backoff and circuit
  breaker, and every command anyone issues goes down it. A follower does exactly one thing, which is to
  make one more session's panes move; it raises no prompt, changes no connection state, and when it
  dies it says only that one session stopped streaming — there is no backoff, because the usual reason
  a follower dies is that its session did. Sharing is by session and not by window: two windows on one
  session are two views of one client, since a second client there would stream the same panes twice.

  The primary is *moved* rather than duplicated when its own session leaves the screen: it has to be
  attached to something, and `switch-client` only strands panes when somebody is watching them, which
  is precisely the case `reconcileChannels` checks before doing it. Retiring a follower is a
  check-then-act across an `await`, so it re-checks after the wait: tabbing away and back inside the
  grace period otherwise tore down the client the reconcile had just decided to keep, and nothing was
  scheduled to notice.
- **A pane belongs to one channel, or it is painted twice.** A window can be linked into several
  sessions (F4.9's subject), and every attached client streams `%output` for every pane it can see —
  verified on 3.7b by attaching two control clients to two sessions sharing a window: both emit the
  same `%output %p` line. Two copies fed to one emulator is a corrupted screen, which is worse than the
  frozen one this whole mechanism exists to fix. `paneOwners` is first-come ownership by channel epoch;
  everyone else's bytes for that pane are dropped, and when the owner goes away the pane is released
  *and repainted*, because whoever picks it up has been having its bytes discarded and is mid-stream on
  a screen it never drew. `refresh-client -A` (the pause) has to go to the owning client too — asking
  the primary to pause a pane it is not streaming does nothing at all, silently.
- **`HostState.liveSessionIds` is what tetmux is attached to, and it counts channels that are still
  connecting.** `TmuxSession.isAttached` is tmux's own client count and includes terminals elsewhere on
  the machine, so it cannot answer "are these panes live?". Liveness deliberately includes a follower
  that is still handshaking and a `switch-client` that has not landed (`Connection.pendingSessionId`):
  attaching is a round trip, and the strictly honest answer for its duration makes `NotAttachedBanner`
  appear for a tenth of a second and withdraw, which reads as a glitch rather than as information. A
  *failed* `switch-client` must clear `pendingSessionId`, or a dead session reports live forever and
  the banner never appears over a window that has stopped moving.
- **Stale tetmux clients are detached on attach (F4.17), and the tag is `client_control_mode`.** The
  SRD asks for a distinctive client name; tmux has none to give — `client_name` *is* the tty and there
  is no command to set it (verified on 3.7b). So an orphan is "a control-mode client whose tty is not
  one of ours", which means the handshake must learn its own `#{client_tty}` *before* the
  `list-clients` response arrives — the two are issued in that order deliberately, and the FIFO is what
  makes it work. The whole pass is skipped if any channel of the host has not yet answered its tty
  query, because a handshaking follower is indistinguishable from an orphan. Ordinary `tmux attach`
  terminals are never candidates. Known blast radius: two live tetmuxen against one server (a
  `swift run` beside an installed build) detach each other, as would iTerm2's tmux integration.
- **Pane commands are subscribed to on tmux ≥ 3.2 and polled below it.** `refresh-client -B
  tetmuxPaneCommand:%*:"#{pane_current_command}"` is what reports a command started in a *background*
  pane — nothing announces `pane_current_command` otherwise, it arrives only with a `list-panes`, and
  the refreshes that trigger one fire on renames and pane switches. So `schedulePaneRefresh` on
  `%window-renamed` and `%window-pane-changed` is the fallback path, not the mechanism. Subscriptions
  are issued on the **primary only**: they are per client but the values are server-wide, so a follower
  subscribing multiplies identical notifications.
- **A tab's terminal views are never rebuilt, so a bell has to reach the app, not the view.** Panes
  beep through `NSSound.beep()`, and when the app is not frontmost `BellNotifier` also posts a
  `UserNotifications` banner (F4.31), coalesced to one per 10 s with an "and N more" body — `yes | ring`
  would otherwise bury Notification Center. Authorisation is asked for on the first bell rather than at
  launch, and a refusal is not retried. `UNUserNotificationCenter.current()` **traps** in a process with
  no bundle identifier, which is exactly `swift run tetmux`, hence the availability guard.
- **Activity notifications are opt-in per window; the bell is not, and the asymmetry is the point.**
  A bell is a program deliberately asking for attention. Activity is only "output arrived in a window
  nobody is reading", which for most windows is a prompt redrawing — reported for every window it
  would be constant and worthless, and reported for the one running a long remote job that prints and
  never rings it is the whole feature. So `AppModel.watchedWindows` is a set of host-qualified window
  ids (tmux numbers windows per server, so `@1` exists on every host at once), toggled from the one
  place both the tab menu and the tree menu already share — `WindowSessionMenus`, which keeps the two
  from drifting without needing a `RowSubject` case of its own. Watches are §4.3 view state, so they
  persist in `workspace.json`, which grew an **envelope** (`{windows, watchedWindows}`) around what
  used to be a bare array; `WorkspaceStore.decode` still reads the old shape, because discarding
  somebody's window arrangement is a poor way to introduce a feature. `AppModel.newlyActive` is
  static and pure because it is the half that is silently wrong: `hasActivity` stays true until the
  window is read, so reporting the *value* rather than the *transition* would re-fire on every
  topology snapshot for the rest of the afternoon — and a window seen for the first time has no
  previous value, so attaching to a server whose watched window is already active is deliberately not
  an event. `NotificationPolicy` is the on/off pair, in `UserDefaults` beside the theme; it is
  mirrored onto `BellNotifier.shared` because a pane surface has no `AppModel` to ask.
- **A colour scheme is pane *content* only, and System is the absence of one.** §7 keeps the chrome
  compositing from `controlAccentColor` and hierarchical styles so it follows the system appearance;
  a tab bar that changed colour with the terminal scheme would be an application pretending to be a
  terminal. Four things are load-bearing. The **System scheme carries no palette** — it calls
  `configureNativeColors`, which reads `NSColor.textColor`/`.textBackgroundColor` and therefore
  follows light and dark *while the app runs*; copying today's values into fixed ones would look
  right until the user switched appearance. **`installColors` goes first**, because it resets the
  view's 256-entry colour cache and setting the foreground and background before it would have them
  thrown away — and it is guarded on an actual change (`Coordinator.appliedSchemeId`), since a
  repaint of every pane on every `%layout-change` is what an unguarded version costs. **The pane
  tree's background follows the scheme too**: an unfocused pane is dimmed with `opacity`, so whatever
  is behind it is what it fades toward, and a dark scheme fading toward the system's white is a grey
  wash nobody chose (`ContrastPolicy`'s exemption still applies on top — at increased contrast the
  dimming stops entirely). And **§4.6's passthrough surface takes the scheme as well**, because it is
  one tmux client painting itself and a fallback in different colours would look like somebody else's
  application. The theme stores the scheme's *id*, not the scheme: an unknown id falls back to
  System, which is what a downgrade or a hand-edited preference produces.
- **The terminal's appearance is one `TerminalTheme` in `UserDefaults`, and changing it costs a round
  trip per pane.** The `Settings` scene sets font family, size, ligatures (T5.8) and scrollback; the
  theme lives on `AppModel` with a `didSet` that persists it, and reaches panes as a value passed down
  the view tree. Font changes are not free: the cell size derives from the font and the grid derives
  from the cell size, so every pane on screen re-measures and re-asks tmux. Scrollback is applied to
  live panes with `changeScrollback` rather than only at creation — SwiftTerm's default is 500 lines,
  which is not a choice anyone made.
- **The pane's mouse behaviour is an `NSView` subclass, and its Paste is never SwiftTerm's.**
  `PaneTerminalView` overrides `menu(for:)` and `otherMouseDown` because a SwiftUI gesture over a
  `TerminalView` never sees an event — the same reason `PaneDivider` is an `NSView`. Three things
  there are load-bearing. The link under the click is captured when the menu is *built*, not when an
  item fires: the pointer has moved and the pane may have scrolled by then, so re-deriving it opens
  whatever is there now. The cell size for hit-testing comes from `getOptimalFrameSize() / grid`,
  which is SwiftTerm's own `cellDimension` read back — mirroring the font arithmetic instead means
  resolving the backing scale factor exactly as SwiftTerm does, and getting that wrong moves the cell
  by a whole point and the hit column by several. And both the menu's Paste and middle-click go
  through `SessionService.paste`: SwiftTerm's `paste(_:)` inserts the clipboard as *keystrokes*, one
  `send-keys` per character, which is the path that wedges the channel and cannot carry a newline
  safely. `allowsContextMenuPlugIns = false` keeps AppKit from adding AutoFill and Look Up, which it
  offers because the view takes text input and which mean nothing over a remote pane.
- **A pane's accessibility value is the viewport, not the scrollback.** SwiftTerm's accessibility
  service is an empty stub, so `PaneTerminalView` supplies the value itself, bounded by the grid — a
  screen reader query must not cost more because a pane is holding a large history, and "read the
  window" means the screen in any case. Not done: nothing posts `.valueChanged`, so output arriving
  while VoiceOver is idle goes unannounced. Doing it right means diffing for new lines; re-reading
  the whole screen on every chunk of a build log is worse than silence.
- **Plain-text URLs are SwiftTerm's implicit matcher, not ours.** `linkReporting` defaults to
  `.implicit` and `linkHighlightMode` to `.hoverWithModifier`, so ⌘-click already activates a URL
  with no OSC 8 around it and arrives at `requestOpenLink` as a string. Nothing in tetmux would
  notice if a SwiftTerm bump turned that off, hence `PaneLinkTests`. Both routes are held to one
  scheme allowlist — `http`, `https`, `mailto`, `ftp` — because pane contents are remote text and
  `NSWorkspace.open` launches whatever application claimed a scheme.
- **There are two searches, over two different bodies of text.** ⌘F is SwiftTerm's find bar and
  searches what the *emulator* is holding — the local scrollback, capped by the theme and reset by
  every repaint. ⌃⌘F is tmux's, and reaches the history the emulator never received, which is the
  whole reason copy mode exists. Two controls that look different, deliberately: a sheet rather than
  a bar, and one shot rather than incremental, because each keystroke of an incremental field would
  be a `search-backward` that moves the copy cursor — the history would walk backwards while somebody
  typed.
- **⌘F is SwiftTerm's find bar, reached through `performTextFinderAction`.** It works only because the
  Paste command replaces the `.pasteboard` menu group and *not* `.textEditing` — replacing the latter
  wholesale is what unplugged Find in the first place, since AppKit puts Find in that group.
- **There is one kind of window.** "Open in New Window" opens an ordinary window seeded to a session
  with the sidebar collapsed, not the separate `DetachedScene` type it used to — that had its own view,
  a reduced feature set, and a button to convert itself into a real window, three things to maintain
  for a result that wanted to be a normal window all along.
- **The keymap has exactly one event monitor, and it exists because the ordinary route cannot be
escaped.** Every binding is a SwiftUI `keyboardShortcut` on a menu item, which AppKit resolves in
`performKeyEquivalent` before any view is offered the event — so no view-level hook could ever let
⌘K through to a pane running fzf. `KeyEventMonitor` is a local `NSEvent` monitor, which runs earlier
still (`NSApplication.sendEvent` calls monitors before dispatching key equivalents), and F4.21's
armed chord is delivered to the pane's `keyDown` **directly** rather than passed on: passing it on
hands it straight back to the menu, which is the interception being escaped. It asks
`KeymapPolicy.shortcut(for:literalEscapeActive:)` rather than matching anything itself, so F4.22's
single policy module survives the new surface. New key handling belongs in the policy, not here.

**A rebind must have ⌘ in it, and a taken chord is refused rather than resolved.** The whole default
set lives in `Cmd` space so that everything else reaches the pane untouched — that is the entire
content of F4.20's promise about `Ctrl+K` — so `KeymapPolicy.isBindable` rejects anything without
⌘, in the recorder and again when a hand-edited `settings.json` is applied. Two commands on one
chord is not resolvable either: `shortcut(for:)` breaks the tie by the enum case's spelling, so one
of them silently stops working. The chord recorder answers **`performKeyEquivalent`**, not
`keyDown`, or the menu takes every ⌘ chord before the field sees it. And `KeymapPolicy.overrides`
builds its map with `updateValue`: assigning `nil` through a `[String: String?]` subscript *removes*
the key, which would make a deliberately unbound shortcut indistinguishable from an untouched one
and bring its default back on the next launch.

**A key with no glyph is named, not uppercased.** `KeyBinding` holds a `Character`, and rendering it
by uppercasing gave the space key a chord ending in nothing and an arrow key a private-use codepoint
the font draws as a box — both of which are recordable today, so both were reachable. `namedKeys`
maps them to what macOS calls them: the word for space (System Settings shows Spotlight as
`⌘Space`) and the symbol for the rest, the way the menus do. The *storage* name is separate and is
for `settings.json`, which §2.3 chose so the file can be read by hand — `ctrl+cmd+space` says what it
means and a literal trailing space would not survive anyone looking at it. Names and one-character
keys cannot collide, because every name is longer than one character. What the table cannot vouch
for is that the chord still *matches*, so that has its own test: `charactersIgnoringModifiers` for
⌃⌘Space really is `" "`, which is the character the binding holds.

**Anything that belongs to a window lives on `WindowState`, not `AppModel`.** Selection, focused
  pane, and every sheet the user can raise are per macOS window. Sharing them on the model produced two
  bugs with one cause: clicking a session in one window retargeted all of them, and one
  `.sheet(item:)` bound to shared state opened the same dialog once per open window. `RootView` owns one per window; the
  since-deleted detached window had a hand-rolled version of exactly these fields first, and
  `WindowState` is that generalised so the main window stopped being the special case. A `WindowGroup`
  could always open several windows — shared state was the only thing that made doing so useless.
- **Menu commands act on `AppModel.activeScope`, not on any one window's selection.** Menus are
  application-wide, so ⌘T with any window in front must open a tmux window in *that* window's session.
  Every window publishes its scope via `focus(_:)` when it becomes key, main windows included; there is
  no privileged window to fall back to now that there can be several. `activeScope` is never cleared,
  because a menu can be used while no window is key and the last one to have focus beats nothing.
  `activeWindowState` is the companion for commands that open a *sheet* rather than act — it says
  where to ask — and is weak, so a closed window is not kept alive by having once been key.
- **A sheet nobody asked for is presented by exactly one window.** ssh prompts arrive from the channel
  and belong to a host, not a window, so `presentsHostLevelSheets` picks the head of `windowOrder` and
  the others bind `.constant(nil)`. Registration order rather than focus, so the choice does not move
  mid-typing; closing that window promotes the next, because nothing able to show a prompt means a host
  stuck at "Connecting…" forever.
- **⌘N is a macOS window and ⌘T is a tmux window.** ⌘N used to be the tmux one, which is what it means
  in no other application. The tmux item is titled "New tmux Window" rather than "New Tab"
  even though tmux windows are shown as tabs: AppKit manages menu items titled exactly "New Tab" and
  "Close Tab" itself under automatic window tabbing, and a custom item competing for those names is at
  its mercy. `NewAppWindowButton` exists because `openWindow` is an `@Environment` action and
  `Commands` has no environment to read one from. ⌥⌘W closes a pane and ⇧⌘W a tmux window, kept a
  modifier apart from ⌘W's macOS window on purpose given the blast radii; ⌥⌘[ / ⌥⌘] move between panes
  in the **rendered** tree, so zoom is respected.
- **A dropped tab lands on the side the drag came from, and the marker has to agree.** The rule every
  tab bar has is that the dragged tab takes the target's position and everything between shifts by
  one — so a rightward drag inserts *after* the target and a leftward one *before* it.
  `AppModel.dropDestination` is that arithmetic, static and pure because it is the part that can be
  wrong with nothing to say so: get it backwards and a drag by one position does nothing at all.
  `isTargeted` reports only that *something* is over a tab, never what, so the strip shares a
  `draggingWindowId` — otherwise the insertion rule would be drawn on the leading edge always and
  would lie for every rightward drag. The payload is plain text rather than a declared `UTType`
  because an exported type needs an `Info.plist` to be declared in and `swift run` has no bundle;
  every drop is checked against the session's own window ids, so a stray text drag matches nothing.
- **A window can be asked for but not opened, and not addressed either.** `AppModel.requestedWindow`
  records the request and any open window performs it — via `claimWindowRequest()`, because *every*
  window observes it and a plain nil check on the delivered value opens one window per window already
  on screen. What the new window should show travels separately through `consumeSeed()`, taken once by
  the next window to appear: `WindowGroup(id:for:)` would key windows on that value and bring the
  existing one forward instead of making a second, which is right for "show me this session" and wrong
  for ⌘N. And SwiftUI cannot bring a *particular* window forward at all, so `WindowAccessor` captures
  each window's `NSWindow` — that is the only way `showSession` can raise the right one.
- **The Dock menu is three items, and two of them are the point.** It is the app's only surface while
  it has no window and is not frontmost, and it used to offer New Window alone — which reconciles to
  the first host's *active* session and window, i.e. very often the window already on screen, so the
  one thing the Dock could do was make a second view of what you were already looking at. **New
  Window** now seeds `sidebar: .shown`: someone reaching for the Dock has nothing in front of them
  and needs a window to navigate *from*, and `.automatic` is AppKit deciding rather than an
  instruction. **New Local Session** and **New Remote Session ▸ host** create a session and open a
  window onto it with the tree collapsed. Neither can simply open a window — control mode's
  `new-session` answers with no id, so the window can only be opened once the topology says what it
  should show, which is exactly what `RevealRequest` exists for; they go through
  `createSessionWithDefaultName(preferNewWindow:)` like the menu bar's ⌥. The menu is rebuilt on
  every click because AppKit asks each time and the host list is live. An item with nothing to act on
  gets `action: nil` rather than `isEnabled = false` — the menu auto-enables, so a cleared flag is
  overwritten at display time while an item with no action is greyed out for us.
- **With every window closed there is nobody to claim a request, so the model performs it itself.**
  `requestedWindow` is only ever observed from inside a window, and the app deliberately outlives its
  last one (`applicationShouldTerminateAfterLastWindowClosed` is `false`, because the menu bar extra
  is the point of staying resident) — so picking a session from the tray did nothing at all, ⌥ or no
  ⌥, and left the request set for the next ⌘N to inherit. `AppModel.openAppWindow` is an
  `OpenWindowAction` handed over by a view, since only a view can read one; it stays valid after that
  view is gone because it resolves against the scene graph. `openWindow(_:)` uses it only when
  `openWindows` is empty — calling it while a window is watching would honour the request twice. The
  menu bar re-adopts it on every use, being the one view still around when the last window closes,
  and the Dock menu (AppKit's, built outside any scene) reaches it through the app delegate. **New
  Session** with nothing open needs the same treatment one layer up: `createSession` queues a reveal
  that *opens* a window rather than none at all, or tmux gets a session nobody is ever shown.
- **Staying resident means ⌘Q is the ordinary way out, and it must undo what a disconnect undoes.**
  `window-size manual` is set on the user's sessions; the delegate used to implement only
  `applicationShouldTerminateAfterLastWindowClosed`, so quitting left every session no longer following
  its terminal for the next plain `tmux attach` to find.
- **Showing a session prefers the window already showing it.** `showSession` tries, in order: the
  window already displaying that session (brought forward), then a new window if asked for one, then
  the offered fallback — the clicked window for a sidebar double-click, the last-used one for the menu
  bar extra — then a new window because nothing was open. Retargeting some other window to a session
  that is already on screen both surprises the user and discards what that window was showing.
- **The launcher's list is ranked by use, and the key is what makes that safe.** F4.25's recency is
  an *order* in `workspace.json` — most recent first, capped at 50 — rather than timestamps, because
  ranking needs to know which came first and nothing else, and a wall clock in a file that outlives
  sleep and a timezone change buys nothing. A `RecentTarget` is host-qualified for the usual reason
  (tmux numbers per server, so `@1` is on every host at once), and it keys a **session by name and a
  window by id**, which is not an inconsistency: a session found by discovery has no id at all — the
  probe answers names — while a window's *name* is whatever is running in it whenever
  `automatic-rename` is on. Both go stale on a server restart, and that is accepted here where it
  would not be in `WorkspaceWindow`: a stale entry costs one row its place in a list, not a window
  its session. Uses are recorded in `select` — every deliberate navigation, not only the launcher's
  own rows, or the thing you left thirty seconds ago by any other route sits at the bottom — and
  deliberately **not** in `connect`, which the local host calls on itself at launch. Once a query is
  typed the fuzzy score decides and recency is only the tie-break, which has to be written out:
  `sorted(by:)` is not stable, so equal scores are otherwise not merely unranked but unrepeatable.
- **…and its window row on an unreachable host connects first, through `pendingRestore`.** That row
  has always been subtitled "(will connect)" and always called a plain `select`, which connects
  nothing — the one row whose words and click disagreed. The selection cannot be made at the click:
  the window is a fact from the last time that host answered and there is no channel to select it
  on. So `showWhenAvailable` parks the target and `connect` runs, and the ordinary restore path
  lands it. Two things there are load-bearing. It is **not** a `RevealRequest`, which expires after
  15 s — the handshake watchdog allows 45 — so a slow ssh would drop the pick silently; `pendingRestore`
  has no expiry for exactly this reason, and resolves by id and then by name, which is the right rule
  for a topology as old as the disconnection. And it connects **targetlessly** rather than attaching
  by the remembered session name the way `attachDiscoveredSession` does: that name may be gone, and
  `attach-session -t <gone>` is `%error`, `%exit`, which the exit handler reads as "this server has
  nothing left" and leaves the host disconnected saying nothing. The row's mark is
  `LauncherItem.connectsFirst`, which used to be `isAvailable` and did not mean this — it was set on
  window rows alone, so the recession excused a row that did not work rather than stating a fact
  about the host, while a session row on the same host was drawn at full strength and did connect.
- **…and picking one opens the tree onto it**, through `sessionsToExpand`, which is the same channel
  a session created from the sidebar already used. A launcher result is reached without touching the
  tree, so without this the row highlights inside a collapsed session — the selection invisible in
  the one view whose job is to show it. It is deliberately *not* gated on the sidebar being open:
  the flag is consumed whenever the tree next runs, so a collapsed one simply finds the session
  already open when it is shown. When the pick had to connect first the expansion has to wait with
  it, because the session id the row was built from is from before the disconnection and a restarted
  server has reissued it — hence `expandWhenRestored`, which is keyed by *window* and lives on
  `AppModel` rather than beside the target: `pendingRestore` is written to `workspace.json` verbatim,
  and the workspace restore that shares that field must not expand anything, or every launch would
  open a node per restored window.
- **A window's label is its name only when the user chose it.** `#{automatic-rename}` is how tmux says
  which: `1` while it is naming the window after the running command, `0` once someone has renamed it.
  There is no `#{window_...}` variable for this — the option name itself is the format. Otherwise the
  label is what is *running*, and for a split window that means every pane, because tmux's automatic
  name follows whichever pane is current: a split window's label changed as the user moved between
  panes, and two split windows read identically whenever their active panes matched. `displayLabel`
  lives on `TmuxWindow` so the sidebar and the tab cannot disagree about what a window is called.
- **Creating something shows it, and that takes a round trip.** Control mode's `new-session` and
  `new-window` answer with no id, so the thing created is not selectable until the topology refresh
  brings it back. `AppModel` records the intent and satisfies it on the next snapshot — a session by
  *name*, since tmux allocates the `$id`, and a window by *not having been there before*, since
  selecting whichever window tmux made active would hand the selection to a window opened elsewhere in
  the meantime. Requests hold the asking window weakly and expire after 15 s: one kept indefinitely
  would eventually match an unrelated session of the same name and move somebody's window. ⌥ on the
  menu bar's **New Session** means what ⌥ means on a session row — a window of its own — and has to
  travel the same way rather than opening one at the click: there is no id to seed a window with until
  tmux answers. So the reveal request carries the intent, opens the window when the session arrives,
  and is the one kind of reveal that does *not* need the asking window to still be there.
- **Topology refreshes and pane refreshes are different commands and need different task slots.**
  Sharing one meant a `%window-add` arriving just after a `%window-renamed` ran only `list-panes`, so a
  window created elsewhere kept its placeholder name and wrong session until something unrelated
  refreshed. Automatic renames fire constantly, so this was hit often.
- **The menu bar extra says what ⌥ would do, by polling.** `MenuBarExtra` hands its content no event
  and SwiftUI has no `isAlternate`, so the items' icons are swapped by hand while ⌥ is down —
  otherwise the modifier is invisible until after the click that used it. It cannot be watched with an
  event monitor: a menu tracks events in a run loop of its own where a local monitor sees nothing, and
  a global monitor for a keyboard event needs Accessibility, which this app needs for nothing else.
  `OptionKeyMonitor` therefore reads the hardware flags on a `Timer` added to the **common** run-loop
  modes — the default mode never fires during menu tracking — and only between `NSMenu`'s
  begin/end-tracking notifications, so nothing wakes up while no menu is open. The *action* still
  reads `NSEvent.modifierFlags` at click time; a 20 Hz poll is for display and can be a frame behind.
- **Nothing switches sessions on focus any more.** `AppModel.focus` used to call `switchSession` so
  the window you clicked into became the live one; with a client per displayed session there is nothing
  to move, and moving it would freeze the window you just left. Focus now only republishes scope and
  re-runs `syncDisplayedSessions`. That call is made from everywhere the answer can change — focus,
  `select`, a window registering or unregistering, and every topology snapshot, since a session put on
  screen before tmux has named it cannot be attached to by id until the snapshot arrives.
- **tmux ids collide across hosts.** Sessions and windows are numbered per *server*, so `$0` and `@1`
  exist on every host at once — and that is the common case, not the odd one, because the ordinary way
  to reach a second host is to ssh into it and its tmux starts numbering from zero exactly like the
  first. Anything keyed on a tmux id alone therefore has to carry the host too: `WindowState.isShowing`
  for row selection, and the sidebar's `key(_:_:)` for hover. Without it a window row lit up on every
  connected host simultaneously. The commands behind the row buttons were always host-qualified and
  were never affected; only the display was.
- **Network *switches* never report `.unsatisfied`.** `NetworkStateMonitor` compares
  `path.availableInterfaces` as well as the satisfied flag; watching only the flag misses Wi-Fi to a
  different Wi-Fi, which is exactly when a host that was unreachable becomes reachable again.
- **Reduce Motion is honoured at all three animation sites** — the launcher's scroll, the tab strip's
  scroll-to-selection, and the sidebar's row-action reveal — each keeping the outcome and dropping the
  movement. New animation belongs behind the same check.
- **Increase Contrast is `ContrastPolicy`, and new sites ask it rather than deciding for themselves.**
  Views read `@Environment(\.colorSchemeContrast)` and pass it in; the alternative is a
  `contrast == .increased ? a : b` at a dozen sites with a dozen sets of numbers, drifting until a
  selected row and a selected tab disagree about how selected they look. Every rule is the same kind
  of rule — a signal carried by a faint wash becomes one carried by an obvious one — so nothing
  changes shape, appears, or moves: the user asked to see the application, not for a different one.
  The one that is not simple amplification is the pane: an unfocused pane stops being dimmed *at
  all*, because dimming a pane is dimming terminal text, and the frame around the focused one takes
  over the job at full accent saturation and double the width. The tests assert **direction**, not
  numbers — the failure they exist to catch is a later site that takes the standard value in both
  branches, which leaves the preference switched on and doing nothing.
- **`differentiateWithoutColor` has no policy type, deliberately.** Unlike contrast there are no
  shared numbers to keep in step — the replacement channel is necessarily different at every site, a
  word here and a filled chip there — so each site reads
  `@Environment(\.accessibilityDifferentiateWithoutColor)` and answers for itself. Three sites, and
  the interesting part is which ones needed anything. The **RTT dot** did: the number beside it is
  the measurement and the hue is the judgement, so with colour gone "120 ms" answers nothing unless
  you know the thresholds; it gains `· good`/`· fair`/`· slow`, which is the same answer the sidebar
  already gives in words one panel up. The **⌥-armed close buttons** did: red is the entire content
  of "this click will not stop to ask". The sidebar's **connection rail** did *not* — `hostStatusLabel`
  already puts every state but `.connected` into words on the row the rail belongs to, and
  `.connected` is the one with no label, so the states are already distinct without hue. Checking
  that rather than decorating it is the point. One measured trap: doubling the armed glyph's rule
  takes an 11×11 mark from 45 inked pixels to 65 offscreen and **still does not read** on a row where
  it is drawn in `.secondary`, so the signal is a filled chip behind the button and the weight is
  only its companion.

## Measuring (§6)

Verification is **local and scripted, not CI** — the SRD's decision (§6, §8), on the same argument
the fixture matrix rests on: a hosted runner measures the runner. `docs/measurements.md` holds the
numbers with the machine beside each, and is written to rather than edited, because the point of the
table is the trend. Three things about the harness are worth knowing before extending it.

**A perf harness measures itself first, and the wrong answer looks exactly like a finding.** P6.3's
first run read 23 MB/s in release — half the floor, a plausible number with a plausible story. It
was the test: it sliced the fixture at its first `%output`, so the repeated body carried no
handshake, and `ControlCodec` skips everything before the first `%begin` with a substring search
that allocates at every position. A startup path the app runs a handful of lines through, run over
every line forever. Handshake once then output repeated, and the same bytes measured 396 MB/s. The
fully-decoded assertion beside the rate is the standing guard against the other direction: a parser
that is fast because it is dropping the payload measures wonderfully.

**A floor has to name its build.** A debug build of the codec is **17× slower** than the release one
— no optimisation, retain/release around every array, bounds checks on every subscript. So
`CodecThroughputTests` asserts P6.3's real 50 MB/s only when built release, and 5 MB/s in debug as an
order-of-magnitude tripwire that survives a slow runner while still catching the complexity class of
mistake above (which measured 2 MB/s in debug against 18 for the same bytes). Anything quoting a
debug number as a performance figure is quoting the wrong program.

**P6.1's two ends are in code we do not own, and neither could be an override.** SwiftTerm declares
`TerminalView.keyDown` and `draw` `public` rather than `open`, which closes both to a subclass in
another module. The keystroke end moved to `KeyEventMonitor` — a local `NSEvent` monitor runs before
`sendEvent` dispatches, so it is *earlier* than `keyDown` and is the honest start. The draw end has
no such hook, so `LatencyProbe` closes the interval from a 1×1 overlay **subview** of the pane,
marked dirty when the echo lands: AppKit draws a view's own content before its subviews, so the
overlay's `draw` runs in the same cycle, after the terminal has painted. `viewWillDraw` on the pane
was the alternative and would understate every sample by one full-screen draw. What is still outside
the interval is the window server and the display — unreachable from the process, so every P6.1
figure understates by up to a frame and the record says so.

The probe is off unless asked (`TETMUX_MEASURE_LATENCY`, or a live signpost trace), which is what
keeps the byte scan for the echo off the path P6.3 is a promise about. And `measure-latency.sh` runs
the app with `HOME` and `TMUX_TMPDIR` pointed at a scratch directory, so it gets a private tmux
server, an empty host list and its own workspace file — a measurement that typed into the user's
real session and rewrote their window arrangement would be worse than no measurement.

## Testing

`SessionIntegrationTests` drives a **real PTY against the real tmux server** on the machine. It
creates and kills its own uniquely-named sessions, and skips entirely when tmux is absent. It also
spawns a dozen children concurrently on purpose — that is the fork-safety regression, and it fails
as a hang rather than an assertion. CI installs tmux and fails if that skip fires: a skipped test is
indistinguishable from a passing one in a green check.

**There are two test targets, split along AppKit.** `tetmuxCoreTests` depends on `tetmuxCore` alone
and holds everything that replays a fixture or exercises a pure value type — the codec, the matrix and
its `Fixtures/`, the layout parser, the prompt detector, `TmuxCommand`, `HostModel`. That target is
the entire reason the Linux job can run a test rather than only a build (see above), so **anything
added there must not reach for AppKit, SwiftTerm or a live tmux server**; those belong in
`tetmuxTests`, which links `tetmuxUI`. `AppModelTests` covers the decisions that need no channel and
no window — the F4.9 close decision, scope resolution, keymap matching, tab-drop arithmetic, workspace
resolution, F4.31's activity transition — which were previously unreachable rather than untested.

**An `AppModel` in a test must be given a directory.** It writes files as a side effect of ordinary
operations: rebinding a chord persists `settings.json`, and selecting a session or registering a
window schedules a `workspace.json` save. A default-constructed one in a test therefore writes the
*user's* files, and did — running the app after the suite found `testOnlyEditedBindingsAreStored`'s
keymap in it. Hence `AppModel(directory:)` and the per-test temporary directory in `setUpWithError`.

**A test that needs a resource the machine may not have skips; it does not fail.** `setUp` skips the
whole suite when tmux is absent, and the `ControlMaster` scenario skips unless `TETMUX_SSH_HOST` names
a host ssh can reach **without a password** (`BatchMode=yes` is the check — a host that would prompt
is no use to a suite nobody is watching). Written with `XCTUnwrap` instead of `XCTSkip` it goes red on
every machine but one, which is how it was written the first time. A test against somebody's real
machine also has to leave nothing behind: only sockets that appeared during the run are removed, the
remote session is uniquely named and killed, and the `ControlPersist` master is closed with
`-O exit` **at tetmux's own control path** — ssh finds a master by path, so the default one exits zero
having done nothing and leaves a live connection open.

**Killing a channel is asynchronous, so a test has to watch the state *leave* `.connected` before
waiting for it to come back.** `SIGKILL` returns the moment the signal is delivered; the pty EOF that
turns a dead process into a dead channel arrives later. A test that kills and then waits for
`.connected` matches the *stale* value instantly, and everything it does next happens in the window
between teardown and the next spawn — where `connections[hostId]` is nil, `sendKeys` drops the
keystroke, and the evidence reads exactly like a session that reconnects and then ignores its
keyboard. That cost an evening and produced a TODO entry about a bug that did not exist. The dropped
keystroke is correct behaviour, incidentally, and consistent with the outbox's age limit: keys typed
at a host with no channel are not worth replaying.

**A test's deadline has to be inside the work, not wrapped around it.** Pane output is read by
`collect(_:until:seconds:)`, which starts reading before the keystrokes that produce the output and
stops on the marker *or* on a deadline of its own. It replaced a `withTimeout` helper that raced an
arbitrary operation against a sleep in a task group — which cannot bound work it does not own. Its
callers all passed `{ await someTask.value }`, and awaiting an **unstructured** task's value is not
cancellable: when a marker never arrived, the timeout fired, `cancelAll()` could not stop that child,
and the group's teardown waited on it for ever. Every bound in the test was bypassed by the mechanism
meant to enforce them, and the suite stalled with no assertion, no output and no test name — which is
the worst failure mode a test can have. Both of `collect`'s children are structured, so cancellation
reaches them (`for await` on an `AsyncStream` returns nil, `Task.sleep` throws). It returns what
arrived rather than throwing, so a missed marker **fails with the output it did get** instead of
skipping — a skip being exactly as green as a pass.

Flow-control decisions are asserted through the **diagnostic logger**, not `HostState`: pausing a pane
is a property of the channel and deliberately invisible to the model, so `LogSink` is the only seam
there is. The stalled-viewer test never reads its stream, on purpose — reading it would make the test
measure nothing.

Protocol tests replay byte streams captured verbatim from tmux 3.7b. When fixing a protocol bug, add
the real captured bytes rather than a hand-written approximation.

**The R3.6 matrix is real now, and it is a local recording rather than a CI job.**
`Scripts/build-tmux-matrix.sh` builds tmux 3.0/3.2a/3.3a/3.4/3.5 from pinned, checksummed tarballs
into a gitignored `.tmux-matrix/`; `Scripts/capture-fixtures.py` drives each under a pty and writes
`Tests/tetmuxCoreTests/Fixtures/tmux-<version>.<scenario>.stream`; `ControlCodecMatrixTests` replays
them. Capture must **not** move into CI: a fixture's value is that it is a frozen record, so a
regression shows as the parser disagreeing with it — regenerate it each run and the test asserts
"the parser agrees with whatever tmux just said", which is true by construction. The inputs are
pinned releases, so a rebuild is byte-identical forever. The scripts exist for *provenance*: without
them the fixtures are one person's word about what they once saw.

**…and the integration suite runs across it too, which is a different property.** The fixtures pin
what each version *says*; `Scripts/test-matrix.sh` pins what tetmux *does* about it. It is a CI job
(`matrix` in `ci.yml`) rather than a per-push one: **weekly, plus `workflow_dispatch`, plus a `v*`
tag** — press the button after touching a version-conditional path. Not on pushes or pull requests,
because building tmux from a pinned tarball is minutes of `./configure && make`; `actions/cache`,
keyed per version, pays that once. The tag is the exception because a tag is the only event that
produces something a user installs, and a tag can be cut from a commit the cron has never swept — so
that is where R3.6's compatibility claim stops being a note and becomes a promise, and where the
matrix blocks the release rather than going red beside a published one. Two costs are accepted with
it: a 7-day cache eviction against a 7-day cron means a tag build usually rebuilds all five from
source, and a tarball fetch is now a network dependency in the release path.

**The CI job is a `strategy.matrix`, one parallel runner per version, and the script is still the
single implementation** — it takes a version list, and each job passes it one. Sequential is right on
a laptop, where five versions share one build of the test bundle; in CI it turns five ~90-second runs
into one eight-minute job with a single pass/fail at the end. Split, the wall clock is the slowest
version rather than the sum, each version has its own cache entry and its own line in the checks
list, and `fail-fast: false` means a 3.0 regression does not cancel the other four — which version
disagrees is the whole information the matrix exists to produce. It costs more machine-minutes than
it saves in wall clock, deliberately: the value of on-demand is an answer while you are still looking
at it.

**And "no tests ran" is never a pass.** `swift test` writes its summary two ways — `Executed 60
tests, with 0 failures`, and once anything skips, `Executed 60 tests, with 2 tests skipped and 0
failures` — so the script takes the count on its own rather than matching the sentence. Matching the
sentence is what it did first, and the day a test started skipping it printed "no tests ran" with a
tick beside it. A run that reports no count, or a count of zero, now fails: exit status zero having
run nothing is the same green-check-that-means-nothing this whole area exists to prevent. It is where the version branches live — per-window sizing off below 2.9, tab reordering as `move-window -b` on
3.2 and a run of `swap-window`s below it, pane commands subscribed on 3.2 and polled below, no flow
control at all before 3.2. `PtyTransport.resolveTmux` reads `TETMUX_TMUX` to pick the binary, and it
is **local-only by design**: a remote host runs whatever its own login shell finds, so a path on this
machine would name a binary that is not there. A named binary that cannot be executed returns `nil`
rather than falling back to `PATH`, because a typo that quietly used the system tmux would report
five passes for one version.

Most of the value needed no new tests: several already assert an *outcome* and take whichever branch
the server supports, so the same assertions under 3.0 are the only thing that has ever executed the
`swap-window` fallback end to end. What it did need was **isolation**, and finding that out was the
first thing the matrix did. Every test now gets a tmux server of its own (`TMUX_TMPDIR` per test,
`kill-server` in `tearDown`), because sharing the machine's server had been hiding two real defects:
a test that probed an untouched host and asserted a non-empty answer, which is true only on a machine
that already has sessions; and leaked clients — a `SessionService` that is never disconnected leaves
a live `tmux -CC` attached — accumulating until the run wedged, after which every remaining test
timed out at fifteen seconds saying nothing about why. Anything that stands in for a *remote* host
with a shell script has to put the matrix binary on its own `PATH` (`matrixPathExport`): those
scripts share this machine's `TMUX_TMPDIR`, so a stand-in running the system tmux starts a server of
the wrong version on the socket every later test is using, and a tmux client cannot speak to a server
of another version.

Three things keep a capture a record of a **version** rather than of a machine, and each was a real
leak before it was fixed: `-f /dev/null` so nobody's `~/.tmux.conf` gets in; every pane running
`cat` so a fixture holds protocol instead of somebody's shell prompt; each binary installed as plain
`tmux` in a directory of its own, because tmux names a window after the command running in it and a
binary called `tmux-3.5` puts `%window-renamed @0 tmux-3.5` in the stream. Automatic rename is off
by default in the preamble for the same reason — one 3.0 capture came back naming a window
`kernel_task`.

Assertions are about **structure, not bytes**: captures carry wall-clock timestamps and server-wide
command numbers, so two recordings of one version are never identical and a golden file would fail
for reasons nobody can act on. What is pinned is that the same actions build the same model on every
version, plus the protocol facts the code branches on. `SshPromptDetectorTests` follows the
same rule with OpenSSH: its fixtures were captured by driving `ssh` and `ssh-keygen` under `pty.fork`,
and the details a plausible-looking fake gets wrong (the leading `\r`, the trailing space, the absent
newline) are exactly the ones detection depends on.

The password path is covered end to end without a password-accepting host: `writeFakePasswordSshScript`
stands in for ssh — it prompts on the pty, reads one line, and only then execs the tmux command it was
handed, so the real detect → publish → answer → handshake sequence runs against local tmux.

Everything is captured from one tmux version, so the version-conditional paths self-skip rather than
run on the versions they exist for; `TerminalGeometryTests` covers the scroller gutter and the
font-derived cell round trip but is not the geometry suite §8 asks for. Both gaps are in `TODO.md`
rather than fixed.

## State on disk

- `~/Library/Application Support/tetmux/hosts.json` — host list. A decode failure renames the file to
  `hosts.json.corrupt-<timestamp>` and surfaces `loadFailure` rather than returning an empty list:
  both halves used to be `try?`, so a mangled file silently became "no hosts" and the first edit wrote
  one host over the rest. An empty file is explicitly not corruption.
- Hosts discovered from `~/.ssh/config` keep their `ssh-` ids and are re-derived each launch, so an
  unedited one is deliberately **not** persisted — a stale entry would outlive the stanza. An *edited*
  one is persisted as the difference from what discovery produces, and only while its `Host` block
  still exists. Before that, a forward or ssh option added to a discovered host worked all session and
  vanished on relaunch, while the Keychain flag it wrote survived and the two then disagreed.
- `~/Library/Application Support/tetmux/workspace.json` — `windows`, one entry per macOS window: host,
  session (id *and* name), tmux window, whether the tree was showing, and the frame; plus
  `watchedWindows`, F4.31's watches, and `recents`, F4.25's ranking — both of which belong to no
  window and so had nowhere else to go. §4.3's
  view state and nothing else — tmux is the persistence layer for everything in a pane. Written
  debounced, on window close, and synchronously from `applicationShouldTerminate`, which is the usual
  way this app is closed. An empty window list is never written: the app outlives its last window, so
  closing them all and quitting from the menu bar would otherwise erase a workspace nobody meant to
  discard. The file used to be the bare array of windows and is still read in that shape.
- `~/Library/Application Support/tetmux/settings.json` — the keymap, as the difference from the
  defaults. A `null` is a shortcut deliberately unbound. The terminal's *appearance* deliberately
  stays in `UserDefaults` below: font and scrollback are ordinary application preferences the system
  already has a place for, while a keymap is a document somebody may want to read, diff, or copy to
  another Mac — which is §2.3's whole argument for JSON.
- `~/Library/Preferences` (`UserDefaults`) — `terminal.fontName`, `fontSize`, `ligatures`,
  `scrollbackLines`, `colorScheme`, and F4.31's `notifications.bells` / `notifications.activity`. Preferences the
  system already has a place for; the *watches* those last two govern are view state and live in
  `workspace.json`.
- `~/Library/Caches/tetmux/cm-%C` — ssh `ControlMaster` socket. Kept short on purpose: unix socket
  paths cap at 104 bytes and Application Support plus ssh's 40-char hash runs close to it.
- Login Keychain — per-host passwords, opt-in, as `kSecClassInternetPassword` with protocol ssh keyed
  by server/account/port. `hosts.json` records only *that* a password is expected, never the password;
  `HostConfigStoreTests` asserts no new secret-shaped field appears in it. Removing a host, or turning
  storage off in the editor, deletes the item — an orphaned credential the user believes they deleted
  is worse than none.

ssh remains responsible for authentication: keys are tried first and the Keychain only answers a prompt
that ssh actually raised. Key passphrases are never stored per host — they belong to the key, and
ssh-agent already handles them.
