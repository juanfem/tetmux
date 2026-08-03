# tetmux

A native macOS **tmux client**. Not a terminal emulator that you then run tmux inside — tetmux speaks
tmux's control mode (`tmux -CC`) and renders the resulting model as ordinary macOS UI. tmux windows
become app tabs, tmux panes become app splits, and tmux's own status bar, pane borders, and window
list are never drawn.

The point is that a remote working set stops being a picture of a terminal. Panes are real
`NSView`s, so selection, scrollback, and font rendering are native; the session lives on the server,
so closing the lid, changing networks, or quitting the app leaves everything running.

> **Status:** early. It connects, renders sessions and splits, tears windows off into their own macOS
> windows, and recovers from dropped connections — but there is no settings UI, no packaged `.app`, and
> the keymap, while centralised in one policy type, is not yet editable at runtime. Torn-off windows are
> separate windows rather than native `NSWindow` tabs, so they cannot yet be dragged together into one
> tab bar (F4.12 asks for that eventually).

## Requirements

- macOS 14 or newer
- A Swift 6 toolchain (Xcode 16+)
- tmux **2.4 or newer** locally and/or on any host you connect to — that is the control-mode floor.
  Developed against tmux 3.7; older-server quirks (the `refresh-client -C` syntax change in 3.2, the
  third field added to `%layout-change` in 2.5) are handled explicitly.
- For remote hosts: a working `ssh` login. tetmux shells out to the system `ssh`, so `~/.ssh/config`
  — including `ProxyJump`, `Match`, and agent forwarding — applies unchanged.

## Build and run

```bash
swift build
swift run tetmux
```

Tests need Xcode's toolchain, because XCTest is absent from CommandLineTools:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Using it

The sidebar lists hosts, their sessions, and each session's windows. `localhost` is always present;
other hosts come from a conservative scan of `~/.ssh/config` plus anything you add in-app. Clicking a
disconnected host connects it. There is also a menu bar item listing every host and session.

| Shortcut | Action |
|---|---|
| `⌘K` | Launcher — one ranked list over all hosts, sessions, and windows |
| `⌘T` | New window |
| `⇧⌘W` | Close window (confirmed) |
| `⌘D` / `⇧⌘D` | Split right / split down |
| `⌘R` / `⇧⌘R` | Rename window / rename session |
| `⌘V` | Paste into the focused pane |
| `⌥⌘V` | Send the next chord literally, bypassing every binding above |

Every default binding lives in `Cmd` space, which is the one real simplification of being
macOS-only: `Cmd` chords collide with neither readline, Emacs, nor tmux's own prefix, so every bare
`Ctrl` chord forwards to the pane untouched. Closing a tab **unlinks** the window — it never kills
what is running.

Sessions and windows can be renamed from the sidebar's context menu, from a tab's context menu, by
double-clicking a tab, or with `⌘R`/`⇧⌘R`. Renaming is sent to tmux and the tree updates when tmux
confirms it, so a rename made from another client looks exactly the same.

### Separate windows

Right-click a window or a session and choose **Open in New Window** to tear it out into its own macOS
window; **Move Back to Main Window** puts it back. A torn-off window sizes its tmux window
independently of the main one — on tmux 2.9 and newer, where `resize-window` exists; below that every
window shares the client's single size. The same tmux window can be open in two macOS windows at once,
in which case the focused one drives the size.

All of these share the host's one ssh connection, which sets the honest limit: tmux streams output for
**one session per connection**, so a window showing a session other than the attached one displays a
snapshot with an **Attach Here** button. Pressing it moves the connection — and turns the previously
attached session's windows into snapshots in turn.

### SSH host options

**Edit Host…** in the sidebar's context menu covers what `~/.ssh/config` cannot express per host:

- **Password authentication.** Keys are still tried first — ssh decides that — but when a password
  prompt does appear, tetmux answers it instead of hanging on a prompt written to a terminal you cannot
  see. Optionally the password is saved in your login Keychain (as an internet password, revocable in
  Keychain Access) and filled automatically; otherwise you are asked, and asked verbatim in ssh's own
  words so you can tell which host and account is being asked about. One attempt per connection: a
  rejected password fails the connection rather than being resubmitted into a lockout. Key passphrases
  are recognised but never stored — that is ssh-agent's job.
- **Tunnels.** Local (`-L`), remote (`-R`), and SOCKS (`-D`) forwards, established with the host's
  connection and gone when it closes. A forward that cannot bind does not take the session down with
  it; ssh's complaint shows up in the connection error text.

Nothing here weakens ssh: no `StrictHostKeyChecking`, no `UserKnownHostsFile`, and a host-key
confirmation is never auto-answered.

### Connection loss

Panes stay on screen when a channel dies, holding their real scrollback, with a banner saying they
are a snapshot. Recovery is attempted automatically — on wake, on network changes, and with a
1 s → 60 s backoff — but ssh takes its keepalive interval to notice a dead link, so the banner's
**Reconnect** button is the fast path when you know you are back. Reattaching restores the session
you were actually on and repaints every visible pane from tmux's scrollback.

Authentication failures are never retried, because retrying them locks accounts out. ssh's own error
text is shown verbatim rather than paraphrased.

## When something misbehaves

```bash
swift run tetmux --diagnose                    # local tmux
swift run tetmux --diagnose my-server          # a saved host, by id or name
```

This connects a real channel, prints the parsed event stream to stderr and the resulting topology to
stdout, then subscribes to a pane and round-trips a keystroke. It resolves against the same saved
host list the UI uses, so it exercises the exact user, port, and custom command. Reach for it first:
it separates "the protocol layer is wrong" from "the views are wrong", which is otherwise slow to
establish.

## Architecture

Four layers; everything below the UI is plain Swift with no AppKit dependency.

```
tetmux      app entry point + --diagnose CLI
tetmuxUI    SwiftUI/AppKit chrome; SwiftTerm pane surfaces        (@MainActor)
tetmuxCore  SessionService (actor) · ControlCodec · LayoutParser · PtyTransport
```

Everything reduces to a **control-mode channel**: a bidirectional byte stream speaking the tmux
control protocol. Local and remote differ *only* in which process `PtyTransport` spawns — `tmux -CC`
directly, or `ssh … -tt host -- <one argv element that execs tmux -CC>`. There is no "remote code
path".

`tetmuxCore` deliberately imports neither AppKit, SwiftUI, nor SwiftTerm. That keeps the interesting
logic headlessly testable, and leaves a non-macOS shell possible later without a rewrite.

Two documents are worth reading before changing behaviour:

- **`CLAUDE.md`** — the invariants that produce silent, hard-to-diagnose breakage when violated, and
  the protocol gotchas behind code that looks odd. Start here.
- **`tmux-manager-srd.md`** — the design baseline. Requirement IDs (`R3.4`, `F4.17`, `T5.6`, `P6.3`)
  are cited throughout the source and are the fastest route to the rationale for a given decision.

## Testing

`SessionIntegrationTests` drives a real PTY against the real tmux server on the machine, creating and
killing its own uniquely-named sessions and skipping entirely when tmux is absent. Protocol tests
replay byte streams captured verbatim from tmux 3.7b — when fixing a protocol bug, add the real
captured bytes rather than a hand-written approximation.

## Security

- Host-key checking is never weakened. No `StrictHostKeyChecking`, no `UserKnownHostsFile`, and a
  host-key confirmation prompt is surfaced rather than answered.
- Authentication remains ssh's responsibility. A password is stored only if you ask for it, only in the
  login Keychain, and never in `hosts.json` — which has no field that could hold one. Deleting a host,
  or turning storage off, deletes the Keychain item too.
- OSC 52 clipboard **writes** are denied by default and must be enabled per host; clipboard **reads**
  by a remote host are never permitted.
- OSC 8 hyperlinks open only `http`, `https`, `mailto`, and `ftp`.
- Clipboard content is encoded before it reaches tmux, so a paste is data and never a command. Names
  entered in the UI are stripped of anything that could end a command early.

## State on disk

| Path | Contents |
|---|---|
| `~/Library/Application Support/tetmux/hosts.json` | Host list, including tunnels and whether a password is expected. Entries discovered from `~/.ssh/config` are re-read each launch and deliberately not persisted. |
| `~/Library/Caches/tetmux/cm-%C` | ssh `ControlMaster` socket. Kept short on purpose — unix socket paths cap at 104 bytes. |
| Login Keychain | Per-host passwords, opt-in, as internet passwords with protocol `ssh`. |

While tetmux is attached it sets `window-size manual` on the session so each window can be sized
independently, and restores the option on a deliberate disconnect. If a connection dies with the network
instead, the option is left set; `tmux set-option -u -t <session> window-size` resets it.

## Dependencies

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) provides the pane surfaces, behind a
seam narrow enough that nothing above it knows which emulator is drawing. It resolves
[swift-argument-parser](https://github.com/apple/swift-argument-parser) (Apache-2.0) transitively.

tmux itself is neither bundled nor linked — tetmux spawns whatever `tmux` is on the host's `PATH`.

## License

MIT. See [`LICENSE`](LICENSE).
