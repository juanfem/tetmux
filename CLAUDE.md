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
disconnect.

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
- **A command the user asked for that fails has to say so** (§7). `%error` bodies used to reach only
  the diagnostic logger, which only `--diagnose` installs — in the app the command simply did not
  happen and nothing said why. `PendingCommand.Kind.userCommand(_:)` labels the ones a person
  initiated, and only those become `HostState.lastCommandFailure` and a banner. Internal commands
  keep `.ignore`: a `resize-window` an old server refuses is ours to cope with, not a sentence to put
  in front of somebody.
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
- **Tunnels are connection options, not a managed feature.** §1.2 rules out a port-forward management
  UI, and there isn't one: forwards are `-L`/`-R`/`-D` arguments that live and die with the channel.
  Incomplete rows are dropped rather than passed to ssh (a malformed `-L` makes ssh exit before tmux
  starts), and `ExitOnForwardFailure` is deliberately left at ssh's default — a taken local port must
  not kill the session. ssh's complaint lands in the pre-handshake transcript.
- **A detached window shares the host's channel (F4.12, option B).** Tearing off a tmux *window* is
  fully live, because `%output` arrives for every pane of the attached session. A detached *session*
  cannot be: control mode streams output for one session per client, so a window showing any other
  session renders one `capture-pane` snapshot, says so, and offers "Attach Here" — which necessarily
  freezes the previously attached session's windows. Making two sessions of one host live at once needs
  a second channel, i.e. re-keying `connections`, `outputSubscribers`, `reconnectTarget`, and
  `reconnectAttempts` from `hostId` to `(hostId, session)`. That is deliberately not done.
- **Menu commands act on `AppModel.activeScope`, not the sidebar selection.** Menus are
  application-wide, so ⌘T with a torn-off window in front must open a window in *that* window's session.
  A detached window sets `frontmostScope` while it is key; the main window clears it. Detached windows
  also keep their own `focusedPaneId`, selection, and sheet state — sharing the model's would move each
  other's keyboard focus, and a sheet bound to shared state presents itself in every open window at
  once.
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
