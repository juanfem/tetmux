# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this
repository. It is the orientation; the depth lives in `docs/`, and the index below says which file
to read before touching what. Those files are records of real failures and the rules they taught,
not general advice — **read the relevant one before changing behaviour in its area**, and when
finished work leaves a lesson, append it there rather than here. Entries are bold-titled paragraphs
stating the rule, the failure that taught it, and which parts are load-bearing; keep that shape.

## What this is

`tetmux` is a native macOS **tmux client**, not a terminal emulator that runs tmux. It speaks tmux
control mode (`tmux -CC`) and renders the resulting model natively: tmux windows become app tabs,
tmux panes become app splits. tmux's own status bar, pane borders, and window list are never shown.

`tetmux-srd.md` is the requirements baseline (v2.1, amended against the implementation). It is
specific and worth consulting before changing behaviour — requirement IDs (`R3.4`, `F4.17`, `T5.6`,
`P6.3`) are cited throughout the source, and those citations are the fastest way to find the
rationale for code that looks odd. Existing IDs are frozen: amendments change their text, never
their number.

`TODO.md` holds what is **open**, and what is **parked** (`[~]` — could be done, deliberately is
not), each entry with the evidence and instructions concrete enough to start from. It does *not*
record what closed: finished work leaves as an invariant in these docs, an amended requirement in
the SRD, or a row in `docs/measurements.md`, next to the thing it constrains. Check it before
concluding something is a new bug; anything the SRD asks for that the tree does not do belongs
there, because an unlisted requirement reads as done.

## The guidance index

| File | Read before |
|---|---|
| `docs/invariants.md` | Changing almost anything. The catalogue of invariants whose violation is silent breakage: command correlation and framing, geometry and the cell size, SwiftUI pane identity and focus, quoting, fork safety, reconnect and `%exit` semantics. Each has a regression test. |
| `docs/protocol.md` | Touching `ControlCodec`, `LayoutParser`, or anything that parses the control-mode wire. |
| `docs/behavior.md` | Changing user-facing behaviour. One entry per feature: passthrough, discovery, copy mode, primary/follower channels, pane ownership, close/kill semantics, menus, sidebar, launcher, notifications, colour schemes, workspace restore, the keymap. |
| `docs/testing.md` | Writing or debugging tests, or quoting a performance number. §6's measurement discipline (the numbers themselves live in `docs/measurements.md`), the two test targets, the tmux version matrix, fixture capture, isolation traps. |
| `docs/build-and-release.md` | Touching CI, packaging, the .dmg, or `Package.swift`'s platform conditionals. |
| `docs/state-on-disk.md` | Changing what is persisted: `hosts.json`, `workspace.json`, `settings.json`, `UserDefaults`, the Keychain. |

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

Scripts/measure-latency.sh             # P6.1 keypress→glyph p95, and the panel's measured rate
Scripts/measure-throughput.sh          # P6.3 %output parse rate, release build
Scripts/measure-launch.sh 5 --untraced # P6.7 exec→first frame with no tracer in the number
Scripts/measure-idle.md                # P6.6/P6.7 by hand — the procedure, not a program

Scripts/capture-programs.py            # §8's program corpus: vim/htop/less/top/powerline, and the
                                       # grid tmux renders from each. By hand, never in CI.
Scripts/capture-throughput.py          # the %output fixture measure-throughput.sh replays

Scripts/build-tmux-matrix.sh           # tmux 3.0/3.2a/3.3a/3.4/3.5 from pinned tarballs
Scripts/test-matrix.sh                 # the integration suite against every one of them
Scripts/test-matrix.sh 3.0 --filter testDraggingATabReordersTheSession
```

Run the suite as `env -u TMUX swift test` when working from inside a tmux pane — a leaked `$TMUX`
inverts the per-test server isolation and `tearDown`'s `kill-server` then names your own server
(`docs/testing.md` has the details).

The CI job shapes, the arm64-only .dmg, the macOS 26 SDK assertion, and ad-hoc signing are all
deliberate decisions with recorded reasons; `docs/build-and-release.md` holds them. Do not revisit
universal binaries or signing as part of other packaging work.

### The diagnostic CLI

```bash
swift run tetmux --diagnose                    # local tmux
swift run tetmux --diagnose server.example.org # a saved host, by id or name
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

Where things are, since the docs name symbols without saying which file holds them:

| File | What it is |
|---|---|
| `Core/ControlCodec.swift` | Bytes → `[ControlEvent]`. Pure value type, no I/O. |
| `Core/LayoutParser.swift` | tmux layout strings → `LayoutNode` tree. |
| `Core/PtyTransport.swift` | `forkpty` + reader thread. The only spawner of anything a channel runs on. |
| `Core/CommandProbe.swift` | One question, one subprocess, no pty — F4.4's discovery and nothing else. |
| `Core/SshPromptDetector.swift` | Classifies a pre-handshake prompt ssh is sitting on. |
| `Core/ScreenTitleFilter.swift` | Eats screen's `ESC k` title out of a pane's bytes; the emulator prints it. |
| `Session/SessionService.swift` | The actor. Channels, correlation, topology, flow control. |
| `Session/HostModel.swift` | `HostState`, `TmuxSession`, `TmuxWindow`, `TmuxVersion`. |
| `Session/TmuxCommand.swift` | Every command string and format, with its quoting rules. |
| `Session/HostConfigStore.swift` | `hosts.json`, `~/.ssh/config` discovery, `ssh -G` resolution. |
| `AppMain.swift` | Scenes, menus, tab strip, window chrome. |
| `AppModel.swift` | App-wide model; the decisions that need no channel. |
| `WindowState.swift` | Everything that belongs to one macOS window. |
| `TerminalContainerView.swift` | The pane-tree renderer and `PaneDivider`. |
| `TerminalSurface.swift` | `TerminalView` wrapper, `TerminalTheme`, bell, OSC handling, `ComposingTerminalView`, `PaneTerminalView`. |
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
| `PackageResources.swift` | The resource bundle, probed rather than asserted. `Bundle.module` is banned. |
| `NotificationPolicy.swift` | F4.31 — which events earn a banner, and `WatchedWindow`. |
| `DestructiveActionModal.swift` | The F4.10 confirmation, which says *why* the close is a kill. |
| `CopyModeSearchSheet.swift` | Searches tmux's history, which is not what ⌘F searches. |
| `BellNotifier.swift` · `KeychainStore.swift` | F4.31 background bells; per-host passwords. |
| `HostEditorView.swift` | The per-host form: destination, password, tunnels, ssh options, clipboard. |
| `AuthenticationSheet.swift` · `RenameSheet.swift` | The four ssh prompt kinds; session/window renames. |
| `LatencyProbe.swift` · `LaunchProbe.swift` | P6.1 and P6.7, off unless their env var asks. |

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
passthrough entry in `docs/behavior.md`.

## Rules that hold everywhere

Headlines only — the failure stories, the exact mechanics, and the conditions that do not fit on a
line here are in `docs/invariants.md` and `docs/behavior.md`. When one of these seems to be in the
way, read its entry before working around it.

- Identifiers keep their tmux sigil (`$1`, `@3`, `%7`) at every layer, codec to view.
- tmux owns geometry (§3.3); the cell size comes from the font, never from a pane; nothing resizes
  a surface before tmux confirms.
- Command correlation is by order against a FIFO; framing outranks dispatch; nothing writes before
  the handshake completes.
- Every user-supplied value goes through `TmuxCommand.quote` **and** `singleLine`; multi-line
  values through `doubleQuoted`; the remote command is exactly one argv element.
- Never weaken ssh host-key checking. A secret never goes through `send` and is never logged.
- `Bundle.module` is banned outright; resources go through `PackageResources`.
- State broadcasts are for topology changes only, and timer-driven values stay out of the diff.
- tmux ids collide across hosts: anything keyed on a session/window/pane id carries the host too.
- A reconnect attaches and never creates (F4.15); `%exit` is the only thing separating "the session
  ended" from "the link died".
- Closing a tab unlinks, never kills (F4.9); only a window's last link may kill, behind F4.10's
  confirmation.
- A tmux window is a "Tab" in every user-facing string; "Window" means the macOS window and
  nothing else.
- The child of a fork may touch nothing but syscalls before `exec`.
