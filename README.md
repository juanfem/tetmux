# tetmux

A native macOS **tmux client**. Not a terminal emulator that you then run tmux inside — tetmux speaks
tmux's control mode (`tmux -CC`) and renders the resulting model as ordinary macOS UI. tmux windows
become app tabs, tmux panes become app splits, and tmux's own status bar, pane borders, and window
list are never drawn.

The point is that a remote working set stops being a picture of a terminal. Panes are real
`NSView`s, so selection, scrollback, and font rendering are native; the session lives on the server,
so closing the lid, changing networks, or quitting the app leaves everything running.

> **Status:** usable, and honest about it. It connects, renders sessions and splits across as many
> macOS windows as you like, survives dropped connections, restores your window arrangement across
> launches, and has copy mode, drag-to-reorder tabs, an editable keymap and a settings pane. It meets
> every performance target it sets itself — `docs/measurements.md` has the numbers with the hardware
> beside each one.
>
> What it does **not** have is a notarised build or an updater, and that is a decision rather than a
> queue: notarisation needs a paid Apple Developer account, tetmux is written for one person's daily
> use, and the cost is a one-time right-click → Open on first launch (see the packaging note below).
> `TODO.md` lists that and everything else parked, with the reasoning; nothing on it is in progress.

## Requirements

- macOS 14 or newer
- A Swift 6 toolchain (Xcode 16+)
- tmux **2.4 or newer** locally and/or on any host you connect to — that is the control-mode floor.
  Developed against tmux 3.7; older-server differences are handled explicitly, and some features are
  version-gated: per-window sizing needs 2.9, and flow control and format subscriptions need 3.2.
  Below 2.9 you get a one-time warning saying what is unavailable.
  A host **below 2.4** is not refused: it falls back to a passthrough terminal — one plain `tmux` on
  a pty, drawing its own status bar and answering its own prefix key, in one window rather than as
  tabs and splits. It is a different thing wearing the same app, and the host says so; a host with no
  tmux at all is offered a plain login shell instead, which is offered rather than opened because
  nothing in it would survive the window closing.
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

Part of the suite drives a real tmux server on the machine, and skips itself if tmux is not
installed — so a green run without tmux is telling you less than it looks like. CI installs tmux and
fails the build if that skip fires, and builds `tetmuxCore` on Linux in a second job to keep the
no-AppKit boundary from rotting unnoticed.

### A packaged app

```bash
Scripts/package-dmg.sh          # → dist/tetmux-<version>-<arch>.dmg
```

`swift run` works because the app sets its own activation policy by hand, but a bare SwiftPM binary
has no bundle identifier, so the Keychain ACL has nothing stable to key on and every launch re-asks
for stored passwords. The script assembles the `.app`, ad-hoc signs it, and wraps it in a disk image.
CI does the same on every push and attaches the image to any `v*` tag.

The build is single-architecture — the filename says which — because a universal one pulls in
SwiftTerm's Metal shader compilation and a toolchain component that is a separate multi-gigabyte
download. The image is ad-hoc signed rather than notarised — by decision, not omission — so the
first open needs right-click → Open, or
`xattr -dr com.apple.quarantine /Applications/tetmux.app`. Once per install, and never again.

## Using it

The sidebar lists hosts, their sessions, and each session's tabs. `localhost` is always present
and connects itself at launch; other hosts come from a conservative scan of `~/.ssh/config` plus
anything you add in-app, and connect when you click them. There is also a menu bar item listing every
host and session, and a Dock menu with **New Window**, **New Local Session**, and **New Remote
Session ▸** — the last two because the Dock is the only surface the app has when no window is open,
and offering only "new window" there meant a second view of what you were already looking at.

| Shortcut | Action |
|---|---|
| `⌘K` | Launcher — one ranked list over all hosts, sessions, and tabs |
| `⌘N` | New macOS window |
| `⌘T` | New tab (a tmux window) |
| `⌘W` | Close tab — asks first when that would end what is running |
| `⇧⌘W` | Close the macOS window — leaves everything running on the server |
| `⌃⌘W` | Close the focused pane |
| `⌘D` / `⇧⌘D` | Split right / split down |
| `⇧⌘Z` | Zoom the focused pane |
| `⌥⌘[` / `⌥⌘]` | Previous / next pane |
| `⇧⌘[` / `⇧⌘]` | Previous / next tab |
| `⌘R` / `⇧⌘R` | Rename tab / rename session |
| `⌘F` | Find in the focused pane's scrollback |
| `⌃⌘F` | Search tmux's own history — further back than `⌘F` can reach |
| `⌃⌘[` | Enter copy mode |
| `⌃⌘Space` / `⌃⌘C` | Start selection / copy it to the Mac clipboard |
| `⌘=` / `⌘-` / `⌘0` | Bigger / smaller / actual size |
| `⌘V` | Paste into the focused pane (middle-click pastes the selection instead) |
| `⌥⌘V` | Send the next chord to the pane literally, past every binding above |

**A tmux window is called a *tab* throughout the app, and *window* always means a macOS window.**
That is not a translation layer over tmux's model — it is what the thing is on screen, and it is
why `⌘N` and `⌘T` mean here what they mean in every other Mac application. The tree, the tab strip
and the menu bar all use the one word, so no control has to be read twice to work out which kind of
window it will act on.

Every default binding lives in `Cmd` space — the one real simplification of being macOS-only, since
`Cmd` chords collide with neither readline, Emacs, nor tmux's own prefix, so every bare `Ctrl` chord
forwards to the pane untouched. tmux's prefix key is *not* intercepted and reaches the pane, which
also means `prefix`-based bindings do nothing useful here; the table above is the replacement. Every
binding is editable in **Settings ▸ Keys**, and a rebind must keep `Cmd` in it, which is what keeps
that promise about bare `Ctrl` true.

The two searches are genuinely two. `⌘F` searches what this side is holding — the scrollback in the
pane, as deep as the Settings depth and reset by a repaint. `⌃⌘F` searches tmux's own history on the
server, which reaches further back than tetmux was ever sent, and it enters copy mode to do it. Copy
mode itself is visible rather than silent: the pane badges the mode by name, because control mode is
never streamed the overlay and a pane sitting in it otherwise looks exactly like a dead process. The
keys you already use in copy mode still work — they go to tmux and are looked up in your own table —
so the menu items add a way in and a way out to the Mac clipboard without taking anything away.

**Hold `⇧` to select in a program that is using the mouse.** vim, htop and most modern TUIs — Claude
Code among them — turn on mouse reporting, which means the *program* receives clicks and drags and
the terminal does not, so dragging to select appears to do nothing. That is the program working as
intended rather than a bug, and it happens in Terminal.app and iTerm2 too; each of them just picks a
different modifier to escape it (`Fn` and `⌥` respectively). Here it is `⇧`, the xterm convention.
For anything longer than a line, copy mode is the better tool: it does not involve the mouse at all,
so mouse reporting cannot interfere, and it reaches tmux's scrollback rather than only what this side
was sent. Middle-click pastes whatever you last selected, by either route, rather than the clipboard.

Closing a tab **unlinks** it — it never kills what is running — unless that tab is linked to only
the one session, which tmux cannot unlink, and then you are asked and told why. Holding `⌥`
while clicking a close or kill button skips that confirmation, and the glyph turns red while `⌥` is
down so the modifier says what it will do before the click rather than after it. Nothing is
remembered: the next tab asks again.

Sessions and tabs can be renamed from the sidebar's context menu, from a tab's context menu, by
double-clicking a tab, or with `⌘R`/`⇧⌘R`. Renaming is sent to tmux and the tree updates when tmux
confirms it, so a rename made from another client looks exactly the same. A tab's label is its
name only when someone chose it; otherwise it is what is *running*, and for a split tab that means
every pane, with the focused pane's part in medium.

### Settings

**tetmux ▸ Settings…** has three tabs. **Terminal** covers the font (family, size, ligatures), the
pane colour scheme, and how much scrollback each pane keeps — 10,000 lines by default. Scrollback is
held on this side rather than by tmux, because control mode streams output here, so that number is
what `⌘F` and scrolling up actually search. Changing the font re-asks tmux for a new grid, so panes
reflow. The colour scheme applies to pane *contents* only and never to the app's chrome, which
follows the system appearance; **System** is the absence of a scheme rather than a copy of today's
colours, so it tracks light and dark while the app runs.

**Notifications** is two switches, for bells and for activity, and they are deliberately not the same
kind of thing. A bell is a program asking for attention, so it is on for every pane. Activity is only
"output arrived in a tab nobody is reading", which for most tabs is a prompt redrawing — so it is
opt-in **per tab**, from the tab's or the tree's context menu, and the tabs you have opted into
persist across launches. Both only ever notify while tetmux is in the background.

**Keys** is the keymap table, with a chord recorder. A chord already taken is refused rather than
silently resolved, and edits are stored as the difference from the defaults.

#### Scrollback is where the memory goes

If tetmux is using more memory than you expect, this is almost certainly why, and it is the one
setting that changes it. Each pane keeps its own history, and a terminal cell costs 24 bytes, so at
the default depth an 80-column pane holds roughly **18 MB** — measured at about 25 MB in practice
once per-line overhead is counted. Twenty panes at that depth is most of half a gigabyte, and the
picker's largest option is ten times the default *per pane*:

| Scrollback | Per pane (80 columns) | Twenty panes |
|---|---|---|
| 1,000 lines | ~2 MB | ~37 MB |
| 5,000 lines | ~9 MB | ~180 MB |
| **10,000 lines** (default) | ~18 MB | ~370 MB |
| 50,000 lines | ~92 MB | ~1.8 GB |
| 100,000 lines | ~183 MB | ~3.6 GB |

The settings pane shows the per-pane figure beside the picker and updates it as you choose, so you
need not come back here for the arithmetic. Lowering the depth takes effect on panes already open —
it is applied live, not at the next launch — and costs you only history you had not scrolled back
to. Nothing else in tetmux scales with pane count in a way you would notice: the connections, the
tabs and the sidebar are all small next to this.

The measurements behind those numbers, including what was counted and what was not, are in
[`docs/measurements.md`](docs/measurements.md).

### Several windows

Right-click a window or a session and choose **Open in New Window**. There is only one kind of macOS
window: the new one is an ordinary window seeded to that session with its sidebar collapsed, so
everything works there exactly as it does anywhere else.

Each displayed session gets its own tmux client, so several sessions can be live in several windows at
once — tmux streams output only for the session a client is attached to, and one client per host would
make every other window a still frame. Two windows showing the *same* session share one client, since
a second there would stream the same panes twice. If a session ends up on screen with no client behind
it, a banner says so rather than letting the panes quietly stop moving.

On tmux 2.9 and newer each tab is sized individually, so a tab opened into its own macOS window sizes
itself independently; below that every tab shares the client's single size. When the same tab is open
in two macOS windows, the focused one drives the size.

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
- **Extra ssh options**, typed as they would be on a command line, plus `-X` behind a checkbox. They
  are split the way a shell would split them and handed straight to `execve` — no shell, no expansion
  — and placed before tetmux's own options, because ssh takes the first value it is given for each.

Nothing here weakens ssh: no `StrictHostKeyChecking`, no `UserKnownHostsFile`, and a host-key
confirmation is never auto-answered.

### Connection loss

Panes stay on screen when a channel dies, holding their real scrollback, with a banner saying they
are a snapshot. Recovery is attempted automatically — on wake, on network changes, and with a
1 s → 60 s backoff — but ssh takes its keepalive interval to notice a dead link, so the banner's
**Reconnect** button is the fast path when you know you are back. Reattaching restores the session
you were actually on and repaints every visible pane from tmux's scrollback.

A reconnect only ever *attaches*: it will not create a session. If the server restarted while you were
away, you are told there is nothing to attach to rather than handed a new empty session wearing the old
one's name. Authentication failures are never retried, because retrying them locks accounts out, and
ssh's own error text is shown verbatim rather than paraphrased.

Attaching also detaches tetmux clients left behind by earlier dropped connections. Only control-mode
clients that are not one of tetmux's current channels are touched — a plain `tmux attach` in a terminal
is never disturbed. **Detach Other Clients** in the host's context menu is the blunt version, and does
include your terminals; **Detach This Client** lets go of the session without ending it.

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
tetmuxUI    SwiftUI/AppKit chrome; SwiftTerm pane surfaces; KeychainStore   (@MainActor)
tetmuxCore  SessionService (actor) · ControlCodec · LayoutParser · PtyTransport · SshPromptDetector
```

Everything reduces to a **control-mode channel**: a bidirectional byte stream speaking the tmux
control protocol. Local and remote differ *only* in which process `PtyTransport` spawns — `tmux -CC`
directly, or `ssh … -tt host -- <one argv element that execs tmux -CC>`. There is no "remote code
path".

`tetmuxCore` deliberately imports neither AppKit, SwiftUI, nor SwiftTerm. That keeps the interesting
logic headlessly testable, and leaves a non-macOS shell possible later without a rewrite — which is
why CI builds that target on Linux even though nothing there consumes it.

Two documents are worth reading before changing behaviour:

- **`CLAUDE.md`** — the invariants that produce silent, hard-to-diagnose breakage when violated, and
  the protocol gotchas behind code that looks odd. Start here.
- **`tetmux-srd.md`** — the requirements baseline. Requirement IDs (`R3.4`, `F4.17`, `T5.6`, `P6.3`)
  are cited throughout the source and are the fastest route to the rationale for a given decision.

## Testing

`SessionIntegrationTests` drives a real PTY against the real tmux server on the machine, creating and
killing its own uniquely-named sessions and skipping entirely when tmux is absent. Protocol tests
replay byte streams captured verbatim from tmux 3.7b — when fixing a protocol bug, add the real
captured bytes rather than a hand-written approximation, and prefer capturing one over reasoning about
what tmux probably does.

Two habits are worth keeping. A test that waits on a model predicate must **fail**, not skip:
`waitForHost` throws `XCTSkip` on timeout, and a skip is exactly as green as a pass. And a test for a
bug should be checked by breaking the fix again — several tests here were only trusted after watching
them fail.

## Security

- Host-key checking is never weakened. No `StrictHostKeyChecking`, no `UserKnownHostsFile`, and a
  host-key confirmation prompt is surfaced rather than answered.
- Authentication remains ssh's responsibility. A password is stored only if you ask for it, only in the
  login Keychain, and never in `hosts.json` — which has no field that could hold one. Deleting a host,
  or turning storage off, deletes the Keychain item too.
- OSC 52 clipboard **writes are off by default and enabled per host**, in **Edit Host…** — trusting
  the machine on your desk to set your clipboard is a different decision from trusting a shared box
  you ssh into, so it is not one application-wide switch. A host record written before the field
  existed reads as denied. Clipboard **reads are never permitted**, at any setting.
- OSC 8 hyperlinks open only `http`, `https`, `mailto`, and `ftp`.
- Clipboard content is encoded before it reaches tmux, so a paste is data and never a command. Names
  entered in the UI are stripped of anything that could end a command early.

## State on disk

| Path | Contents |
|---|---|
| `~/Library/Application Support/tetmux/hosts.json` | Host list, including tunnels, extra ssh options, and whether a password is expected. Hosts discovered from `~/.ssh/config` are re-read each launch; only your *edits* to them are stored, so the config file stays authoritative. A file that cannot be read is kept as `hosts.json.corrupt-<timestamp>` rather than overwritten. |
| `~/Library/Application Support/tetmux/workspace.json` | Window arrangement — one entry per macOS window (host, session, tmux window, frame, whether the tree was showing), plus which windows you watch for activity and the launcher's recency order. View state and nothing else: tmux is the persistence layer for anything inside a pane. |
| `~/Library/Application Support/tetmux/settings.json` | The keymap, as the difference from the defaults; `null` is a shortcut deliberately unbound. JSON rather than `UserDefaults` because a keymap is a document you may want to read, diff, or copy to another Mac. |
| `~/Library/Caches/tetmux/cm-%C` | ssh `ControlMaster` socket. Kept short on purpose — unix socket paths cap at 104 bytes. |
| `UserDefaults` | Terminal font, size, ligatures, scrollback depth, colour scheme, and the two notification switches — the ordinary preferences the system already has a place for. |
| Login Keychain | Per-host passwords, opt-in, as internet passwords with protocol `ssh`. |

While tetmux is attached it sets `window-size manual` on the session so each tab can be sized
independently, and restores the option on a deliberate disconnect and on quit. If a connection dies
with the network instead, the option is left set; `tmux set-option -u -t <session> window-size` resets
it.

## Dependencies

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) provides the pane surfaces, behind a
seam narrow enough that nothing above it knows which emulator is drawing. It resolves
[swift-argument-parser](https://github.com/apple/swift-argument-parser) (Apache-2.0) transitively.

tmux itself is neither bundled nor linked — tetmux spawns whatever `tmux` is on the host's `PATH`.

## Scope and contributions

tetmux is written for my own daily use, and that is what decides what goes in it. It is shared
because it may be useful to someone else, not because it is aiming to be everyone's tmux client.

Feature requests are welcome and I will consider the ones I find useful myself — if a request does
not fit how I work, I will say so rather than leave it open indefinitely. Pull requests are welcome
on the same terms: fixes, tests, and additions that leave the existing behaviour alone are the
easiest to accept, and anything that changes the default workflow is unlikely to be merged even if
it is well built. If you are planning something substantial, open an issue first so neither of us
spends the effort before finding that out.

The license is MIT, so forking is always an option and is the right one when the disagreement is
about what the app should be.

## License

MIT. See [`LICENSE`](LICENSE).
