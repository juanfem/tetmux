# System Requirements Document — tetmux, a tmux Control-Mode Session Manager (macOS)

**Version:** 2.1 — amended 2026-08-06 against the shipped implementation
**Status:** Requirements baseline. Requirement IDs (`R3.x`, `F4.x`, `T5.x`, `P6.x`) are cited
throughout the source; existing IDs are frozen and amendments change their text, never their number.
**Platform:** macOS 14+, Apple Silicon (arm64) **only** — by decision, not omission. See §2.5.

v2.1 records the decisions v2.0 left open (terminal core, multiplexing topology), corrects the
places where the implementation deliberately outgrew the text (window sizing, paste, credentials,
window tabbing), and adds requirements for three subsystems that turned out to be load-bearing and
were previously undocumented (channels and multiplexing §3.5, authentication §4.8, flow control
P6.5). §9 and §10 are retained as historical record.

---

## 1. Product definition

A native macOS application that presents local and remote `tmux` servers through a graphical
interface. tmux windows appear as application tabs; tmux panes appear as application splits.
Sessions on any configured SSH host are discoverable, attachable, and survivable across network
interruptions from a single window.

The application is a **tmux client**, not a terminal emulator that happens to run tmux. It speaks
tmux control mode (`tmux -CC`) and renders the resulting model natively. tmux's own status bar,
pane borders, and window list are never displayed — the GUI replaces them.

### 1.1 What this is for

The target user runs long-lived work on several remote Linux machines from a Mac and currently
juggles nested tmux prefixes, forgotten session names, and terminal tabs whose contents they cannot
identify without attaching. The product's value is that the session topology of every machine you
use is visible at once, and that reconnecting after a dropped VPN or a closed laptop lid is instant
and lossless.

### 1.2 Non-goals

- **A Linux or Windows GUI.** The application connects *to* Linux; it does not run there. See §2.4
  for the portability hedge that keeps this reversible at low cost.
- **An Intel or universal macOS build.** arm64 only (§2.5).
- A general-purpose terminal emulator. There is no "open a plain shell" mode except as offered on a
  host with no tmux (§3.4's last row) and as part of the fallback path in §4.6.
- Editing the user's `tmux.conf`, `ssh_config`, or dotfiles.
- Serial, telnet, Docker, or Kubernetes transports.
- File transfer, SFTP browsing, or port-forward management UI. Forwards exist only as `-L`/`-R`/`-D`
  connection options that live and die with the channel.
- Mac App Store distribution (see §2.5 — the sandbox makes it impossible).
- Any AI or agent features.

---

## 2. Architecture

### 2.1 The central abstraction

Everything reduces to one concept: **a control-mode channel** — a bidirectional byte stream on
which the tmux control protocol is spoken. Local and remote differ only in which process
`PtyTransport` spawns:

| | Spawned process |
|---|---|
| Local | `tmux -CC -2 -u new-session -A -s <name>` |
| Remote | `ssh … -tt <host> -- <one argv element that execs the same tmux invocation>` |

A PTY is allocated in both cases; tmux refuses to attach without a terminal, and `ssh -tt` forces
allocation even when stdin is not a tty.

Two refinements that v2.0 did not anticipate, both load-bearing:

- **A user-initiated connect attaches with no target** (`attach-session`, which cannot create), and
  only when there is nothing to attach to does a second attempt create. Attach-by-remembered-name
  belongs to *recovery* only. Conflating the two makes clicking a host with existing sessions do
  nothing at all (F4.15).
- **§4.6's passthrough invocation is the same sentence with `-CC` removed** — that flag is the
  entire difference, asserted as an equality in a test, because a fallback that also dropped `-u`
  would present as a font bug.

Because the transport difference is confined to process spawning, **all session logic is written
once**. There is no "remote code path."

### 2.2 Layers

```
tetmux      app entry point + --diagnose CLI
tetmuxUI    SwiftUI/AppKit chrome; SwiftTerm pane surfaces; KeychainStore   (@MainActor)
tetmuxCore  SessionService (actor) · ControlCodec · LayoutParser · PtyTransport · SshPromptDetector
CUtil       systemLibrary shim, Linux only — `forkpty` lives in libutil on glibc
```

`tetmuxCore` must not import AppKit, SwiftUI, or SwiftTerm (§2.4). `ControlCodec` remains a pure
value type — no I/O, fixture-tested. `SessionService` is an actor holding channels, correlation,
topology, and flow control.

### 2.3 Technology stack

**Swift 6, AppKit for window/split structure, SwiftUI for chrome, sidebar, launcher, and settings.**
Not Electron. For a keystroke-in-glyph-out application, native input latency is the product.

**Terminal core: SwiftTerm.** *Decision, recorded per §9 Spike 1.* v2.0 named libghostty as the
primary candidate with SwiftTerm as fallback; the fallback was taken. The swappable-backend
requirement (a `TerminalSurface` protocol either engine could sit behind) is **withdrawn**: the
implementation leans on SwiftTerm specifics — the hidden scroller, `cellDimension` read-back for
hit-testing, the implicit link matcher, the find bar — and pretending the backend is replaceable
would be a fiction. The dependency is instead **pinned by tests**: behaviour tetmux relies on but
does not implement (implicit URL detection, mouse-mode state, IME composition) must have a
regression test that fails if a SwiftTerm bump turns it off (F4.23, F4.24, T5.5).

**Fit note, still true:** a control-mode client does not need a terminal *emulator* — it needs a
terminal *view*. No PTY ownership per pane, no child-process management. Just "here are bytes, give
me a grid, draw it."

**PTY:** a thin Swift wrapper over `forkpty(3)` and `TIOCSWINSZ`. No third-party dependency. The
child of the fork may touch nothing but syscalls before `exec` — Swift allocation there deadlocks
intermittently in a process with a live concurrency pool.

**Concurrency:** Swift structured concurrency throughout. `SessionService` is an `actor`; the codec
is a `struct` with `mutating func feed(_:) -> [ControlEvent]`; transports expose async streams. UI
types are `@MainActor`. No callback pyramids, no `DispatchQueue` ad-hockery.

**SSH: the system `ssh` binary, invoked as a subprocess.** Unchanged, and the decision that has
earned its keep most: prompt handling (§4.8), `ControlMaster` discovery (F4.4), and `ssh -G`
resolution (F4.2) all lean on real OpenSSH behaviour that no reimplementation would get right.
`~/.ssh/config` is not a parseable file format in practice — `Include`, `Match exec`, `ProxyJump`,
canonicalisation, and first-value-wins precedence make faithful reimplementation a multi-month
effort that will still be subtly wrong. Delegating to OpenSSH gets certificates, FIDO/`sk-` keys,
hardware and 1Password agents, Kerberos/GSSAPI, jump hosts, and `known_hosts` semantics for free
and correct.

Standard invocation for every host:

```
ssh -o ControlMaster=auto \
    -o ControlPath=~/Library/Caches/tetmux/cm-%C \
    -o ControlPersist=300 \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -tt <host> -- <remote command>
```

The `ControlPath` lives in Caches, not Application Support: unix socket paths cap at 104 bytes and
Application Support plus ssh's 40-character hash runs close to it. User-supplied ssh options are
split shell-style (quotes group, backslash escapes) and placed **before** tetmux's own `-o`
options — ssh resolves each parameter to the first value it obtains, so options appended after ours
would be accepted and silently ignored. The remote command is exactly **one argv element**: ssh
joins everything after the destination with spaces and hands the single result to the remote login
shell.

The application never passes `StrictHostKeyChecking=no` and never auto-accepts a host key.
Verification prompts and failures are surfaced verbatim from `ssh`'s output (§4.8, §7).

**Persistence: JSON** in `~/Library/Application Support/tetmux/` — `hosts.json`, `workspace.json`,
`settings.json`. Not SQLite, not SwiftData. One deliberate exception: the terminal's *appearance*
(font, size, ligatures, scrollback) lives in `UserDefaults`, because those are ordinary application
preferences the system already has a place for, while a keymap is a document somebody may want to
read, diff, or copy to another Mac — which is the whole argument for JSON.

**Credentials.** *(Amended — v2.0 said "never stored", and the implementation deliberately went
further.)* ssh remains the authenticator: keys are tried first, and the application only ever
answers a prompt ssh actually raised. Within that:

- A per-host password may be stored **opt-in** in the login Keychain
  (`kSecClassInternetPassword`, protocol ssh, keyed by server/account/port). Removing the host, or
  turning storage off, deletes the item.
- `hosts.json` records only *that* a password is expected, never the password. A test asserts no
  secret-shaped field ever appears in it.
- Key passphrases are never stored per host — they belong to the key, and ssh-agent already
  handles them.
- Keychain access lives in `tetmuxUI`, never `tetmuxCore`: `Security.framework` is as macOS-only
  as AppKit. `SessionService` publishes a prompt and is handed an answer; it never reads a
  credential.

### 2.4 Portability hedge

Everything below the UI layer — `ControlCodec`, `SessionService`, `PtyTransport`, the models — must
compile on Linux Swift, and CI must build that target on Linux even though nothing consumes it
(`CUtil` supplies `forkpty` on glibc). This costs almost nothing and preserves the option of a
future Linux shell without a rewrite. Its immediate payoff is that the interesting logic stays
headlessly testable. A hedge that is never exercised has already stopped being a hedge — the Ubuntu
CI job is the other half of the requirement, not an optional extra. The codec's fixture suite
*runs* on Linux as well: `tetmuxCoreTests` links `tetmuxCore` alone, and the Ubuntu job runs it
(`swift test --filter tetmuxCoreTests`).

### 2.5 Distribution

**arm64 only, by decision.** A universal binary needs SwiftPM's `--arch arm64 --arch x86_64`, which
routes through xcbuild, which compiles SwiftTerm's Metal shaders and so needs a Metal toolchain
component that is a separate multi-gigabyte download; the native path copies the `.metal` source
into the resource bundle and never invokes the compiler. The `.dmg` filename carries the
architecture so nobody on an Intel Mac is surprised late.

**Ad-hoc signing, no notarisation, no updater — by decision, and not a gap waiting to be closed**
*(amended 2026-08-06)*. Notarisation needs a paid Apple Developer account, and §1 is explicit that
tetmux is built for one person's daily use: that person is content to right-click → Open once, or
run `xattr -dr com.apple.quarantine`, which is what the release notes and the README both say out
loud. Buying a certificate to remove a one-time step for its only guaranteed user is not a trade
worth making, and leaving it listed as pending work misrepresents a decision as a backlog item.
Anyone else's first open costs the same one-time step, which is stated at the download rather than
discovered after it.

*If that ever changes* — an account arrives, sponsored or bought, or the friction starts landing on
somebody else — the work is known and is not large: sign with the Developer ID Application cert plus
`--options runtime --timestamp` in `Scripts/package-dmg.sh` (the ad-hoc branch stays, for local
builds), add `xcrun notarytool submit --wait` and `xcrun stapler staple` to the `v*` tag job with the
app-specific password as a repo secret, then Sparkle via SPM with an EdDSA key kept offline and an
appcast served from GitHub Releases. A Homebrew cask becomes worth doing at the same moment and not
before. The .dmg stays arm64-only regardless — that is this section's other decision, and it is not
part of this one.

**App Store distribution is impossible**, not merely inconvenient: the sandbox forbids spawning
`/usr/bin/ssh`, reading `~/.ssh`, and connecting to the user's SSH agent socket. Do not design
around a future sandboxed build.

---

## 3. Control-mode protocol layer

The highest-risk component, and the one most likely to be implemented sloppily.

### 3.1 Requirements

- **R3.1** `ControlCodec` is a pure value type: `mutating func feed(_ bytes:) -> [ControlEvent]`.
  No I/O, no processes, no timers, no `async`. Unit-testable with nothing running. Lines are
  bounded at 16 MiB — a stream that never sends a newline must not be unbounded memory growth.
- **R3.2** Correct block framing (`%begin <ts> <num> <flags>` … `%end` / `%error`). *(Amended.)*
  Command numbers are **server-wide and start at an arbitrary value**, so they cannot schedule the
  match: correlation is by *order*, against a FIFO of pending commands, and commands queue in an
  outbox until tmux's own attach-time `%begin`/`%end` block has passed. The number is used to
  **detect** a desync (a `%begin` that fails to increase, a `%begin` with nothing pending, a
  terminator closing a block it did not open) — detection is logged; everything that could cause a
  misalignment (partial writes, secrets in the FIFO) is treated as fatal to the channel rather than
  recovered from. **Framing outranks dispatch**: inside a `%begin` block every line is response
  content, including lines starting with `%`, and only a terminator carrying the matching number
  closes the block. Parsing notifications first admits data loss (`%` shell prompts vanishing from
  repaints) and forgery (`%exit`/`%output` injected via captured scrollback).
- **R3.3** Handles at minimum: `%output`, `%extended-output`, `%layout-change`, `%window-add`,
  `%window-close`, `%window-renamed`, `%window-pane-changed`, `%session-changed`,
  `%session-renamed`, `%sessions-changed`, `%unlinked-window-*`, `%client-detached`,
  `%client-session-changed`, `%pane-mode-changed`, `%config-error`, `%subscription-changed`,
  `%pause`, `%continue`, `%exit`. Unknown `%`-prefixed lines are logged and ignored, never fatal —
  tmux adds notifications between versions.
- **R3.4** Octal escape decoding in `%output` payloads is correct for all byte values including
  embedded newlines and NUL. Operates on bytes, never on `String`. Command response bodies are
  *not* escaped — `capture-pane -e` arrives as raw escape sequences, so raw bytes are carried
  alongside any lossy string form.
- **R3.5** Layout strings parse into a typed tree with checksum validation, and **a rejection is
  all-or-nothing**: the layout and visible-layout fields of one notification commit together or
  the previous layout is kept whole. Blanking the tree on a mismatch costs the user their panes;
  a stale grid costs one notification's worth of staleness. The parser runs on bytes from the wire
  and must never trap: overflow is checked, recursion is depth-capped — `try?` catches neither.
- **R3.6** Developed against **recorded fixtures**: real byte streams captured from tmux 3.0, 3.2a,
  3.3a, 3.4, and 3.5 (plus the current local version) covering split/kill/resize/rename/zoom/detach
  sequences. Fixture **replay** runs in CI; fixture **capture** never does — a fixture's value is
  that it is a frozen record, and a capture regenerated each run asserts "the parser agrees with
  whatever tmux just said", which is true by construction. The capture scripts are kept for
  provenance and pin checksummed tarballs, so a rebuild is byte-identical. Captures must record a
  *version*, not a machine: default config (`-f /dev/null`), deterministic pane content, a binary
  installed as plain `tmux`.

### 3.2 Sending input to panes

Under control mode the channel's input side carries **tmux commands, not pane keystrokes**.

- Keyboard input is `send-keys -H -t %<pane>` with hex bytes, batched per display frame — never one
  command per keystroke.
- **Paste does not go through per-key `send-keys`.** *(Amended — v2.0 prescribed
  `load-buffer -b <tmp>`, which requires a file and so cannot exist for a remote host.)* Small
  pastes (≤ 512 bytes) go through `send-keys -H`, which is hex and newline-safe by construction.
  Large pastes are chunked `set-buffer`/`set-buffer -a` with double-quoted escaping, then one
  `paste-buffer -d -p`. Only double quotes can carry `\n` — a single-quoted tmux string has no
  escape for a newline at all — and inside double quotes tmux **expands `$`**, so it must be
  escaped or `"cd $HOME"` arrives resolved. Each paste gets its own buffer name: chunks are
  separate commands, and two panes pasting at once would otherwise interleave into one buffer.
- Bracketed-paste markers are tmux's job (`paste-buffer -p`), honoured when the pane's application
  enabled the mode.
- **Every user-supplied value is quoted (`TmuxCommand.quote` / `doubleQuoted`) *and* framed
  (`TmuxCommand.singleLine`).** Control-mode commands are newline-framed, so a value containing a
  line break ends the command early and the remainder arrives as a *new command that tmux
  executes*. Quoting cannot defend against that — the framing is resolved a layer below the parser.
  Session names, window names, start directories, and initial commands are all user data that
  reach a shell.
- tmux's argument lexer is its own; a shell cannot answer questions about it. Probe quoting
  questions over a real channel (verified on 3.7b: `\n`/`\t`/`\e` work in double quotes, `$VAR`
  expands, `\xHH` does not, NUL cannot survive at all).

### 3.3 Geometry — tmux is authoritative

**R3.7** The GUI never decides pane geometry:

1. The view measures its pixel area and computes a target cell grid from the current font metrics.
2. `SessionService` asks tmux for that size.
3. tmux responds with `%layout-change`.
4. The view lays out splits from the received layout and snaps each surface to the cell dimensions
   tmux reported.

Any implementation that resizes a surface before tmux confirms will drift and corrupt output.
Resize requests are debounced ~100 ms and coalesced. During AppKit live-resize, channel traffic is
suppressed entirely and one request issues on completion, at the size the user let go of
(`LiveResizeGate` — one per macOS window, its held requests keyed by tmux window).

Two derivation rules keep the loop from feeding on itself:

- **The cell size comes from the font, never from a pane.** A pane can only report its own frame
  divided by its own cell count, which is circular; with split panes the per-pane answers disagree
  and the requested width oscillates forever. The theme mirrors the emulator's font arithmetic and
  depends on nothing but the font and the **window's** backing scale factor — not
  `NSScreen.main`, which follows keyboard focus anywhere on the system.
- The emulator's own `sizeChanged` is ignored in control mode — it fires when the emulator
  re-derives its grid from the frame we just gave it. (In passthrough the rule inverts: the surface
  *is* the client's terminal, so `sizeChanged` drives `TIOCSWINSZ` — §4.6.)

**Window sizing.** *(Amended — v2.0 said `window-size latest` on attach; per-window sizing
superseded it.)* On tmux ≥ 2.9 each displayed window is sized individually: `set-option
window-size manual` plus `resize-window -t @id`, which is what lets a torn-off macOS window size
its tmux window independently. A window's size has exactly **one owner** (the focused view); other
views of the same window render the grid the owner negotiated, because two views driving one
window fight forever. Below 2.9 there is no per-window sizing and `window-size latest` +
`refresh-client -C` is the only mechanism — without it an old or small client clamps every window
toward 80×24 (F4.17's failure mode by another route). `window-size` is a *session* option: it is
re-applied after `%session-changed`, and **restored** (`set-option -u`) on deliberate disconnect
and on quit — and that restore must be waited for against tmux's own `%end`, not merely written,
or the teardown's `SIGHUP` races the write and leaves `manual` on the user's session for the next
plain `tmux attach` to find.

### 3.4 Version handling and fallback

**R3.8** On connecting, the tmux version is established before anything else, and **the probe's
answer decides which kind of channel this is** — a below-floor server hands over to passthrough
and none of the control-mode policies run (§4.6).

| Version | Behaviour |
|---|---|
| ≥ 3.2 | Full control mode: `refresh-client -B` subscriptions, `%pause` flow control, `move-window -a/-b` |
| 2.9 – 3.1 | Full control mode; subscriptions and pause unavailable — byte ceiling is the whole flow-control mechanism, pane commands polled, reorders built from `swap-window` |
| 2.4 – 2.8 | Control mode with reduced features (no per-window sizing); warn once per host |
| < 2.4 | **Passthrough fallback** (§4.6) |
| tmux absent | Clear error offering a plain login shell to that host — offered, never started |

Passthrough fallback is a first-class requirement. Institutional and HPC environments run
long-lived old distributions, and an application that refuses to connect to them is useless in
exactly the environments where session persistence matters most. Other version facts the code
branches on: `client_user` is empty below 3.3; `%client-detached` needs 3.2 (topology refreshes
re-read `list-clients` as the fallback).

### 3.5 Channels and multiplexing *(new in v2.1 — answers §9 Spike 2)*

- **R3.9** **One tmux client per session on screen.** Control mode streams `%output` only for the
  attached session, so one channel per host cannot animate two displayed sessions. A host has a
  **primary** channel and any number of **followers**, one per additionally-displayed session, and
  the two kinds are deliberately asymmetric: the primary *is* the host — its state is the host's
  connection state, its `%exit` is the server ending, it owns the reconnect backoff and carries
  every command — while a follower only makes one more session's panes move: no prompt, no state,
  no backoff (a follower usually dies because its session did). Sharing is by session, not by
  window: two windows on one session are two views of one client. The primary is *moved* with
  `switch-client` rather than duplicated when its own session leaves the screen, and only when
  nobody is watching the panes it would strand. The desired set is recomputed from every open
  window's selection; a reconciler makes reality match it.
- **R3.10** **A pane belongs to one channel, or it is painted twice.** A window linked into several
  sessions is streamed by every attached client that can see it (verified on 3.7b); two copies fed
  to one emulator is a corrupted screen. Pane ownership is first-come by channel epoch; the
  non-owners' bytes are dropped, and when the owner goes away the pane is released *and repainted*,
  because its new owner is mid-stream on a screen it never drew. Flow-control commands go to the
  **owning** client — pausing a pane on a client that is not streaming it does nothing, silently.
  A repaint for a second viewer of a pane is **addressed to that viewer alone**: `capture-pane`'s
  payload begins with a full clear, and broadcasting it wipes the scrollback every other view of
  that pane is holding.
- **R3.11** **Liveness is what tetmux is attached to, not what tmux counts.** tmux's own
  `session_attached` includes clients elsewhere on the machine and cannot answer "are these panes
  live?". Liveness deliberately includes a follower still handshaking and a `switch-client` still
  in flight — attaching is a round trip, and the strictly honest answer for its duration makes the
  not-attached banner flash and withdraw, which reads as a glitch. A *failed* switch must clear the
  pending state, or a dead session reports live forever and the banner never appears.

---

## 4. Functional requirements

### 4.1 Host and session sidebar

- **F4.1** A collapsible tree: **Host → Session → Window**. Panes are not tree nodes; they appear
  in the split view. A pane is not independently attachable, so listing it in a navigation tree is
  noise. *(v2.0's "pane inspector" is withdrawn — none was built and none is missed.)*
- **F4.2** Hosts are populated from `~/.ssh/config` `Host` stanzas (excluding wildcards) plus
  manual entries in `hosts.json`. `ssh -G` resolves what an alias means — **for display only**:
  editor placeholders show the resolved user and port so a blank field says what leaving it blank
  will do. The connection is always made with the *name*, so ssh applies its own file and every
  `Match` block resolves against the real invocation; feeding resolved values back to ssh would
  re-decide what ssh has already decided. The resolution map keeps a repeated key's **first**
  value (ssh's precedence); genuinely multi-valued keys (`identityfile`) cannot be read from it.
- **F4.3** Per-host state: `disconnected`, `connecting`, `connected`, `degraded`, `reconnecting`,
  `failed`, with the reason string available. `degraded` (passthrough) is an *active* state.
- **F4.4** Lists update from control-mode notifications. **There is no polling loop.** Discovery
  for a host with no attached channel is a single `tmux -C list-sessions` over the existing SSH
  master — on demand (expanding the host, opening the launcher) and on window focus only, with a
  freshness window. The probe must be unable to interrupt anybody: `BatchMode=yes`, a pipe rather
  than a pty, stdin from `/dev/null` (`tmux -C` reads commands until EOF and otherwise hangs
  forever). Its answer is `%begin`-framed while its failures are not, which is what separates
  "this host has nothing" from "we could not ask" — and the result is therefore an *optional*,
  because recording an unreachable host as empty tells somebody their sessions are gone because
  their laptop is on a train. Discovery attaches nothing; a discovered session attaches by name
  with `attach-session`, which cannot create.
- **F4.5** Each window row shows name, pane count, active pane's foreground command, and an
  activity indicator derived from `%window-*` notifications. A window's label is its name only
  when the user chose it (`#{automatic-rename}` is the tell); otherwise it is what is running —
  for a split window, every pane, so the label does not churn as focus moves between panes.

### 4.2 Tabs, splits, and the workspace

- **F4.6** One application tab = one tmux window. Opening a session opens tabs for its windows;
  the active tmux window is the active tab. Tab reorder is `move-window -a/-b` on ≥ 3.2 and a run
  of adjacent `swap-window`s below; both address windows by `@id`, never by index — a session's
  indices are arbitrary and often not contiguous — and the source of a move carries its session,
  because a linked window is reachable by id from any of them.
  *(Amended:)* a tab can also be moved into **a session that does not exist yet** — first item of
  Move to Session, wherever a window is listed. tmux has no single command for it, so it is
  `new-session -d` with a named placeholder window, `move-window` into it, and a `kill-window` of
  the placeholder **by that name**; a move that fails therefore leaves an empty session tmux
  destroys, and nothing of the user's is ever the kill's target. The new session is named the way
  New Session names one, and is shown once the tab is in it.
- **F4.7** Splits mirror the tmux pane layout exactly, including nesting and dimensions,
  reconstructed from the layout string. A zoomed window renders the **visible** layout while
  membership and labels come from the full one; zoom state arrives in `%layout-change` flags, and
  a window already zoomed at attach never sends one — so the window list format must carry the
  visible layout and flags too.
- **F4.8** GUI split/close operations translate to tmux commands and apply only when tmux
  confirms. Dragging a divider issues `resize-pane -x/-y`.
- **F4.9** Closing a tab detaches or unlinks — it never kills. Where tmux makes that impossible it
  must say so rather than do the other thing: a window linked to a single session cannot be
  removed without being destroyed (`unlink-window` refuses it outright), so that case is the one
  path to `kill-window` and it goes through the F4.10 confirmation, worded to explain why closing
  has become killing. A linked window says so before the click — a badge on tab and tree, with the
  other sessions named — because the link is what decides whether closing is reversible.
- **F4.10** Destructive commands require confirmation showing the target's name, pane count,
  running commands, **and who else is attached** — a kill is not private, and `list-clients` kept
  fresh in the model is what makes "nobody else is attached" trustworthy. Not suppressible by a
  "don't ask again" checkbox. *(Amended:)* a **per-click ⌥** may skip the confirmation — holding
  the modifier *is* the assertion the dialog asks for, made once per window, remembered never —
  and the modifier is read at click time, not from a display monitor that may be a frame behind.
- **F4.11** Session operations: new, rename, kill, detach-others, detach-this-client. New session
  deliberately puts no dialog between wanting a shell and having one: the start directory and
  optional initial command are **host properties**, resolved on tmux's side (a remote-only path
  works; there is no folder picker because one could only browse this machine).
  The initial command goes last on the `new-session` line — tmux stops reading flags at the first
  non-flag word — and is quoted whole, because the far-side shell parses it.
  *(Amended:)* **where things start is stated, never inherited.** A session starts in the host's
  start directory, or in `$HOME` when it has none — as `-c`, on every path that can create one,
  the connect line included. A **tab or split starts where the pane it came from is**, as
  `-c '#{pane_current_path}'`. Both replace a tmux default that inherits: with no `-c`, a session
  takes the *attached session's* directory and a window takes its *own session's*, so every shell on
  a host ended up where its first session happened to open — `/` for a `.app` launched from Finder.
  `~` is expanded by tetmux (to `#{HOME}`, which the far side answers) and not by tmux, which does
  not expand a tilde in `-c` and instead falls back to `$HOME` when the literal path is missing —
  indistinguishable from having worked, and why v2.1 claimed it did.
- **F4.12** *(Rewritten — both halves of v2.0's row are superseded by decisions.)* macOS window
  tabbing is **off** (`allowsAutomaticWindowTabbing = false`): a row of macOS tabs directly above
  the tab bar of tmux windows — the tabs this app is about — was confusion shipped as a feature,
  and ⌥-clicking a session asked for a window and got a tab. There is **one kind of window**:
  tear-off is "Open in New Window" (an ordinary window seeded to a session), and merge-back does
  not exist. Restoration is `workspace.json` alone, not macOS state restoration: entries are
  written debounced during the session, on window close, and synchronously on quit, so crash and
  reboot recovery already fall out of relaunch — the system mechanism would add only the debounce
  window's worth of fidelity, for a second source of truth.

### 4.3 Connection lifecycle and recovery

**Framing:** tmux *is* the persistence layer. The server keeps running when the network drops. The
application persists **view state** — which windows pointed at which host and session — not
session contents.

- **F4.13** Disconnection detected by PTY EOF, `%exit`, or `ServerAlive` failure. **`%exit` is the
  only thing separating "the session ended" from "the link died"**: a dropped connection is EOF
  with nothing first; tmux ending a client always announces it. Treating a deliberate close as a
  network blip recreates, with a fresh window, the session the user just closed. A dead channel is
  not noticed promptly (~45 s of `ServerAlive`), and writes into the pty succeed all the while —
  so the panes-are-a-snapshot state is surfaced with a banner and a button, and a 10 s
  `display-message` round trip feeds the RTT indicator (F4.29).
- **F4.14** Reconnection uses exponential backoff (1 s → 60 s cap, ±20% jitter) with a circuit
  breaker after 8 consecutive failures, then manual retry. The backoff is for a connection that
  **dropped**, not one that never started: authentication failures and user-initiated connects
  that fail before a handshake are not retried — the user is standing there to read the reason,
  which goes on screen with Retry beside it. An explicit connect clears the breaker. A pending
  backoff is a task, and deliberate disconnect cancels it — a host the user closed must not
  reconnect a minute later and raise a password prompt.
- **F4.15** Reconnection **never creates** a session; a user click never lands on a remembered
  name. The backoff path attaches; if the server restarted while the link was down, creating would
  manufacture an empty session under the remembered name and present it as the user's. A click
  goes through targetless `attach-session` (which cannot create) and only creates when the server
  has nothing at all. When the attached session is *gone* (its `%exit` observed), the window
  enters a "session gone" state offering recreation by name on explicit user action — the ended
  name is carried on host state and gated per window, so a second window on another session of
  the same host gets no offer to recreate somebody else's — distinct from "not connected".
- **F4.16** On reattach, visible panes repaint via `capture-pane -p -e -J -S -<N>`, N bounded
  (default 2000 lines). Non-visible panes repaint lazily on first display. Pane subscriptions are
  a registry of what is on screen, not a property of the connection — they survive teardown, and
  the next handshake repaints them.
- **F4.17** Stale clients are reconciled on every attach. tmux has no settable client name
  (`client_name` *is* the tty — verified), so the tag is `client_control_mode`: an orphan is a
  control-mode client whose tty is not one of ours, which requires each channel to learn its own
  `#{client_tty}` before `list-clients` answers — a FIFO-ordering guarantee. The pass is skipped
  while any channel of the host has not answered, because a handshaking follower is
  indistinguishable from an orphan. Ordinary `tmux attach` terminals are never candidates. Known
  blast radius, accepted: two live tetmuxen against one server detach each other, as would
  iTerm2's tmux integration. Without this, an orphaned client clamps every window toward 80×24 —
  the single most common failure mode in applications of this class.
- **F4.18** **Sleep/wake and network changes drive reconnection directly**, not timeouts:
  `NSWorkspace.didWakeNotification` and `NWPathMonitor`, comparing available *interfaces* as well
  as the satisfied flag — Wi-Fi to a different Wi-Fi never reports `.unsatisfied` and is exactly
  when an unreachable host becomes reachable. Closing the lid on a train and reopening it at the
  office should restore every session in under two seconds without user action.

### 4.4 Input and keyboard policy

macOS-only removes most of the difficulty: `Cmd` chords do not collide with readline, Emacs, or
tmux's prefix.

- **F4.19** A documented, editable keymap defines exactly which chords the application intercepts.
  The default set is `Cmd`-based only, and **a rebind must contain ⌘** — enforced in the recorder
  and again when a hand-edited `settings.json` is applied — because F4.20's promise is only true
  while the app lives entirely in `Cmd` space. A taken chord is refused, not resolved. The keymap
  persists as the difference from the defaults; an explicit `null` is a deliberate unbind.
- **F4.20** Launcher hotkey: `Cmd+K`. Safe, because `Ctrl+K` (kill-line) is untouched.
- **F4.21** A "send next chord literally" escape (`Cmd+Alt+V`) so any intercepted binding can
  reach the pane. This requires the app's one `NSEvent` monitor — menu key equivalents resolve
  before any view sees the event, so no view-level hook can let ⌘K through to a pane running fzf —
  and the armed chord is delivered to the pane directly, never re-dispatched. The armed mode is
  visibly indicated.
- **F4.22** A single policy module is consulted by every surface, the event monitor included. No
  ad-hoc key handling in views.
- **F4.23** Mouse wheel scrolls local scrollback when the pane's application has not enabled mouse
  reporting; when it has (SGR 1006), events are forwarded. Determined per-pane from parsed mode
  state. *(Delegated to SwiftTerm; must be pinned by a test — §2.3.)*
- **F4.24** Full IME support, including marked-text composition and dead keys. *(Delegated to
  SwiftTerm's `NSTextInputClient`; must be pinned by a test — the app subclasses the view and
  runs an event monitor ahead of dispatch, neither written with composition in mind.)*

### 4.5 Fuzzy launcher

- **F4.25** One overlay searching hosts, sessions, and windows, ranked by recency. Selecting a
  window attaches and focuses it, connecting the host first if needed.
- **F4.26** Usable while a host is unreachable — cached topology shown greyed with a
  "will connect" affordance.

### 4.6 Passthrough fallback mode

- **F4.27** For servers below the control-mode floor, one attached tmux client renders in a single
  terminal surface with tmux's own UI visible; GUI splits are disabled; the sidebar still provides
  discovery and launching; the mode is clearly indicated. **Passthrough is a different channel,
  not control mode with features off**: no codec, no pending-command FIFO, no handshake, no flow
  control — everything those exist for assumes a parser on the far end. The version probe *ends*
  the channel and hands over. Geometry inverts (§3.3): the surface is the client's terminal, so
  `TIOCSWINSZ` is the whole mechanism and multiple windows take turns, last one winning, exactly
  as two tmux clients of different sizes do. There is nothing to repaint from, so the channel
  keeps a bounded replay buffer for late-joining views, and it is the one place bytes are dropped
  without owing a repaint. The plain login shell (R3.8's last row, same surface) is **offered,
  never started** — nothing on a host with no tmux persists, and starting one unbidden would
  invent the only promise this mode cannot make.

### 4.7 Status bar and system integration

- **F4.28** Status bar shows, for the focused tab: host, session name, tmux version, RTT, active
  pane's foreground command and working directory.
- **F4.29** RTT measured by timing a `display-message -p ''` round trip over the live channel
  every 10 s. Not ICMP — frequently blocked, and does not reflect the SSH path.
- **F4.30** A menu bar extra listing all known sessions across hosts, attachable without bringing
  the main window forward — and functional when **no** window is open: the app outlives its last
  window, so surfaces that normally hand a request to a window must be able to open one.
- **F4.31** Notification Center alerts for configurable pane events: bell, or `%window-activity`
  on a watched window — the useful half for a long remote job that prints and does not ring.
  Coalesced (one banner per 10 s with an "and N more" body); authorisation asked on first use, a
  refusal not retried. Both halves are shipped: watches are per-window view state in
  `workspace.json`, the on/off pair beside the bell toggle in `NotificationPolicy`. Activity is
  derived from `#{window_activity_flag}` re-read on topology refreshes — nothing announces it, so
  detection may lag until an unrelated refresh fires.

### 4.8 Authentication and interactive prompts *(new in v2.1)*

- **F4.32** The pre-handshake stream is watched for a prompt ssh is *sitting on* — the signal is a
  trailing line with no newline, so a banner that merely mentions a password is ignored. Four
  kinds: **password**, **key passphrase**, **host key**, and **question** (one-time codes, PAM
  challenges, anything a `ProxyCommand` wants). The last two exist because "not classified" must
  not mean "hangs until the watchdog": a host-key prompt ends in `? ` rather than a colon, and an
  unclassified question is believed only after the stream has been quiet, because a read can land
  mid-line. Prompts are published as host state, not folded into the connection-state enum.
- **F4.33** **A secret never enters the command path.** The answer is written to the transport
  directly: it is not a tmux command, an entry in the pending FIFO would misalign every `%begin`
  for the life of the channel, and the pre-handshake outbox would deliver it far too late. One
  *secret* per channel — a rejected password resubmitted is how accounts get locked out — while
  non-secret answers (a host-key "yes") do not consume that budget; a hard ceiling of three
  answers bounds misclassification. The secret is never logged and never enters the pre-handshake
  transcript, which is shown verbatim on failure.
- **F4.34** A **host key** prompt is a decision, not a text field: ssh's own lines verbatim,
  fingerprint included, Cancel as the default button, **no "always trust"**. This is not §2.3's
  forbidden auto-accept — it puts ssh's question in front of the person who must answer it. A
  *changed* key never arrives here: ssh refuses it outright rather than asking. Questions are
  shown verbatim, answered, never stored, never filled from the Keychain.
- **F4.35** Everything that can hang has a bound: a handshake watchdog (~45 s) covers a blocking
  MOTD or hung `ProxyCommand`; the pre-handshake outbox is capped, dropping oldest; awaited
  commands time out, and every path that could strand a waiter resumes it. The failure of an
  unbounded wait is "Connecting…" forever, which is the worst diagnostic there is.

### 4.9 Reaching a session without tetmux

- **F4.36** Any session can be copied as the **command line that reaches it from a shell** —
  offered on the session's context menu and in the showing window's toolbar. It is deliberately
  *not* any invocation this application makes: those all spawn `tmux -CC`, and a person pasting one
  gets a screenful of `%output` in a terminal they cannot type into. One rule decides what it
  carries — anything that says how to *reach the host* is in (destination, non-default port, the
  user's own ssh options, which is where a `ProxyJump` or `IdentityFile` lives), anything belonging
  to tetmux's own channel is out (`ControlMaster` is this app's socket, the forwards are already
  bound by the connection it holds open, `-X` is not about getting there). `-t` is not optional:
  tmux refuses to attach without a tty and ssh gives none when handed a command. A host reached by
  a wrapper is described by that wrapper. Values are quoted only where a shell needs it, so the
  line reads as something a person would have typed. It is built from the host's configuration and
  needs no channel, so a session found by discovery (F4.4) on a host nothing is attached to can
  still be copied.

---

## 5. Terminal fidelity contract

Exact, testable commitments. Violations produce visible corruption under tmux.

- **T5.1** `TERM` advertised to panes: `xterm-256color`; `tmux -CC` invoked with `-2 -u`.
- **T5.2** Truecolor (24-bit SGR) supported end to end. *(Asserted on both paths a pane's bytes
  arrive by — `%output`, where tmux's octal escaping is what turns `\033` back into an introducer,
  and `capture-pane -e`'s raw result lines, which is how a reattached pane is repainted. On the
  cell's colour, so a downsample to the 256-colour palette fails rather than looking plausible.)*
- **T5.3** SGR-1006 mouse reporting forwarded correctly so mouse-driven TUIs work inside panes.
- **T5.4** Bracketed paste honoured.
- **T5.5** OSC 8 hyperlinks rendered and clickable — and plain-text URLs too, via the emulator's
  implicit matcher, pinned by a test. Both routes go through one scheme allowlist (`http`,
  `https`, `mailto`, `ftp`): pane contents are remote text, and the system opens whatever
  application claimed a scheme.
- **T5.6** **OSC 52 clipboard writes denied by default**, gated behind a per-host opt-in — a
  `HostConfig` field, deliberately not an application-wide one: trusting the machine on your desk
  is a different decision from trusting a shared box you ssh into. A missing key means denied, so
  files written before the field existed get the safe answer. Clipboard *reads* by remote hosts
  are never permitted.
- **T5.7** Correct Unicode 15+ width and grapheme cluster handling, including emoji ZWJ sequences
  and CJK. Under control mode a desynchronised grid corrupts pane geometry rather than merely
  looking wrong. *(Delegated to SwiftTerm; pinned by the §8 width corpus — real-byte
  CJK/combining/ZWJ fixtures replayed against the grid — and by the program-level half beside it,
  where `vim`, `less`, a timed repaint and a Powerline prompt are replayed and compared cell for
  cell with tmux's own rendering of the same bytes.)*
- **T5.8** Font ligatures off by default, behind a setting.

---

## 6. Performance requirements

- **P6.1** Keypress → glyph, local session: ≤ 12 ms at p95 **on a display refreshing at 100 Hz or
  faster**; on a slower panel, ≤ one refresh interval + 2 ms. *(Amended 2026-08-06 against
  measurement.)* The original figure named no display and was therefore unmeetable by any
  application on the hardware most of this one runs on: at 60 Hz a frame is 16.7 ms, so a 12 ms
  budget is spent before the compositor has had a chance to present anything. Measured across four
  configurations, the wait for a frame is the whole of the residual — 11.54 ms p95 on a fixed-rate
  100 Hz external monitor, 14.28 ms on the built-in 60 Hz panel, 17.84 ms on that panel on
  battery, with the protocol under 2 ms in every one. **Met on both displays as of 2026-08-06**,
  once the rate was measured rather than assumed: the panel is a fixed 60 Hz (verified — every one
  of its 18 modes is 60.0 Hz), so its bound is 18.67 ms and all three figures are inside it.
  So the number that judges a **change** is the part the application controls: **keypress → the
  echoed bytes reaching the emulator ≤ 3 ms at p95**, which is what `Scripts/measure-latency.sh`
  reports as the echo column and what caught the 8 ms coalescer. The end-to-end figure is recorded
  with its display beside it or it means nothing.
- **P6.2** Keypress → glyph, remote session: ≤ RTT + the P6.1 budget for the display in use, at p95.
- **P6.3** Sustained `%output` throughput ≥ 50 MB/s on one pane without reordering or blocking the
  main thread. *(Amended:)* bytes may be **dropped only where a repaint repairs them** — a
  dropped chunk is never handed to the emulator as a hole in the stream. Passthrough is the one
  documented exception (§4.6): it has no repaint to owe, and a bounded replay buffer is the
  fallback.
- **P6.4** Byte handoff from transport to surface is batched per display frame (ProMotion-aware).
  Never one dispatch per read. **Met 2026-08-06, and not amended although it bought nothing.** tmux
  emits 21 934 `%output` chunks a second for a busy pane — 219 per display frame at 100 Hz — and the
  surface now feeds the emulator exactly once a frame, verified by counting rather than assumed.
  CPU was 108.2% of one core before and 106.9% after: the dispatch is not where the time goes, since
  SwiftTerm's per-byte work costs the same however few calls deliver the bytes. The requirement was
  achievable and cheap, so it was met rather than rewritten to match the tree — that distinction is
  the one below. The first handoff after a quiet moment is **not** batched, which is what keeps P6.1
  intact (11.51 ms p95 before, 11.37 after).
- **P6.5** Backpressure enforced end to end, and *(amended)* the mechanism is specified because
  three parts of it are easy to get wrong. Output is bounded **in bytes per subscriber** — never
  delegated to a stream's element-count buffering, because chunk sizes vary by orders of
  magnitude and a buffer deep enough for `cat` never trips for a chatty pane. The **slowest
  viewer** of a pane decides: above a high watermark the owning client is sent
  `refresh-client -A '%p:pause'`, below a low watermark it resumes, and the gap between the two
  is deliberate — one threshold pause/resumes on alternate chunks, and each resume costs a full
  `capture-pane`. A dropped chunk comes **off the books**, or accounting wedges the pane paused
  forever. A pane tmux paused on its own (`pause-after`) is ours to resume — nothing else will —
  and needs its own hold-down rather than the viewer's watermark. Below tmux 3.2 there is no
  pause, and the byte ceiling is the entire mechanism.
- **P6.6** Idle CPU with 20 panes across 4 hosts: < 0.5% of one core. There is no polling except
  the menu-bar modifier display, which runs only while a menu is open. Verify with Instruments on
  battery — sustained wakeups matter more than average CPU. **Not amended, and the cause is now
  known.** Measured at 1.83% on battery and 0.48% on AC, the miss was a spike every ten seconds:
  F4.29's round-trip reading is a field on the diffed `HostState`, so every probe answer was a state
  change and every state change rebuilt a SwiftUI tree holding every pane. Isolated by suppressing
  only the write while still sending the probe, then fixed by publishing the reading on a channel of
  its own with one leaf view reading it. On 12 panes: mean 0.45%/0.71% with spikes to 5.4% before,
  **0.04% with nothing above 0.8%** after. Re-run on the arrangement this requirement names — 20
  panes, 4 hosts, on battery — it **passes**: mean 1.83% became **0.14%** and the maximum 13.9%
  became 2.10%, with the ten-second cadence gone rather than reduced. The wakeup half is met with
  room — package idle exits are ~0/s.
- **P6.7** Resident memory, *(amended 2026-08-06 against measurement)*, is bounded **per pane**
  rather than as a single total: **< 90 MB with one pane** at default scrollback (10 000
  lines/pane), and **< 30 MB for each additional pane**. Twenty panes therefore sit near 600 MB,
  and that is the honest consequence of a 10 000-line default rather than a regression.
  The original "< 150 MB with 20 panes at default scrollback (10 000 lines/pane)" contradicted its
  own parenthesis: a pane's scrollback measures ~25 MB at that depth (72 MB with one pane, 547 MB
  with twenty — ~47 bytes per cell, in the emulator's buffer), so the two halves of the sentence
  could not both hold. The bound is restated in the form that can actually be checked and that
  fails for a reason somebody can act on: a base cost and a marginal cost. Anyone wanting the old
  total back is choosing a smaller default scrollback, and should say so by changing that number.
  **Warm** launch to interactive: < 400 ms *(amended 2026-08-06; the original said cold)*. Measured
  268–288 ms across two sets of runs, so it **passes**. A cold launch is recorded rather than
  bounded: 898 ms median, spread 579.7–1012.3, and 1192 ms for the first launch of a freshly linked
  binary, which is the shape of a first launch after install.
  Two things justify the amendment, and only the second is a judgement. The first is that the
  original number was never measured against the program: a third of every traced figure was the
  instrument — under Instruments' App Launch template `Process Creation` is ~290 ms for tetmux and
  413 ms for **Calculator**, with no main-thread samples in it at all — so what the 400 ms floor had
  been failing against was partly `xctrace`. Timed by the application itself from the kernel's
  `p_starttime` to the first frame, warm was inside the floor all along.
  The second is that **cold is not tetmux's number to move**. The page cache is worth ~630 ms of it,
  and the only phase that grows when the cache is emptied is AppKit Scene Creation, which holds no
  hot spot and no tetmux symbol — class realization, category attachment, bundle localization scans,
  the font registry, asset lookups, spread thin across AppKit, libobjc, CoreFoundation, libswiftCore,
  SwiftUI, CoreUI and dyld. Buying it back means building a first frame that touches fewer framework
  subsystems, which is open-ended work against a cost paid once per boot or once per install. **The
  owner's judgement is that ~1 s there is good enough** (§1: this is a tool for one person's daily
  use), and a requirement nobody intends to meet is worse than one that says what is actually
  promised. This amendment is therefore **not** the same kind as the other two in this section: P6.1
  and the memory total were incoherent as written, while this one was achievable in principle and was
  given up on purpose. If the cold figure is ever chased, the target is that 210 ms, and the record
  of what has already been ruled out is in `docs/measurements.md`.

Verification is **local and scripted**, not CI *(amended — §8)*: the R3.6 matrix set the
precedent that a measurement worth trusting is a reproducible local artefact, and a hosted runner
measures the runner. The harness exists — `Scripts/measure-latency.sh`,
`Scripts/measure-throughput.sh`, `Scripts/measure-launch.sh` and the `Scripts/measure-idle.md`
procedure — and every figure it has produced is in `docs/measurements.md` with the machine, the
display and the power state beside it. As of 2026-08-06, after a second pass and the launch
amendment above, **every requirement in this section is met**: P6.1 passes on both displays, with the
built-in panel's rate now measured at a fixed 60 Hz rather than assumed; P6.3 passes with 6.5× of
room; P6.4 is met and verified by counting; P6.6 passes on the 20-pane, 4-host, on-battery
arrangement it names; and both halves of P6.7 pass their amended bounds. Nothing in §6 has an entry
in `TODO.md`.

Three of these numbers were amended *because* they were measured, which is the process working rather
than a retreat — but they are not all the same move, and the difference is the part worth keeping.
P6.1 named no display and was unachievable at 60 Hz by any application; P6.7's memory total
contradicted its own scrollback parenthesis. Those two were **incoherent**, and restating them cost
nothing that was ever really promised. P6.7's launch half is the third and is different in kind: cold
launch was a coherent, achievable target that was **deliberately given up**, because the 630 ms at
stake is framework first-use rather than tetmux's code and the owner judged the work not worth it.
Recording which of the two a given amendment is, is what keeps the section from becoming a list of
whatever turned out to be easy. The ones that were merely unmet were left alone and then met — P6.4
and P6.6 both.
**And two of the four original misses were the harness**: P6.7's launch figure was a third `xctrace`,
and P6.6's rerun threw away an arm that had measured window occlusion. A performance harness gets
something badly wrong before it is right, and the wrong answer looks exactly like a finding — the
same lesson P6.3's first 23 MB/s taught.

---

## 7. UI specification

Native macOS throughout: vibrancy sidebar, standard full-screen and Stage Manager behaviour,
system-following light/dark appearance with accent colour respected — colours composited from
system colours, never hard-coded literals that invert wrongly in dark mode. Chrome typography: the
system font. Terminal typography: user-selected monospace. Custom glyphs are drawn where SF
Symbols' per-symbol stroke tuning would make neighbours optically mismatched.

Density matters more than decoration: the sidebar's job is to show twenty sessions across five
hosts without scrolling. Row height and information hierarchy are tuned against that case, not a
screenshot with three sessions.

Accessibility is a requirement, not an afterthought: VoiceOver labels on all sidebar and tab
elements; Reduce Motion honoured at every animation site (keep the outcome, drop the movement);
Increase Contrast resolved through one policy module every site asks, so amplified signals stay in
step; `differentiateWithoutColor` answered per-site, because the replacement channel is
necessarily different at each (a word beside the RTT dot, a filled chip behind an armed button).
The terminal viewport is readable by VoiceOver; announcing new output is parked (`TODO.md`).

Every state has a defined visual: connecting, degraded/passthrough, reconnecting, session-gone,
tmux-too-old, tmux-missing, host-key, agent-locked. Error surfaces show the underlying `ssh` or
`tmux` message, not a paraphrase — a channel that dies before tmux speaks shows its pre-handshake
transcript verbatim. A command the user asked for that fails says so (a labelled banner); internal
commands cope silently, because a `resize-window` an old server refuses is ours to handle, not a
sentence to put in front of somebody.

---

## 8. Testing strategy *(revised in v2.1)*

- **Fixture replay** for `ControlCodec` across the tmux version matrix (R3.6), CI-enforced on
  macOS. The fixture suite runs on Linux too: the Ubuntu job builds `tetmuxCore` and runs
  `tetmuxCoreTests`, which is the §2.4 hedge being exercised.
- **Version-matrix integration**, *replacing v2.0's Docker prescription*: the matrix build already
  produces real 3.0–3.5 binaries locally in about a minute each; pointing the existing
  integration suite at each of them covers old-version *behaviour* with no container and no sshd
  image. The suite must **fail, not skip**, when its preconditions are absent — a skipped test is
  indistinguishable from a passing one in a green check, and that rule is CI-enforced.
- **Integration against the real thing**: `SessionIntegrationTests` drives a real PTY against the
  real tmux server, creates and kills uniquely-named sessions, and deliberately forks many
  children concurrently (the fork-safety regression fails as a hang). The password path runs end
  to end against a fake-ssh script that prompts on a pty and then execs tmux, so
  detect → publish → answer → handshake is exercised without a password-accepting host.
- **Chaos tests** *(built)*: killing the channel mid-stream and `SIGSTOP`ping the server run in the
  integration suite; severing the ControlMaster socket runs opt-in behind `TETMUX_SSH_HOST`; and
  sleep/wake is tested at its seam — a test cannot suspend the machine, so the link is killed while
  the host is "asleep", the backoff is allowed to park a retry far enough out to be told apart from
  a wake, and `probeAllConnections()` is called. What that asserts is **promptness**, not recovery:
  a dropped link comes back on its own, so a wake test that only asserted reconnection would pass
  with the wake path deleted. `NSWorkspace.didWakeNotification` itself is AppKit's and is wired up
  in `AppModel`; it has no seam and is not covered. Each scenario must leave the app in a defined
  state and recover.
- **Geometry regression suite** *(built)*: layout strings with expected trees, and a seeded
  50-resize storm asserting convergence on tmux's final layout.
- **Rendering acceptance** *(built)*: the CJK/emoji width corpus makes T5.7 asserted rather than
  assumed, and `vim`, `htop`, `less` and a Powerline prompt are replayed from recorded byte streams
  and checked against a reference terminal's grid. **The reference terminal is
  tmux's own emulator**, deliberately: what the app depends on is not correctness against some third
  terminal but that these two build the same grid from the same bytes, since it asks tmux for a
  column count and then renders the layout tmux computes from the answer. Both halves come from one
  recorded run of one pane (`Scripts/capture-programs.py`), so the stream and the grid describe the
  same instant. `top` is recorded beside `htop`, since `htop` is not on a Mac by default and the
  timed-repaint case should still be coverable without it; both are restricted to a single process,
  so a fixture is a record of a program rather than of one desktop.
- **Latency and throughput measurement** *(amended)*: local, scripted, reproducible — not CI.
  Assert P6.1 and P6.3 with a harness a human runs on real hardware and records, the same
  provenance model as the fixture matrix.
- Protocol fixtures are **captured, never hand-written**: when fixing a protocol bug, add the real
  bytes. The details a plausible fake gets wrong are exactly the ones detection depends on — true
  of the tmux captures and the OpenSSH prompt fixtures alike.

---

## 9. Implementation phases — historical record

All phases are complete or superseded; this section is kept for the record and for the spike
answers, which remain binding.

- **Spike 1 (terminal surface)** resolved to **SwiftTerm** (§2.3). The libghostty path was not
  taken; the swappable-backend protocol was withdrawn in favour of pinning tests.
- **Spike 2 (multiplexing semantics)** resolved to **one client per displayed session** — a single
  channel per host cannot animate two sessions, because `%output` flows only for the attached one.
  The primary/follower architecture in §3.5 is the consequence.
- **Spike 3 (transport)** validated `ssh -tt` + `ControlMaster` + `tmux -CC`, including
  socket-death and sleep/wake behaviour.

The phase ordering (protocol codec before UI, local before SSH, input policy before polish) worked
as designed and is the recommended shape for any comparable effort.

---

## 10. Principal risks — historical record, updated

| Risk | Status |
|---|---|
| libghostty integration effort | Resolved: SwiftTerm chosen (Spike 1); risk retired |
| Control-mode protocol edge cases across versions | Mitigated: five-version fixture corpus replayed in CI; integration suite runs across the built 3.0–3.5 binaries, weekly in CI, on demand, and on every release tag, where it blocks the .dmg |
| Geometry desync between GUI and tmux | Mitigated architecturally (§3.3); live-resize suppression shipped (`LiveResizeGate`) |
| Orphaned clients clamping window size | Mitigated (F4.17), with tests; known blast radius documented |
| `send-keys` round-trip latency under fast typing | Mitigated and **measured**: coalescing now flushes on the leading edge, and the round trip is under 2 ms p95 (P6.1); buffer-based paste |
| **Display refresh dominates perceived latency** *(new)* | Accepted: with the protocol under 2 ms, keypress→glyph is one frame. P6.1 amended to name a refresh rate, and passes on both displays; a fix would have to schedule drawing differently |
| Old tmux in institutional environments | Mitigated: passthrough shipped as a distinct channel (§4.6) |
| **SwiftTerm dependency drift** *(new)* | Behaviour tetmux relies on but does not implement is pinned by tests, the F4.23/F4.24 pins included |
| **Unsigned distribution** *(new)* | Accepted by decision (§2.5): a one-time right-click → Open, stated at the download. Revisit if an account arrives or the friction lands on somebody else |
| macOS-only limits reach | Accepted deliberately; §2.4 hedge CI-enforced |
