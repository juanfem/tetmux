# System Requirements Document — tmux Control-Mode Session Manager (macOS)

**Version:** 2.0
**Status:** Design baseline for implementation
**Platform:** macOS 14+ (Apple Silicon primary, Universal binary)

---

## 1. Product definition

A native macOS application that presents local and remote `tmux` servers through a graphical interface. tmux windows appear as application tabs; tmux panes appear as application splits. Sessions on any configured SSH host are discoverable, attachable, and survivable across network interruptions from a single window.

The application is a **tmux client**, not a terminal emulator that happens to run tmux. It speaks tmux control mode (`tmux -CC`) and renders the resulting model natively. tmux's own status bar, pane borders, and window list are never displayed — the GUI replaces them.

### 1.1 What this is for

The target user runs long-lived work on several remote Linux machines from a Mac and currently juggles nested tmux prefixes, forgotten session names, and terminal tabs whose contents they cannot identify without attaching. The product's value is that the session topology of every machine you use is visible at once, and that reconnecting after a dropped VPN or a closed laptop lid is instant and lossless.

### 1.2 Non-goals

- **A Linux or Windows GUI.** The application connects *to* Linux; it does not run there. See §2.4 for the portability hedge that keeps this reversible at low cost.
- A general-purpose terminal emulator. There is no "open a plain shell" mode except as a debugging affordance and as part of the fallback path in §4.6.
- Editing the user's `tmux.conf`, `ssh_config`, or dotfiles.
- Serial, telnet, Docker, or Kubernetes transports.
- File transfer, SFTP browsing, or port-forward management UI.
- Mac App Store distribution (see §2.5 — the sandbox makes it impossible).
- Any AI or agent features.

---

## 2. Architecture

### 2.1 The central abstraction

Everything reduces to one concept: **a control-mode channel** — a bidirectional byte stream on which the tmux control protocol is spoken. Local and remote differ only in how that stream is created:

| | Channel creation |
|---|---|
| Local | `forkpty` + `exec` of `tmux -CC attach -t <target>` |
| Remote | `forkpty` + `exec` of `ssh -tt <host> -- tmux -CC attach -t <target>` |

A PTY is allocated in both cases; tmux refuses to attach without a terminal, and `ssh -tt` forces allocation even when stdin is not a tty. The PTY is put in raw mode and `\r` is stripped before parsing.

Because the transport difference is confined to process spawning, **all session logic is written once**. There is no "remote code path."

### 2.2 Layers

```
┌──────────────────────────────────────────────────────────┐
│  AppKit / SwiftUI                                        │
│  Sidebar · Tab bar · Split tree · Launcher · Status bar   │
│  One terminal surface (NSView) per tmux pane              │
└───────────────────────▲──────────────────────────────────┘
                        │  @MainActor observation
┌───────────────────────▼──────────────────────────────────┐
│  SessionService (actor)                                  │
│  ServerModel · WindowModel · PaneModel · reconnect FSM   │
└───────────────────────▲──────────────────────────────────┘
                        │  AsyncStream<ControlEvent> / command queue
┌───────────────────────▼──────────────────────────────────┐
│  ControlCodec   ◀── PURE VALUE TYPE, NO I/O, FIXTURE-TESTED│
└───────────────────────▲──────────────────────────────────┘
                        │  bytes
┌───────────────────────▼──────────────────────────────────┐
│  PtyTransport (tmux | ssh -tt → tmux)                     │
└──────────────────────────────────────────────────────────┘
```

Everything below the top layer is plain Swift with no AppKit dependency.

### 2.3 Technology stack

**Swift 6, AppKit for window/tab/split structure, SwiftUI for sidebar, launcher, settings, and inspector.** Not Electron. The reasoning that previously favoured a webview — that the terminal core is the expensive part of "native" and only web tech gives you a mature one for free — no longer holds, because `libghostty-vt` now exists as a shipped, embeddable dependency. What remains of the native cost is chrome, and AppKit gives that back with real vibrancy, real menus, real accessibility, sub-50 MB residency, and input latency that a compositing browser engine cannot match. For a keystroke-in-glyph-out application, that last point is the product.

**Terminal core: libghostty.** Ghostty's terminal engine is available as an embeddable library — VT sequence parsing, terminal state (cursor, styles, reflow, scrollback), and renderer state, extracted from Ghostty's production core with SIMD parsing and its Unicode implementation. There is a SwiftPM wrapper (`GhosttyKit`) around Ghostty's macOS XCFramework.

Critical scoping note: **libghostty-vt provides no drawing or windowing code.** Tabs, splits, and window management are explicitly the embedder's responsibility — which is fine, because those are exactly what this application wants to own. What is *not* yet certain is how much rendered-surface functionality the macOS XCFramework exposes versus how much Metal drawing must be written against the render-state API. **This is Phase 0, Spike 1** (§9) and the answer determines several weeks of scope.

**Fallback if that spike goes badly: SwiftTerm.** A mature AppKit `NSView` terminal with a feed-bytes API, already used in shipping macOS/iOS terminal apps. Lower ceiling on rendering performance and Unicode fidelity than libghostty, but it is a known quantity and eliminates renderer risk entirely. The architecture in §2.2 makes the terminal surface a replaceable component behind a `TerminalSurface` protocol; either backend must be swappable without touching the session or codec layers.

**Fit note:** a control-mode client does not need a terminal *emulator* — it needs a terminal *view*. No PTY ownership per pane, no child-process management, no signal handling. Just "here are bytes, give me a grid, draw it." That is a narrower requirement than either library is built for, which lowers integration risk in both directions.

**PTY:** a thin Swift wrapper over `forkpty(3)` and `TIOCSWINSZ`. No third-party dependency is warranted for ~200 lines.

**Concurrency:** Swift structured concurrency throughout. `SessionService` is an `actor`; the codec is a `struct` with `mutating func feed(_:) -> [ControlEvent]`; transports expose `AsyncThrowingStream<Data>`. UI types are `@MainActor`. No callback pyramids, no `DispatchQueue` ad-hockery.

**SSH: the system `ssh` binary, invoked as a subprocess.** Unchanged from the previous design and the decision I hold most firmly. `~/.ssh/config` is not a parseable file format in practice — `Include`, `Match exec`, `ProxyJump`, `ProxyCommand`, canonicalisation, and first-value-wins precedence make faithful reimplementation a multi-month effort that will still be subtly wrong. Delegating to OpenSSH gets certificates, FIDO/`sk-` keys, hardware and 1Password agents, Kerberos/GSSAPI, jump hosts, and `known_hosts` semantics for free and correct. `ControlMaster=auto` with `ControlPersist` makes auxiliary channels to an already-connected host cost milliseconds.

Standard invocation for every host:

```
ssh -o ControlMaster=auto \
    -o ControlPath=~/Library/Application Support/<app>/cm-%C \
    -o ControlPersist=300 \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -tt <host> -- <remote command>
```

The application never passes `StrictHostKeyChecking=no` and never auto-accepts a host key. Verification prompts and failures are surfaced verbatim from `ssh`'s stderr.

**Persistence: JSON** in `~/Library/Application Support/<app>/` — `hosts.json`, `workspace.json`, `settings.json`. Not SQLite, not SwiftData. The stored data is a host list, a tab/split layout, and preferences; a database buys nothing and costs human-readability, which this user population values.

**Credentials: never stored by the application.** Authentication is entirely `ssh`'s responsibility.

### 2.4 Portability hedge

Everything below the UI layer — `ControlCodec`, `SessionService`, `PtyTransport`, the models — must compile on Linux Swift with no AppKit or Foundation-for-Darwin dependencies, and CI must build that target on Linux even though nothing consumes it. This costs almost nothing to maintain and preserves the option of a future GTK or Linux shell without a rewrite. It also has an immediate benefit: it forces the UI-independent layers to be testable headlessly, which is where most of the value is.

### 2.5 Distribution

Developer ID signed, notarised, hardened runtime, distributed outside the Mac App Store — via direct download and Homebrew cask. **App Store distribution is impossible**, not merely inconvenient: the sandbox forbids spawning `/usr/bin/ssh`, reading `~/.ssh`, and connecting to the user's SSH agent socket. Do not design around a future sandboxed build. Sparkle for updates.

---

## 3. Control-mode protocol layer

The highest-risk component, and the one most likely to be implemented sloppily.

### 3.1 Requirements

- **R3.1** `ControlCodec` is a pure value type: `mutating func feed(_ bytes: some Sequence<UInt8>) -> [ControlEvent]`. No I/O, no processes, no timers, no `async`. It must be unit-testable with nothing running.
- **R3.2** Correct block framing (`%begin <ts> <num> <flags>` … `%end` / `%error`), associating each response with its originating command via the command number.
- **R3.3** Handles at minimum: `%output`, `%extended-output`, `%layout-change`, `%window-add`, `%window-close`, `%window-renamed`, `%window-pane-changed`, `%session-changed`, `%session-renamed`, `%sessions-changed`, `%unlinked-window-*`, `%client-detached`, `%pause`, `%continue`, `%exit`. Unknown `%`-prefixed lines are logged and ignored, never fatal — tmux adds notifications between versions.
- **R3.4** Octal escape decoding in `%output` payloads is correct for all byte values including embedded newlines and NUL. Operates on bytes, never on `String`.
- **R3.5** Layout strings (e.g. `bc62,80x24,0,0{40x24,0,0,1,39x24,41,0,2}`) parse into a typed tree with checksum validation.
- **R3.6** Developed against **recorded fixtures**: real byte streams captured from tmux 3.0, 3.2a, 3.3a, 3.4, and 3.5 covering split/kill/resize/rename/copy-mode/detach sequences. Fixture replay runs in CI. Do not develop this layer by manual testing.

### 3.2 Sending input to panes

Under control mode the channel's input side carries **tmux commands, not pane keystrokes**. Keyboard input is delivered with hex-encoded `send-keys`:

```
send-keys -H -t %<pane-id> 68 65 6c 6c 6f
```

Implications:

- Every keystroke is a command with a `%begin`/`%end` round trip. Batch keystrokes per display frame; do not issue one command per key.
- **Paste does not go through `send-keys`.** Large pastes use `load-buffer -b <tmp>` then `paste-buffer -d -t %<pane>` — one round trip regardless of size. A 2 MB paste via `send-keys` will hang the channel.
- Bracketed-paste markers are emitted around paste content when the pane's application has enabled the mode.

### 3.3 Geometry — tmux is authoritative

**R3.7** The GUI never decides pane geometry:

1. The view measures its pixel area and computes a target cell grid from the current font metrics.
2. `SessionService` sends `refresh-client -C <width>x<height>`.
3. tmux responds with `%layout-change`.
4. The view lays out splits from the received layout string and resizes each surface to the cell dimensions tmux reported.

Any implementation that resizes a surface before tmux confirms will drift and corrupt output. Resize requests are debounced ~100 ms and coalesced. Note that this interacts with AppKit live-resize: during `inLiveResize`, suppress channel traffic entirely and repaint on completion.

`window-size` is set to `latest` on attach so other attached clients do not clamp the window.

### 3.4 Version handling and fallback

**R3.8** On connecting, `display-message -p '#{version}'` establishes the tmux version before anything else.

| Version | Behaviour |
|---|---|
| ≥ 3.2 | Full control mode, including `refresh-client -B` subscriptions |
| 3.0 – 3.1 | Full control mode; subscriptions disabled |
| 2.4 – 2.9 | Control mode with reduced features; warn once per host |
| < 2.4 | **Passthrough fallback** (§4.6) |
| tmux absent | Clear error offering a plain shell to that host |

Passthrough fallback is a first-class requirement. Institutional and HPC environments run long-lived old distributions, and an application that refuses to connect to them is useless in exactly the environments where session persistence matters most.

---

## 4. Functional requirements

### 4.1 Host and session sidebar

- **F4.1** A collapsible tree: **Host → Session → Window**. Panes are not tree nodes; they appear in the split view and the pane inspector. A pane is not independently attachable, so listing it in a navigation tree is noise.
- **F4.2** Hosts are populated by asking `ssh` itself — `ssh -G <host>` yields the fully resolved effective configuration. Host *names* for the picker come from a conservative scan of `Host` stanzas (excluding wildcards) plus manual entries in `hosts.json`.
- **F4.3** Per-host state: `disconnected`, `connecting`, `connected`, `degraded`, `reconnecting`, `failed`, with the reason string on hover.
- **F4.4** Lists update from control-mode notifications. **There is no polling loop.** A host with an open channel learns of changes made by other clients within milliseconds. Discovery for a host with no attached session uses a single `tmux -C list-sessions` over the existing SSH master, on demand and on window focus only.
- **F4.5** Each window row shows name, pane count, active pane's foreground command, and an activity indicator derived from `%window-*` notifications.

### 4.2 Tabs, splits, and the workspace

- **F4.6** One application tab = one tmux window. Opening a session opens tabs for its windows; the active tmux window is the active tab.
- **F4.7** Splits mirror the tmux pane layout exactly, including nesting and dimensions, reconstructed from the layout string.
- **F4.8** GUI split/close operations translate to tmux commands (`split-window`, `kill-pane`, `resize-pane`) and apply only when tmux confirms. Dragging a divider issues `resize-pane -x/-y`.
- **F4.9** Closing a tab detaches or unlinks — it never kills.
- **F4.10** Destructive commands require confirmation showing the target's name, pane count, and running commands. Not suppressible by a "don't ask again" checkbox.
- **F4.11** Session operations: new (name, start directory, optional command), rename, kill, detach-others, detach-this-client.
- **F4.12** Native `NSWindow` tabbing; tabs can be torn off into new windows and merged back. Window/tab arrangement participates in macOS state restoration in addition to `workspace.json`.

### 4.3 Connection lifecycle and recovery

**Framing:** tmux *is* the persistence layer. The server keeps running when the network drops. The application persists **view state** — which tabs pointed at which host and session — not session contents.

- **F4.13** Disconnection detected by PTY EOF, `%exit`, or `ServerAlive` failure.
- **F4.14** Reconnection uses exponential backoff (1 s → 60 s cap, ±20% jitter) with a circuit breaker after 8 consecutive failures, then manual retry. Authentication failures do not retry.
- **F4.15** Reconnection **never creates** a session. If the target is gone, the tab enters a "session gone" state offering recreation by name on explicit user action.
- **F4.16** On reattach, visible panes repaint via `capture-pane -p -e -J -S -<N>`, N bounded (default 2000 lines). Non-visible panes repaint lazily on first display.
- **F4.17** Stale clients are reconciled on every attach: `list-clients -F` identifies this application's clients (tagged via a distinctive client name) that are no longer live, and detaches them. Without this, an orphaned client from a dropped connection clamps window size and every pane collapses toward 80×24. This is the single most common failure mode in applications of this class.
- **F4.18** **Sleep/wake and network changes drive reconnection directly**, not timeouts. Subscribe to `NSWorkspace.didWakeNotification` and `NWPathMonitor`; on wake or path change, immediately probe the control socket and reconnect. Closing the lid on a train and reopening it at the office should restore every session in under two seconds without user action. This is the single most visible quality difference between this app and a terminal with tmux in it, and it is much easier to do well natively than in a webview.

### 4.4 Input and keyboard policy

macOS-only removes most of the difficulty here: `Cmd`-prefixed chords do not collide with readline, Emacs, or tmux's prefix, so the application's own bindings can live entirely in `Cmd` space and everything else forwards to the pane.

- **F4.19** A documented, editable keymap defines exactly which chords the application intercepts. The default set is `Cmd`-based only. No default binding uses a bare `Ctrl` chord.
- **F4.20** Launcher hotkey: `Cmd+K`. Safe, because `Ctrl+K` (kill-line) is untouched.
- **F4.21** A "send next chord literally" escape (`Cmd+Alt+V`) so any intercepted binding can reach the pane.
- **F4.22** A single policy module is consulted by every surface. No ad-hoc key handling in views.
- **F4.23** Mouse wheel scrolls local scrollback when the pane's application has not enabled mouse reporting; when it has (SGR 1006), events are forwarded. Determined per-pane from parsed mode state, not globally.
- **F4.24** Full IME support, including marked-text composition, and correct dead-key handling. This is close to free with AppKit's `NSTextInputClient` and was going to be a liability under Electron.

### 4.5 Fuzzy launcher

- **F4.25** One overlay searching hosts, sessions, windows, and commands, ranked by recency. Selecting a window attaches and focuses it, connecting the host first if needed.
- **F4.26** Usable while a host is unreachable — cached topology shown greyed with a "will connect" affordance.

### 4.6 Passthrough fallback mode

- **F4.27** For servers below the control-mode floor, a tab renders one attached tmux client in a single terminal surface with tmux's own UI visible. GUI splits disabled for that tab; the sidebar still provides discovery and launching. The mode is clearly indicated.

### 4.7 Status bar and system integration

- **F4.28** Status bar shows, for the focused tab: host, session name, tmux version, RTT, active pane's foreground command and working directory.
- **F4.29** RTT measured by timing a `display-message -p ''` round trip over the live channel every 10 s. Not ICMP — frequently blocked, and does not reflect the SSH path.
- **F4.30** A menu bar extra listing all known sessions across hosts, attachable without bringing the main window forward.
- **F4.31** Notification Center alerts for configurable pane events (bell, or a `%window-activity` on a watched window). Useful for long-running remote jobs.

---

## 5. Terminal fidelity contract

Exact, testable commitments. Violations of any produce visible corruption under tmux.

- **T5.1** `TERM` advertised to panes: `xterm-256color`; `tmux -CC` invoked with `-2`.
- **T5.2** Truecolor (24-bit SGR) supported end to end.
- **T5.3** SGR-1006 mouse reporting forwarded correctly so mouse-driven TUIs work inside panes.
- **T5.4** Bracketed paste honoured.
- **T5.5** OSC 8 hyperlinks rendered and clickable.
- **T5.6** **OSC 52 clipboard writes denied by default**, gated behind a per-host opt-in. A remote host silently overwriting the local clipboard is a real exfiltration and injection vector. Clipboard *reads* by remote hosts are never permitted.
- **T5.7** Correct Unicode 15+ width and grapheme cluster handling, including emoji ZWJ sequences and CJK. Incorrect widths desynchronise the character grid, and under control mode a desynchronised grid corrupts pane geometry rather than merely looking wrong.
- **T5.8** Font ligatures off by default, behind a setting.

---

## 6. Performance requirements

Native targets, tightened from what a webview could promise.

- **P6.1** Keypress → glyph, local session: ≤ 12 ms at p95.
- **P6.2** Keypress → glyph, remote session: ≤ RTT + 12 ms at p95.
- **P6.3** Sustained `%output` throughput ≥ 50 MB/s on one pane without dropping bytes, reordering, or blocking the main thread.
- **P6.4** Byte handoff from transport to surface is batched per display frame (ProMotion-aware: 8.3 ms at 120 Hz). Never one dispatch per read.
- **P6.5** Backpressure enforced end to end. tmux's `%pause`/`%continue` flow control is used where available; otherwise the read stream is paused when the surface falls behind.
- **P6.6** Idle CPU with 20 panes across 4 hosts: < 0.5% of one core. There is no polling, so this should be achievable. Verify with Instruments on battery — sustained wakeups matter more than average CPU for battery life.
- **P6.7** Resident memory: < 150 MB with 20 panes at default scrollback (10 000 lines/pane). Cold launch to interactive: < 400 ms.

---

## 7. UI specification

Native macOS throughout. `NSVisualEffectView` sidebar with real vibrancy, `NSToolbar`, standard full-screen and Stage Manager behaviour, system-following light/dark appearance with accent colour respected. Icon set: SF Symbols. Chrome typography: the system font. Terminal typography: user-selected monospace with a documented Nerd Font recommendation and a correct fallback chain.

Density matters more than decoration: the sidebar's job is to show twenty sessions across five hosts without scrolling. Row height and information hierarchy should be tuned against that case, not against a screenshot with three sessions.

Accessibility is a requirement, not an afterthought — VoiceOver labels on all sidebar and tab elements, Reduce Motion and Increase Contrast honoured, full keyboard navigability of every control. AppKit makes this cheap; there is no excuse for skipping it.

Every state has a defined visual: connecting, degraded, reconnecting, session-gone, tmux-too-old, tmux-missing, host-key-changed, agent-locked. Error surfaces show the underlying `ssh` or `tmux` message, not a paraphrase.

---

## 8. Testing strategy

- **Fixture replay** for `ControlCodec` across the tmux version matrix. CI-enforced, runs on both macOS and Linux Swift targets.
- **Containerised integration matrix**: Docker images with tmux 3.0, 3.2a, 3.3a, 3.4, 3.5 and an sshd, exercised through the real transport.
- **Chaos tests**: kill the `ssh` process mid-stream; `SIGSTOP` the remote tmux server; sever the control socket; `pmset sleepnow` and resume. Each must leave the app in a defined state and recover.
- **Geometry regression suite**: layout strings with expected view trees, plus a resize storm (50 rapid window resizes, including live-resize drag) asserting convergence with tmux's reported layout.
- **Rendering acceptance**: `vim`, `htop`, `less`, a Powerline prompt, and a CJK/emoji corpus render correctly against a reference terminal.
- **Latency measurement** in CI on real hardware, asserting P6.1. A regression here is a product regression.

---

## 9. Implementation phases

**Phase 0 — Spikes.** Timebox: one week. Three questions answered with running code before anything else is built:

1. **Terminal surface.** Determine exactly what the libghostty macOS XCFramework exposes: a drawable, input-accepting surface, or VT-and-render-state only with Metal drawing left to the embedder. Build a throwaway AppKit window that feeds it bytes and renders them. If the effort looks like more than ~3 weeks, take SwiftTerm instead and record the decision. Either way, define the `TerminalSurface` protocol before Phase 2.
2. **Control-mode multiplexing semantics** on the target tmux versions — specifically, whether one channel per host can serve as both command plane and output plane for multiple sessions, or whether one channel per session is required. `SessionService`'s design depends on the answer.
3. **Transport end to end**: `ssh -tt` + `ControlMaster` + `tmux -CC`, including behaviour after control-socket death and after a sleep/wake cycle.

**Phase 1 — Protocol codec.** Headless, fixture-driven, no UI. Exit criterion: full fixture suite passes and a CLI can print the event stream from a live local tmux.

**Phase 2 — Single pane, local.** One surface bound to one tmux pane over a real local channel. Input via `send-keys -H`, geometry via `refresh-client -C`. Exit criterion: `vim` and `htop` fully usable and surviving resize storms, with P6.1 met.

**Phase 3 — Window and pane model.** Layout tree, tabs, splits, split/kill/resize operations. Local only.

**Phase 4 — SSH transport.** Swap the transport, change nothing above it. Connection state machine, `ssh -G` resolution, error surfacing. Exit criterion: everything from Phases 2–3 works identically against a remote host.

**Phase 5 — Lifecycle.** Reconnect FSM, backoff, client reconciliation, `capture-pane` repaint, sleep/wake integration, workspace persistence. The chaos suite lands here.

**Phase 6 — Sidebar and discovery.** Multi-host tree, notification-driven updates, session/window commands, confirmations.

**Phase 7 — Input policy and launcher.** Keymap module, interception policy, literal-passthrough escape, IME, fuzzy overlay.

**Phase 8 — Passthrough fallback, menu bar extra, notifications, theming, accessibility audit, notarised release.**

Phases 3 and 4 are deliberately ordered so transport bugs and tmux-model bugs are never debugged simultaneously. Phase 7 precedes polish because keyboard policy retrofitted onto an existing UI is invariably wrong.

---

## 10. Principal risks

| Risk | Mitigation |
|---|---|
| libghostty integration effort larger than expected | Phase 0 Spike 1 with a hard timebox; `TerminalSurface` protocol; SwiftTerm as a pre-selected fallback |
| Control-mode protocol edge cases across tmux versions | Fixture corpus from real servers; version floor with graceful degradation |
| Geometry desync between GUI and tmux | tmux-authoritative rule (§3.3) enforced architecturally; live-resize suppression; regression suite |
| Orphaned clients clamping window size | Client reconciliation on every attach (F4.17), with a test |
| `send-keys` round-trip latency under fast typing | Per-frame keystroke batching; paste via buffer commands |
| Old tmux in institutional environments | Passthrough fallback shipped, not stubbed |
| macOS-only limits reach | Accepted deliberately; §2.4 portability hedge keeps a Linux shell viable later at low cost |
