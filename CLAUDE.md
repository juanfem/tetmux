# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`tetmux` is a native macOS **tmux client**, not a terminal emulator that runs tmux. It speaks tmux
control mode (`tmux -CC`) and renders the resulting model natively: tmux windows become app tabs,
tmux panes become app splits. tmux's own status bar, pane borders, and window list are never shown.

`tmux-manager-srd.md` is the design baseline. It is specific and worth consulting before changing
behaviour — requirement IDs (`R3.4`, `F4.17`, `T5.6`, `P6.3`) are cited throughout the source, and
those citations are the fastest way to find the rationale for code that looks odd.

## Commands

```bash
swift build
swift run tetmux                       # launch the GUI

# Tests need Xcode's toolchain: XCTest is absent from CommandLineTools,
# which is what `xcode-select -p` points at on this machine.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter testLayoutChangeSeparatesItsThreeFields
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SessionIntegrationTests

Scripts/package-dmg.sh                 # .app bundle inside a .dmg, in dist/
Scripts/package-dmg.sh --skip-build    # …from whatever is already in .build/release
```

`.github/workflows/ci.yml` runs the same two things on every push: `swift test` with tmux installed
(otherwise the integration suite silently skips itself and a green check means nothing), then the
packaging script, whose result is mounted and launched before it is uploaded. A `v*` tag also
publishes the image as a release.

The .dmg is **single-architecture** and says so in its filename. A universal binary needs SwiftPM's
`--arch arm64 --arch x86_64`, which routes through xcbuild, which compiles SwiftTerm's Metal shaders
and so needs a Metal toolchain component that is a separate multi-gigabyte download. The native path
copies the `.metal` source into the resource bundle and never invokes the compiler.

### The diagnostic CLI

```bash
swift run tetmux --diagnose                    # local tmux
swift run tetmux --diagnose server.example.org   # a saved host, by id or name
```

Connects a real channel, prints the parsed event stream to stderr and the resulting topology to
stdout, then subscribes to a pane and round-trips a keystroke. **Reach for this first when a host
misbehaves** — it separates "the protocol layer is wrong" from "the views are wrong", which is
otherwise slow to establish. It resolves against the saved host list, so it exercises the exact
user, port, and custom command the UI would use.

To ground a protocol question in reality, capture a live stream rather than reasoning about it:
drive `tmux -CC` under a PTY (Python's `pty.fork` is the quickest way) and read the raw bytes.
Several fixtures in `ControlCodecTests` were produced exactly that way.

## Architecture

Four layers. Everything below the UI is plain Swift with no AppKit dependency.

```
tetmux      app entry point + --diagnose CLI
tetmuxUI    SwiftUI/AppKit chrome; SwiftTerm pane surfaces; KeychainStore   (@MainActor)
tetmuxCore  SessionService (actor) · ControlCodec · LayoutParser · PtyTransport · SshPromptDetector
```

**`tetmuxCore` must not import AppKit, SwiftUI, or SwiftTerm.** That is the §2.4 portability hedge,
and its immediate payoff is that the interesting logic stays headlessly testable. `NetworkStateMonitor`
lives in `tetmuxUI` precisely because it needs `NSWorkspace`.

### The central abstraction

Everything reduces to a **control-mode channel**: a bidirectional byte stream speaking the tmux
control protocol. Local and remote differ *only* in which process `PtyTransport` spawns:

| | Spawned process |
|---|---|
| Local | `tmux -CC -2 -u new-session -A -s <name>` |
| Remote | `ssh … -tt <host> -- <one argv element that execs tmux -CC>` |

There is no "remote code path". If you find yourself adding a remote branch above `PtyTransport`,
the design has gone wrong.

## Invariants that are easy to violate

These are the ones that produce silent, hard-to-diagnose breakage. Each has a regression test.

**Identifiers carry their tmux sigil.** `@3`, `%7`, `$1` — everywhere, from codec to view. Stripping
and re-adding sigils per layer was a recurring source of lookups that silently matched nothing.

**tmux command numbers are server-wide and start at an arbitrary value.** They are not 0-based and
cannot be predicted. Responses *are* strictly ordered, so `SessionService` correlates them with a
FIFO of pending commands. tmux also emits one `%begin`/`%end` block of its own on attach, before we
can write anything; commands therefore queue in an outbox until that handshake completes. Writing
earlier misaligns the queue by one for the life of the channel.

**State broadcasts are for topology changes only.** `SessionService.ingest` diffs `HostState` and
broadcasts only when it actually changed. Broadcasting on `%output` rebuilds the SwiftUI tree for
every chunk of terminal output, tearing down the very terminal views the output is painting into.

**tmux owns geometry (§3.3).** Views measure themselves, ask, and then lay out whatever
`%layout-change` returns. Nothing resizes a surface before tmux confirms. Pane surfaces are snapped to
the cell size tmux reported; letting the emulator pick its own drifts by a cell and desynchronises the
grid.

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
disconnect that hangs is worse than an option left set.

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
paused never moves again. Anything lost is repaired by a repaint, never handed to the emulator as a
hole in the byte stream. All of it needs tmux 3.2; below that the byte ceiling is the whole mechanism.

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

**Pane surfaces need explicit `.id(paneId)`.** The layout tree is rendered through `AnyView`, which
erases structural identity, so without an explicit id SwiftUI rebuilds every `NSView` on each update
and discards the terminal's contents.

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

Two consequences that are easy to miss. **Unlinking a window can destroy its session**: a session left
with no windows is destroyed by tmux, so closing the last tab of a multi-linked window ends that
session and moves the client elsewhere — `testUnlinkingAWindowLeavesItRunningInItsOtherSession` asserts
the window left the session *or* the session went with it. And **a test that waits on a model
predicate must fail, not skip**: `waitForHost` throws `XCTSkip` on timeout, which is exactly as green
as a pass, so anything asserting the absence of this bug uses `waitFor` plus an explicit assertion.

## Protocol gotchas

`ControlCodec` is a pure value type: `mutating func feed(_:) -> [ControlEvent]`, no I/O, no async.
Keep it that way — it is the only reason the protocol layer is testable against fixtures.

- `%layout-change @w <layout> <visible-layout> <flags>` — **three** fields since tmux 2.5. Folding
  them into one string makes the layout unparseable and the window renders nothing.
- `%extended-output %p <age> : <data>` — the colon is a reserved field and must be skipped.
- `%output` payloads are octal-escaped and arbitrary binary. Decode on bytes, never via `String`.
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

## Behaviour worth knowing before changing it

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
  in front of somebody.
- **The local host connects itself at launch; remote ones wait to be asked.** Not a general
  auto-connect policy. Local tmux is always reachable, needs no credentials and cannot prompt for
  anything, so the click was a step with no decision in it. A remote host connecting unbidden can
  raise a password sheet, and several of them at launch is worse than a click.
- **OSC 52 clipboard writes are denied by default and reads are never permitted** (T5.6).
- Authentication failures are not retried; other disconnects back off 1 s → 60 s with jitter and a
  circuit breaker after 8 attempts (F4.14). An explicit reconnect — `reconnectNow`, behind the
  banner button, the sidebar row, and the placeholder's Retry — clears that breaker, because a click
  is the user asserting the host is reachable and a host that spent its attempts must still come
  back.
- **A reconnect reattaches to `reconnectTarget`, not to the session it first connected with.** It is
  tracked from `%session-changed`, so it follows `switch-client`. Reattaching to the original target
  strands the user on a session that gets no `%output` — the frozen-panes failure above, one layer up.
- **A dead channel is not noticed promptly.** ssh takes `ServerAliveInterval` × `CountMax` (~45 s) to
  turn a dead link into EOF, and until then writes into the pty still succeed — which is why
  `probeAllConnections` cannot detect a stale-but-`.connected` host by writing to it. `ConnectionBanner`
  exists because automatic recovery is best-effort: the panes stay on screen holding real scrollback,
  so the user needs to be told they are a snapshot and given a button.
- **ssh prompts on a pty nobody is looking at.** `SshPromptDetector` watches the pre-handshake stream
  for a prompt ssh is *sitting* on — the signal is a line ending in a colon with no newline after it, so
  a banner mentioning a password is correctly ignored. The prompt is published on
  `HostState.authenticationPrompt` (not folded into `ConnectionState`, which every UI switch would then
  have to grow a meaningless case for) and either filled from the Keychain or shown in a sheet. Host-key
  confirmations and second factors are deliberately *not* classified: §2.3 forbids auto-accepting a key,
  and an account password is not a passcode. Fixtures are real captures from OpenSSH under a pty.
- **Keychain access lives in `tetmuxUI`, not `tetmuxCore`.** `Security.framework` is as macOS-only as
  AppKit (§2.4). `SessionService` never reads a credential — it publishes the prompt and is handed an
  answer — so the platform boundary stays put. Calls run on a detached task: `SecItemCopyMatching` can
  put a dialog on screen (an unsigned dev build is asked every rebuild, because the ACL is tied to the
  code signature), which would beachball the main thread or stall every host behind the actor.
- **The ssh escape hatch is split, not shell-quoted.** A host can carry extra `ssh` options typed as
  they would be on a command line, plus `-X` behind a checkbox. `TmuxCommand.splitArguments` splits
  them the way a shell would — quotes group, backslash escapes — and then they go straight to `execve`:
  no expansion, no substitution, no shell, unlike `customCommand` which really is handed to `/bin/sh`.
  They are placed **before** tetmux's own `-o` options, and that ordering is the point: ssh resolves
  each parameter to the *first* value it obtains, so options appended after ours would be accepted and
  silently ignored.
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
  is precisely the case `reconcileChannels` checks before doing it.
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
  appear for a tenth of a second and withdraw, which reads as a glitch rather than as information.
- **There is one kind of window.** "Open in New Window" opens an ordinary window seeded to a session
  with the sidebar collapsed, not the separate `DetachedScene` type it used to — that had its own view,
  a reduced feature set, and a button to convert itself into a real window, three things to maintain
  for a result that wanted to be a normal window all along.
- **Anything that belongs to a window lives on `WindowState`, not `AppModel`.** Selection, focused
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
  in no other application (item 11). The tmux item is titled "New tmux Window" rather than "New Tab"
  even though tmux windows are shown as tabs: AppKit manages menu items titled exactly "New Tab" and
  "Close Tab" itself under automatic window tabbing, and a custom item competing for those names is at
  its mercy. `NewAppWindowButton` exists because `openWindow` is an `@Environment` action and
  `Commands` has no environment to read one from.
- **A window can be asked for but not opened, and not addressed either.** `AppModel.requestedWindow`
  records the request and any open window performs it — via `claimWindowRequest()`, because *every*
  window observes it and a plain nil check on the delivered value opens one window per window already
  on screen. What the new window should show travels separately through `consumeSeed()`, taken once by
  the next window to appear: `WindowGroup(id:for:)` would key windows on that value and bring the
  existing one forward instead of making a second, which is right for "show me this session" and wrong
  for ⌘N. And SwiftUI cannot bring a *particular* window forward at all, so `WindowAccessor` captures
  each window's `NSWindow` — that is the only way items 5 and 9 can raise the right one.
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
- **Showing a session prefers the window already showing it.** `showSession` tries, in order: the
  window already displaying that session (brought forward), then a new window if asked for one, then
  the offered fallback — the clicked window for a sidebar double-click, the last-used one for the menu
  bar extra — then a new window because nothing was open. Retargeting some other window to a session
  that is already on screen both surprises the user and discards what that window was showing.
- **A window's label is its name only when the user chose it.** `#{automatic-rename}` is how tmux says
  which: `1` while it is naming the window after the running command, `0` once someone has renamed it.
  There is no `#{window_...}` variable for this — the option name itself is the format. Otherwise the
  label is what is *running*, and for a split window that means every pane, because tmux's automatic
  name follows whichever pane is current: a split window's label changed as the user moved between
  panes, and two split windows read identically whenever their active panes matched. `displayLabel`
  lives on `TmuxWindow` so the sidebar and the tab cannot disagree about what a window is called.
- **Nothing announces `pane_current_command`.** It only arrives with a `list-panes`, and topology
  refreshes fire on structural changes — so pane-derived labels sat stale until something unrelated
  happened to refresh them. `schedulePaneRefresh` runs on `%window-renamed` (an automatic rename *is*
  tmux reporting that the foreground command changed) and on `%window-pane-changed` (a command started
  in a pane that was not current renames nothing). A background pane changing command while nobody
  switches or renames is still not reported; there is no notification for it.
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

## Testing

`SessionIntegrationTests` drives a **real PTY against the real tmux server** on the machine. It
creates and kills its own uniquely-named sessions, and skips entirely when tmux is absent. It also
spawns a dozen children concurrently on purpose — that is the fork-safety regression, and it fails
as a hang rather than an assertion. CI installs tmux and fails if that skip fires: a skipped test is
indistinguishable from a passing one in a green check.

The test target links `tetmuxUI` as well as `tetmuxCore`. `AppModelTests` covers the decisions that
need no channel and no window — the F4.9 close decision, scope resolution, keymap matching — which
were previously unreachable rather than untested.

Flow-control decisions are asserted through the **diagnostic logger**, not `HostState`: pausing a pane
is a property of the channel and deliberately invisible to the model, so `LogSink` is the only seam
there is. The stalled-viewer test never reads its stream, on purpose — reading it would make the test
measure nothing.

Protocol tests replay byte streams captured verbatim from tmux 3.7b. When fixing a protocol bug, add
the real captured bytes rather than a hand-written approximation. `SshPromptDetectorTests` follows the
same rule with OpenSSH: its fixtures were captured by driving `ssh` and `ssh-keygen` under `pty.fork`,
and the details a plausible-looking fake gets wrong (the leading `\r`, the trailing space, the absent
newline) are exactly the ones detection depends on.

The password path is covered end to end without a password-accepting host: `writeFakePasswordSshScript`
stands in for ssh — it prompts on the pty, reads one line, and only then execs the tmux command it was
handed, so the real detect → publish → answer → handshake sequence runs against local tmux.

## State on disk

- `~/Library/Application Support/tetmux/hosts.json` — host list. Entries with `ssh-` ids are
  rediscovered from `~/.ssh/config` each launch and deliberately not persisted.
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
