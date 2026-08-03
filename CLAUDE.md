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
```

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
tetmuxUI    SwiftUI/AppKit chrome; SwiftTerm pane surfaces        (@MainActor)
tetmuxCore  SessionService (actor) · ControlCodec · LayoutParser · PtyTransport
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

**tmux owns geometry (§3.3).** Views measure themselves, ask via `refresh-client -C`, and then lay
out whatever `%layout-change` returns. Nothing resizes a surface before tmux confirms. Pane surfaces
are snapped to the cell size tmux reported; letting the emulator pick its own drifts by a cell and
desynchronises the grid.

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

## Protocol gotchas

`ControlCodec` is a pure value type: `mutating func feed(_:) -> [ControlEvent]`, no I/O, no async.
Keep it that way — it is the only reason the protocol layer is testable against fixtures.

- `%layout-change @w <layout> <visible-layout> <flags>` — **three** fields since tmux 2.5. Folding
  them into one string makes the layout unparseable and the window renders nothing.
- `%extended-output %p <age> : <data>` — the colon is a reserved field and must be skipped.
- `%output` payloads are octal-escaped and arbitrary binary. Decode on bytes, never via `String`.
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
- **Closing a tab must never kill** (F4.9), and destructive actions are confirmed with no
  "don't ask again" escape (F4.10).
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
- **Network *switches* never report `.unsatisfied`.** `NetworkStateMonitor` compares
  `path.availableInterfaces` as well as the satisfied flag; watching only the flag misses Wi-Fi to a
  different Wi-Fi, which is exactly when a host that was unreachable becomes reachable again.

## Testing

`SessionIntegrationTests` drives a **real PTY against the real tmux server** on the machine. It
creates and kills its own uniquely-named sessions, and skips entirely when tmux is absent. It also
spawns a dozen children concurrently on purpose — that is the fork-safety regression, and it fails
as a hang rather than an assertion.

Protocol tests replay byte streams captured verbatim from tmux 3.7b. When fixing a protocol bug, add
the real captured bytes rather than a hand-written approximation.

## State on disk

- `~/Library/Application Support/tetmux/hosts.json` — host list. Entries with `ssh-` ids are
  rediscovered from `~/.ssh/config` each launch and deliberately not persisted.
- `~/Library/Caches/tetmux/cm-%C` — ssh `ControlMaster` socket. Kept short on purpose: unix socket
  paths cap at 104 bytes and Application Support plus ssh's 40-char hash runs close to it.

Credentials are never stored; authentication is entirely ssh's responsibility.
