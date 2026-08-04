# TODO

From the audit of 2026-08-04. Ordered by what actually breaks for a user, not by effort.
Each item names the evidence, because the ones that matter here are all silent failures — nothing
in this list announces itself, which is why they survived this long.

29 are done. The line and file references below are as they were when the audit ran, so they point
into the commit before each fix rather than into current `main` — they are kept because the evidence
is the useful part of the entry.

What is left falls into three groups, and they are not equally blocked:

- **Needs credentials or hardware nobody here has.** Developer ID signing and notarisation need an
  Apple Developer account; Sparkle needs somewhere to host an appcast and a key to sign it; the R3.6
  fixture matrix needs tmux 3.0/3.2a/3.3a/3.4/3.5 binaries to capture from. These are decisions
  before they are work.
- **Real features, sized like features.** Passthrough fallback (F4.27), copy mode, an editable
  keymap with a settings file, per-host OSC 52, tab reordering and `move-window`, window/session
  state restoration, and the §8 test infrastructure — a containerised sshd matrix, chaos tests, a
  geometry suite, a rendering corpus, and the P6 latency job.
- **Small and unblocked.** F4.17's stale-client reconciliation, `refresh-client -B` subscriptions,
  the 2.4–2.9 warning, `detach-client`, `ssh -G` resolution, plain-text URL detection, Reduce Motion,
  and a non-ASCII `send-keys` test.

## Protocol correctness

- [x] **Notification dispatch outranks command-block framing.** `ControlCodec.parseLine` tests
  `%output`, `%extended-output`, and the whole `%verb` switch before it consults
  `activeCommandNumber`, which is read in exactly one place — the bare-line branch. So any line
  *inside* a `%begin`/`%end` block that starts with `%` is parsed as a notification. The routine
  damage is loss: `capture-pane` replays scrollback as result lines, and tcsh/zsh's classic prompt
  is `%`, so every prompt line in a repaint falls into `default:` and is dropped from the restored
  screen. The severe damage is forgery: a captured `%exit` sets `serverEnded` and the next close is
  treated as an orderly session end with no reconnect; a captured `%end`/`%error` closes the block
  early; a captured `%output %3 …` injects bytes into a pane. While a block is open, only
  `%end`/`%error` *with the matching number* may leave it.
  `Sources/tetmuxCore/Core/ControlCodec.swift:76-97`

- [x] **Responses are matched positionally and the number that would catch a desync is discarded.**
  `%begin` pops the head of `pending` and throws `commandNumber` away; `%end`/`%error` never check
  it. One lost or spurious block shifts the queue for the life of the channel, silently:
  `capture-pane` payloads land in the wrong pane (with their `ESC[3J`), `list-panes` output reaches
  `applyWindows`, and an internal `resize-window` failure surfaces as "Rename session failed". The
  value needed to detect this already arrives on every block.
  `Sources/tetmuxCore/Session/SessionService.swift:701-716`
  *Correlation is still by order — the numbers are server-wide and cannot be predicted at send time,
  so ordering remains the only thing that can match a response to its command. What was added is the
  integrity check: a `%begin` with nothing pending after the handshake, a terminator closing a block
  it did not open, and a number that fails to increase are logged as a desync. Detecting it is not
  the same as recovering from it, and there is still no recovery.*

- [x] **An `%error` with no matched command is discarded entirely**, message text and all — the one
  case where something already went wrong is the one case that says nothing.
  `Sources/tetmuxCore/Session/SessionService.swift:716`

- [x] **A partial PTY write is reported as a total failure.** The write loop gives up after ~1 s of
  `EAGAIN` with `written > 0`, and `send` reads `false` as "nothing reached tmux" and does
  `pending.removeLast()`. tmux is left holding half a command line with no newline; the next command
  concatenates onto it and answers one block for two. Permanent desync by way of the item above,
  plus a corrupted paste — and this is exactly the path a large paste over a congested link takes.
  `Sources/tetmuxCore/Core/PtyTransport.swift:248-263`, `SessionService.swift:1309-1314`

- [x] **`%extended-output` with no reserved-colon field silently yields empty data** rather than
  failing the parse, so a build that varies the field layout makes every pane go quietly dead.
  `Sources/tetmuxCore/Core/ControlCodec.swift:217-228`

- [x] **`LayoutParser` traps on integer overflow and recurses without a depth cap.** Both are
  reachable from bytes on the wire, and `try?` cannot catch either — a garbled `%layout-change`
  takes the app down.
  `Sources/tetmuxCore/Core/LayoutParser.swift:194`, `:117`

## Zoom

- [x] **Zoomed panes are not handled at all.** `grep -i zoom` over `Sources/` and `Tests/` returns
  nothing. The codec parses `visibleLayout` and `flags` and `SessionService` discards both
  (`case .layoutChange(let windowId, let layout, _, _)`); `windowsFormat` asks for
  `#{window_layout}` rather than `#{window_visible_layout}` / `#{window_zoomed_flag}`. `prefix-z`
  from any client leaves tmux emitting at full-window dimensions while tetmux paints the unzoomed
  grid and forces each surface to its unzoomed cell size: wrapped, truncated, and unrecoverable
  without unzooming from somewhere else. The protocol layer already knows; only the model doesn't.
  `Sources/tetmuxCore/Session/SessionService.swift:749`, `Sources/tetmuxCore/Session/TmuxCommand.swift:101`

## Lifecycle and state

- [x] **⌘Q leaves `window-size manual` on the user's sessions.** The delegate implements only
  `applicationShouldTerminateAfterLastWindowClosed`; `restoreWindowSizePolicy` runs on a deliberate
  per-host disconnect and nowhere else. The teardown is careful enough to wait for tmux's own `%end`
  rather than merely writing the line — and the ordinary way people close a Mac app skips all of it,
  leaving windows that no longer follow the terminal for the next plain `tmux attach` to find.
  `Sources/tetmuxUI/AppMain.swift:122`

- [x] **Reconnect creates sessions (F4.15 says it must never).** `connectHost` defaults to
  `.createOrAttach(sessionName:)` and the backoff passes `mode: nil`. If the server restarted while
  the link was down, the reconnect manufactures an empty session under the remembered name and
  presents it as the user's. Only the `%exit`-observed path avoids this.
  `Sources/tetmuxCore/Session/SessionService.swift:376-380`, `:2004-2007`

- [x] **A corrupt `hosts.json` silently discards every host, then overwrites it.** Both the read and
  the decode are `try?` with no fallback: the user sees their hosts vanish, and the next edit does
  load-modify-save and destroys the file that still had them. No backup, no rename, nothing surfaced.
  `Sources/tetmuxCore/Session/HostConfigStore.swift:110-115`

- [x] **Editing an ssh-config-discovered host never persists.** `saveHosts` filters ids prefixed
  `ssh-`, but `AppModel.saveHost` only assigns a `custom-` id when the id is empty. Forwards and ssh
  options on a discovered host work all session and are gone on relaunch — while the Keychain flag
  survives, so the two then disagree.
  `Sources/tetmuxCore/Session/HostConfigStore.swift:127`, `Sources/tetmuxUI/AppModel.swift:456-458`

- [x] **Nothing bounds connect, handshake, or the version probe.** A blocking MOTD or a hung
  `ProxyCommand` sits on "Connecting…" forever with no error and no retry. Worse: if the probe never
  answers, `connection.version` stays nil, `applyWindowSizePolicy` returns at its first guard, and
  every window resize is dropped silently for the life of the channel.
  `Sources/tetmuxCore/Session/SessionService.swift:365-402`, `:954-1010`

- [x] **Manual disconnect cannot cancel the backoff.** The retry task is fire-and-forget and stored
  nowhere, and `.disconnected.isActive` is false so `connectHost`'s guard does not stop it — a host
  the user deliberately closed reconnects up to a minute later, possibly raising a password prompt.
  `Sources/tetmuxCore/Session/SessionService.swift:2004-2007`, `:568-586`

- [x] **Topology and pane refreshes share one task slot** but run different commands, so a
  `%window-add` arriving just after a `%window-renamed` is dropped: only `list-panes` runs, and a
  window created elsewhere keeps its placeholder name and wrong session until something unrelated
  refreshes. Automatic renames fire constantly, so this is hit often.
  `Sources/tetmuxCore/Session/SessionService.swift:1074-1108`

- [x] **`retireFollower` checks then acts across an `await`.** Tab away from a session and back
  within 2 s and the in-flight retirement tears down the client that the reconcile just decided to
  keep, leaving every pane a frozen still frame with nothing scheduled to fix it.
  `Sources/tetmuxCore/Session/SessionService.swift:499-511`, `:540-549`

- [x] **A server-origin `%pause` is undone immediately.** The handler records the pause and calls
  `applyFlowControl` in the same breath; when the local counter is drained the pane is resumed at
  once, so tmux's own `pause-after` degenerates into a pause/resume cycle with a full
  `capture-pane -S -2000` repaint each time. It needs its own hold-down, not the viewer's watermark.
  `Sources/tetmuxCore/Session/SessionService.swift:855-863`, `:1465-1477`

- [x] **`switch-client` failure leaves `pendingSessionId` set forever**, so `liveSessionIds` keeps
  reporting a dead session as live and the not-attached banner never appears over a frozen window.
  `Sources/tetmuxCore/Session/SessionService.swift:489-492`

- [x] **The pre-handshake outbox is unbounded and replayed in full.** Keystrokes typed while a host
  reconnects queue with no cap and no age limit; combined with the missing handshake timeout, a host
  that finally connects gets minutes of stale input injected at once.
  `Sources/tetmuxCore/Session/SessionService.swift:1299-1304`

- [x] **`%pane-mode-changed` and `%config-error` are unhandled.** Another client entering copy mode
  leaves that pane looking frozen with no way to learn otherwise; a `.tmux.conf` syntax error is
  reported here and nowhere else, so the user sees bindings that silently do not work.

- [x] **Per-pane bookkeeping is never pruned on pane death.** `paneOwners`, `repaintedPanes`,
  `pausedPanes`, `lossyPanes` are released by channel epoch or on `removeHost` only; there is a
  `forgetWindowGeometry` for windows and no pane-level equivalent. Slow monotonic growth on a
  long-lived connection.
  `Sources/tetmuxCore/Session/SessionService.swift:1361-1383`

- [x] **A stale reader thread can read a reused fd.** `terminate()` closes the master fd without
  joining the reader, which is sitting in a 1000 ms `poll` holding the number by value; a reconnect
  can be handed the same fd and have its bytes consumed by the old stream. The deferred `SIGKILL`
  has the same shape against a possibly-reaped pid.
  `Sources/tetmuxCore/Core/PtyTransport.swift:174-205`, `:296-325`

## The terminal a person uses all day

- [x] **Scrollback is 500 lines and is destroyed on every tab switch.** The pane is built with
  `TerminalView(frame:)` and default options, so the scrollback is SwiftTerm's default, never
  chosen. Only the selected window's container exists, so switching tabs dismantles the views and
  the return trip replays a payload beginning `ESC[H ESC[2J ESC[3J` — screen *and* scrollback —
  capped at 2000 lines.
  `Sources/tetmuxUI/TerminalSurface.swift:73`, `Sources/tetmuxUI/AppMain.swift:268-301`

- [x] **⌘F does nothing.** SwiftTerm ships a working find bar, reachable only through the standard
  text-editing menu group that AppKit puts Find in — which is the group replaced with a single Paste
  button. The feature exists in the dependency and was accidentally unplugged.
  `Sources/tetmuxUI/AppMain.swift:54-59`

- [ ] **Copy mode is unreachable and nothing replaces it.** Keys go to the pane via `send-keys -H`,
  so tmux's key table is never consulted and `C-b` lands in the shell as a literal control
  character; `grep -rn "copy-mode" Sources/` is empty. Search, zoom, and pane navigation have no
  substitute in the app's own vocabulary.
  `Sources/tetmuxUI/KeymapPolicy.swift:10-22`

- [x] **There is no settings window at all** — no `Settings` scene, so macOS shows no "Settings…"
  item. No font size (the most-adjusted setting in a terminal), no theme, no ANSI palette;
  `TerminalTheme.ligatures` is declared and never read, and `TerminalTheme` is assigned once at
  declaration and never written.
  `Sources/tetmuxUI/AppMain.swift:11-33`, `Sources/tetmuxUI/AppModel.swift:15`

- [x] **No keyboard route between panes, and none to another tab except ⌘K.** Pane focus is
  mouse-only; there is no ⌘1–9, no ⌘{/⌘}, no ⌥⌘arrow. `.closePane` is declared with no default
  binding, so its menu item renders bare — while ⇧⌘W (close tmux window) and ⌘W (close macOS
  window) are one modifier apart with very different blast radii.
  `Sources/tetmuxUI/KeymapPolicy.swift:64-77`

- [x] **Two ⌘V items in the menu bar, and the standard one probably wins.** AppKit's Paste is in the
  pasteboard group and comes first; SwiftTerm validates `paste(_:)` as always enabled. If so, ⌘V
  routes to per-keystroke `send-keys -H` and bypasses the buffer chunking whose own comment says a
  megabyte of `send-keys` will wedge the channel. Verify live, then remove one.
  `Sources/tetmuxUI/AppMain.swift:56-58`, `Sources/tetmuxCore/Session/SessionService.swift:1622-1650`

- [x] **The bell is `NSSound.beep()`, always** — no background notification, no per-tab marker (the
  tab dot is tmux's activity flag), no visual bell, no mute. A long build in a background window
  beeps into the void. F4.31 asks for Notification Center; `UserNotifications` is never imported.
  `Sources/tetmuxUI/TerminalSurface.swift:192`

- [x] **The tab strip has no overflow handling and does not follow selection.** A plain horizontal
  `ScrollView` with no `ScrollViewReader`: with fifteen tmux windows, selecting one from ⌘K or the
  sidebar leaves its tab off-screen with no indicator and no overflow menu.
  `Sources/tetmuxUI/AppMain.swift:322-341`

- [ ] **No tab reordering and no way to move a window between sessions.** No `onMove`/`draggable`
  anywhere; `SessionService` exposes `unlink-window` but no `move-window`, `swap-window`, or
  `link-window`. Renaming is well covered at both levels; ordering is not.

- [ ] **Nothing is restored on relaunch.** No `@SceneStorage`/`@AppStorage` anywhere; `bootstrap`
  restores `hosts.json` and then each window is dropped onto the first host and its active session.
  The sessions survived the relaunch — the window-to-session layout did not.
  `Sources/tetmuxUI/WindowState.swift:155-180`

- [ ] **Pane contents are invisible to VoiceOver.** SwiftTerm's accessibility service is an empty
  stub and `makeNSView` adds no label, value, or role. The chrome around it is labelled thoroughly,
  which makes the hole sharper: everything is announced except the terminal.
  `Sources/tetmuxUI/TerminalSurface.swift:72-85`

- [ ] **No URL detection for plain text, no right-click menu on a pane, no middle-click paste.**
  Only OSC 8 hyperlinks open, so the URL `git push` prints is not clickable.
  `Sources/tetmuxUI/TerminalSurface.swift:195-200`

- [~] Reduce Motion and Increase Contrast are not honoured; animations are unconditional.
  `Sources/tetmuxUI/LauncherOverlay.swift:85`
  *Reduce Motion is honoured now at all three animation sites — the launcher's scroll, the tab
  strip's scroll-to-selection, and the sidebar's row-action reveal — each keeping the outcome and
  dropping the movement. Increase Contrast is still unhandled.*

## Requirements shipped as stubs

- [x] **F4.17 stale-client reconciliation — "the single most common failure mode" — is a probe with
  no consumer.** `list-clients -F` is sent on every attach and the response is passed to `log()`.
  No distinctive client name is ever set, nothing identifies a non-live tetmux client, and nothing
  detaches one. The only detach is a menu action that detaches *every* other client, the user's
  legitimate ones included.
  `Sources/tetmuxCore/Session/SessionService.swift:1035-1036`, `:1903-1906`

- [ ] **F4.27 passthrough fallback**, which §4.6 and §10 both call first-class, is a banner string
  after which control mode proceeds anyway. No attached-client surface, no mode indicator, nothing
  disabled.
  `Sources/tetmuxCore/Session/SessionService.swift:1013-1019`

- [~] **R3.8 version table: three of five rows absent.** `refresh-client -B` subscriptions are never
  issued (`TmuxVersion.supportsSubscriptions` is dead code); there is no once-per-host warning for
  2.4–2.9; tmux being absent produces a raw stderr line rather than the offer of a plain shell.
  Subscriptions are also the supported way to observe `pane_current_command` and
  `window_zoomed_flag` — without them the code polls `list-panes` on a debounce.
  `Sources/tetmuxCore/Session/HostModel.swift:489`
  *Two of the three are done: `refresh-client -B` subscribes to `pane_current_command` for every
  pane on ≥3.2, which is what finally reports a command started in a background pane, and 2.4–2.9
  now warns once per host. Still absent: the tmux-absent row's "offer a plain shell to that host",
  which is the passthrough surface below and not a separate small job.*

- [ ] **R3.5 checksum validation defaults to off** and both production callers take the default, so
  the validation exists only in tests.
  `Sources/tetmuxCore/Core/LayoutParser.swift:87`

- [ ] **Declared and never wired**: the per-host OSC 52 opt-in is a single app-wide flag that is
  never mutated and has no field on `HostConfig` (T5.6); `KeymapPolicy.rebind` and `shortcut(for:)`
  have no production callers, and there is no settings file to edit bindings in (F4.19/F4.22);
  `⌘⌥V` literal-escape is documented in the README and never passed `true` (F4.21);
  `HostConfigStore.resolveEffectiveConfig` (`ssh -G`) is dead code (F4.2).

- [ ] **F4.4** never lists a host's sessions without attaching — `list-sessions` only goes down an
  already-attached channel, so the only way to see what is on a host is `connectHost`, which
  attaches and can create.

- [~] **F4.11** has no `detach-client`: disconnect tears the pty down with `SIGHUP` instead. And
  `newSession` accepts a start directory that no caller passes.
  *`detach-client` is done, as "Detach This Client" beside Disconnect, and waited for rather than
  merely written so `SIGHUP` cannot beat it out of the pty. The start directory and the optional
  command still have no UI to set them from.*

## Infrastructure

- [x] **The §2.4 portability hedge is already broken.** `PtyTransport` calls `Darwin.write`
  unqualified by any `#if canImport(Darwin)`, fifteen lines after the file carefully imports
  `Glibc`, and `forkpty` is not exposed by the Glibc module either. CI is macOS-only, against
  §2.4's explicit "CI must build that target on Linux even though nothing consumes it". A hedge
  that is never exercised has already stopped being a hedge.
  `Sources/tetmuxCore/Core/PtyTransport.swift:249`, `.github/workflows/ci.yml`

- [ ] **§2.5 distribution**: ad-hoc signing only (`codesign --sign -`), no Developer ID, no
  notarisation, no hardened runtime, and no update mechanism anywhere in the tree — every user is on
  manual download plus a Gatekeeper fight on first open.
  `Scripts/package-dmg.sh:136`

- [ ] **R3.6 fixture matrix is one version.** Everything is captured from 3.7b; the SRD asks for
  3.0, 3.2a, 3.3a, 3.4 and 3.5, and CI installs a single Homebrew tmux. The version-conditional
  code paths are therefore all untested on the versions they exist for.

- [ ] **P6.1–P6.7 are unmeasured.** No latency, throughput, CPU or memory instrumentation exists,
  against §8's "latency measurement in CI on real hardware, asserting P6.1".

- [ ] **§8 testing strategy, absent items**: no containerised sshd/tmux matrix, no chaos tests
  (`SIGSTOP`, `pmset`, severed socket), no geometry regression suite or 50-resize storm, and no
  rendering-acceptance corpus — so T5.7's Unicode 15 width and ZWJ correctness is delegated entirely
  to SwiftTerm and asserted nowhere.

- [x] **Non-ASCII typed input is untested.** `send-keys -H` with bytes ≥ 0x80 relies on modern tmux
  ORing `KEYC_LITERAL`; older builds may re-encode per byte and produce mojibake. Add the test
  before reading it as either safe or broken.
  `Sources/tetmuxCore/Session/SessionService.swift:1607-1608`

---

## Done

An earlier round: ⌥ skipping the close/kill confirmation with the glyph turning red while held; the
menu bar tray opening a window when none is open (three separate dead ends — an unclaimed
`requestedWindow`, the same dead end one branch later for ⌥, and New Session never queueing a reveal
at all); localhost auto-connecting at launch; the Dock menu's New Window item; and the session count
on a collapsed host.
