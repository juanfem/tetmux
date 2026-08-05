# TODO

From the audit of 2026-08-04. Ordered by what actually breaks for a user, not by effort.
Each item names the evidence, because the ones that matter here are all silent failures — nothing
in this list announces itself, which is why they survived this long.

**35 done, 5 partial, 7 open.**

References on **done** items are as they were when the audit ran, so they point into the commit
before each fix rather than into current `main` — they are kept because the evidence is the useful
part of the entry. References on **open and partial** items are refreshed against current `main`,
since those are meant to be walked to.

What is left falls into three groups, and they are not equally blocked:

- **Needs credentials or hardware nobody here has.** Developer ID signing and notarisation need an
  Apple Developer account; an updater needs somewhere to host an appcast and a key to sign it; the
  P6 wants latency measured in CI on real hardware. These are decisions before they are work.
  (The R3.6 matrix was in this group and is out of it: the binaries turned out to build from source
  in about a minute each, so nothing was needed but the script to do it.)
- **Real features, sized like features.** Passthrough fallback (F4.27, which is also the "offer a
  plain shell" row of R3.8), copy mode, an editable keymap with a settings file, per-host OSC 52,
  tab reordering and `move-window`, window/session state restoration, listing a host's sessions
  without attaching (F4.4), and the §8 test infrastructure — a containerised sshd matrix, chaos
  tests, a full geometry suite, a rendering corpus.
- **Small and unblocked.** The three still-unwired declarations — per-host OSC 52, an editable
  keymap, and ⌘⌥V's literal escape — and a start directory for **localhost**, which needs the host
  editor to work for a host that has no ssh settings.

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
  *Capped at 256 commands, oldest dropped. There is still no age limit — a host that connects after
  a long outage replays what is left of the queue rather than discarding it as stale.*

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
  character; `grep -rni "copy-mode" Sources/ Tests/` is still empty. Search and zoom now have app-level
  substitutes (⌘F, ⇧⌘Z) and pane navigation has ⌥⌘[ / ⌥⌘], but tmux's own copy mode — selection by
  keyboard, its search, its buffers — has none.
  `Sources/tetmuxCore/Session/SessionService.swift:1929`, `Sources/tetmuxUI/KeymapPolicy.swift:10-30`

- [x] **There is no settings window at all** — no `Settings` scene, so macOS shows no "Settings…"
  item. No font size (the most-adjusted setting in a terminal), no theme, no ANSI palette;
  `TerminalTheme.ligatures` is declared and never read, and `TerminalTheme` is assigned once at
  declaration and never written.
  `Sources/tetmuxUI/AppMain.swift:11-33`, `Sources/tetmuxUI/AppModel.swift:15`
  *Font family, size, ligatures and scrollback are settable and persisted. Theme and ANSI palette
  are still absent — panes follow the system appearance and nothing else.*

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
  *Background bells post a coalesced notification now. There is still no visual bell, no mute, and
  no per-tab bell marker distinct from tmux's activity flag.*

- [x] **The tab strip has no overflow handling and does not follow selection.** A plain horizontal
  `ScrollView` with no `ScrollViewReader`: with fifteen tmux windows, selecting one from ⌘K or the
  sidebar leaves its tab off-screen with no indicator and no overflow menu.
  `Sources/tetmuxUI/AppMain.swift:322-341`

- [ ] **No tab reordering and no way to move a window between sessions.** No `onMove`/`draggable`
  on the tab strip; `SessionService` exposes `unlink-window` but no `move-window`, `swap-window`, or
  `link-window` — none of the three appears anywhere in `Sources/`. Renaming is well covered at both
  levels; ordering is not.
  `Sources/tetmuxCore/Session/SessionService.swift:2302`, `Sources/tetmuxUI/AppMain.swift:436-461`

- [ ] **Nothing is restored on relaunch.** No `@SceneStorage`/`@AppStorage` anywhere; `UserDefaults`
  now carries the terminal appearance and nothing else. `bootstrap` restores `hosts.json` and then
  each window is dropped onto the first host and its active session; `WindowSeed` is in-memory only.
  The sessions survived the relaunch — the window-to-session layout did not.
  `Sources/tetmuxUI/AppModel.swift:283-307`, `Sources/tetmuxUI/WindowState.swift:13`, `:155-180`

- [~] **Pane contents are invisible to VoiceOver.** SwiftTerm's accessibility service is an empty
  stub and `makeNSView` adds no label, value, or role. The chrome around it is labelled thoroughly,
  which makes the hole sharper: everything is announced except the terminal.
  `Sources/tetmuxUI/TerminalSurface.swift:142-144`
  *The screen's contents are readable now: `accessibilityValue` is the visible viewport — bounded by
  the grid rather than by the scrollback, so the cost does not grow with history — alongside a
  character count, the selection, the cursor's line, and a role description that says "terminal"
  rather than "text area". Two things are still missing. Nothing posts `.valueChanged`, so output
  arriving while VoiceOver is idle is not announced and the user has to go back and read; doing that
  properly means diffing for the lines that are new, because re-reading the whole screen on every
  chunk of a build log is worse than saying nothing. And there is still no grid navigation — no
  per-line elements, no `accessibilityRange(forLine:)` — so a screen reader reads the pane as one
  string.*

- [x] **No URL detection for plain text, no right-click menu on a pane, no middle-click paste.**
  Only OSC 8 hyperlinks open, so the URL `git push` prints is not clickable. There is no
  `rightMouseDown`, no `otherMouseDown`, and no `contextMenu` on a pane — the three context menus in
  the app are on sidebar rows and the tab.
  `Sources/tetmuxUI/TerminalSurface.swift:307-313`
  *The plain-text half turned out to be **already true** — the pinned SwiftTerm detects implicit
  links and activates them on ⌘-click, and our `requestOpenLink` was being reached all along. That
  entry was stale rather than wrong when written, so it is now covered by a test that fails if a
  SwiftTerm bump ever turns the matcher off. The two real gaps are done: `PaneTerminalView` is a
  `TerminalView` subclass with a context menu (Open / Copy Link on whatever the click landed on, then
  Copy, Paste, Select All) and middle-click paste. Both pastes go through `SessionService.paste`
  rather than SwiftTerm's own, which inserts a clipboard as keystrokes. Verified against a live pane:
  ⌘-click opened `https://example.com/from-a-pane` in the browser, the menu found the URL under the
  pointer, and a middle click delivered its clipboard to the prompt.*

- [x] Reduce Motion and Increase Contrast are not honoured; animations are unconditional.
  `Sources/tetmuxUI/LauncherOverlay.swift:36`, `:87`
  *Reduce Motion is honoured at all three animation sites — the launcher's scroll, the tab strip's
  scroll-to-selection, and the sidebar's row-action reveal — each keeping the outcome and dropping
  the movement. Increase Contrast is now `ContrastPolicy`, one place that every site asks rather than
  a `contrast == .increased ? a : b` per call site: selection fills and hover washes get stronger,
  selection gains a border, recessed text comes back toward legible without reaching 1, and an
  unfocused pane stops being dimmed at all — dimming a pane is dimming terminal text, and the frame
  around the focused one takes over the job at full saturation and double the width. The tests assert
  direction rather than numbers, which is what stops a later site from taking the standard value in
  both branches. `differentiateWithoutColor` is handled too, and with no policy type — the
  replacement channel differs at every site, so each reads the environment itself. The RTT dot gains
  `· good`/`· fair`/`· slow`, since the number beside it is the measurement and the hue was the
  judgement; the ⌥-armed close buttons gain a filled chip, since red was the whole content of "this
  will not stop to ask". The connection rail needed **nothing** — `hostStatusLabel` already says every
  state but `.connected` in words, and `.connected` is the one with no label — which is worth having
  checked rather than decorated.*

## Requirements shipped as stubs

- [x] **F4.17 stale-client reconciliation — "the single most common failure mode" — is a probe with
  no consumer.** `list-clients -F` is sent on every attach and the response is passed to `log()`.
  No distinctive client name is ever set, nothing identifies a non-live tetmux client, and nothing
  detaches one. The only detach is a menu action that detaches *every* other client, the user's
  legitimate ones included.
  `Sources/tetmuxCore/Session/SessionService.swift:1035-1036`, `:1903-1906`
  *tmux turned out to have no settable client name — `client_name` is the tty — so the tag is
  `client_control_mode` instead. Known blast radius: two live tetmuxen against one server, or
  iTerm2's tmux integration, would detach each other.*

- [ ] **F4.27 passthrough fallback**, which §4.6 and §10 both call first-class, is a banner string
  after which control mode proceeds anyway. A sub-2.4 server is marked `.degraded` and then goes
  straight on to the window-size, flow-control and subscription policies. No attached-client surface,
  no mode indicator, nothing disabled. This is also the missing R3.8 row below — "offer a plain
  shell" is the same surface, not a separate small job.
  `Sources/tetmuxCore/Session/SessionService.swift:1268-1281`

- [~] **R3.8 version table: three of five rows absent.** `refresh-client -B` subscriptions are never
  issued (`TmuxVersion.supportsSubscriptions` is dead code); there is no once-per-host warning for
  2.4–2.9; tmux being absent produces a raw stderr line rather than the offer of a plain shell.
  Subscriptions are also the supported way to observe `pane_current_command` and
  `window_zoomed_flag` — without them the code polls `list-panes` on a debounce.
  `Sources/tetmuxCore/Session/HostModel.swift:555`, `Sources/tetmuxCore/Session/SessionService.swift:2057-2072`
  *Two of the three are done: `refresh-client -B` subscribes to `pane_current_command` for every
  pane on ≥3.2, which is what finally reports a command started in a background pane, and 2.4–2.9
  now warns once per host. The subscription path is exercised end to end by
  `testACommandInABackgroundPaneIsReportedWithoutARefresh`, which starts a command in a background
  pane from outside the channel and waits for the model to learn of it. Still absent: the
  tmux-absent row's "offer a plain shell to that host", which is the passthrough surface above.*

- [x] **R3.5 checksum validation defaults to off** and all production callers take the default, so
  the validation exists only in tests. There are now three of them — the zoom work added a second
  parse for `visibleLayout`.
  `Sources/tetmuxCore/Core/LayoutParser.swift:87`, callers at
  `Sources/tetmuxCore/Session/HostModel.swift:151`, `:174`, `:178`
  *On at every production caller. What unblocked it was making a rejection all-or-nothing: `apply`
  parses both fields first and either commits both or keeps the previous layout, so a mismatch costs
  a stale grid rather than the blank window `layoutTree == nil` renders — which is the fear that kept
  it off. It returns a `LayoutApplyResult` so `SessionService` can log what it threw away. Two test
  fixtures turned out to carry hand-edited checksums that no tmux ever emitted; the real ones,
  zoomed `window_visible_layout` included, all verify.*

- [~] **Declared and never wired**, all four confirmed still unreferenced outside `Tests/`:
  the OSC 52 opt-in is a global `TerminalTheme` field with no persistence key, no settings control
  and no `HostConfig` field, so it can never become true and its own doc comment's "unless the user
  opts in per host" is fiction (T5.6); `KeymapPolicy.rebind` and `shortcut(for:)` have no production
  callers, and there is no settings file to edit bindings in (F4.19/F4.22); `⌘⌥V` literal-escape has
  a binding and a title but no menu item and no handler, and `literalEscapeActive: true` is never
  passed (F4.21); `HostConfigStore.resolveEffectiveConfig` (`ssh -G`) is dead code (F4.2).
  `Sources/tetmuxUI/TerminalSurface.swift:19`, `Sources/tetmuxUI/KeymapPolicy.swift:107`, `:122-143`,
  `Sources/tetmuxCore/Session/HostConfigStore.swift:226`
  *One of the four is wired: `ssh -G` now fills the host editor's User and Port placeholders and says
  what an alias resolves to, so a field left blank shows what ssh will actually use rather than
  "optional". Display only, deliberately — the connection is still made with the *name* so ssh
  applies its own `Match` blocks. Wiring it turned up a bug in the dead code itself: the map was
  last-wins, and `identityfile` repeats once per candidate key, so it reported whichever default came
  last as though someone had chosen it. The other three are untouched.*

- [ ] **F4.4** never lists a host's sessions without attaching — `list-sessions` only goes down an
  already-attached channel, so the only way to see what is on a host is `connectHost`, which
  attaches and can create.
  `Sources/tetmuxCore/Session/SessionService.swift:460`, `:1374-1376`

- [~] **F4.11** has no `detach-client`: disconnect tears the pty down with `SIGHUP` instead. And
  `newSession` accepts a start directory that no caller passes.
  *`detach-client` is done, as "Detach This Client" beside Disconnect, and waited for rather than
  merely written so `SIGHUP` cannot beat it out of the pty. The start directory is now a **host**
  setting — "Start in" in the host editor — rather than a dialog at creation time, which is what lets
  it exist at all: `createSessionWithDefaultName` deliberately puts nothing between wanting a shell
  and having one. tmux resolves the path on its own side, so `~` and a directory that only exists
  remotely both work, and there is deliberately no folder picker. Wiring it turned up that the
  parameter never went through `TmuxCommand.singleLine`, so a pasted path with a line break would
  have ended the command early and handed tmux the remainder as a new one.
  **Two things it still does not cover.** It cannot be set for **localhost**: `saveHosts` filters the
  `local` id and the sidebar offers no editor for it, so the host most likely to want one is the one
  that cannot have one — giving it an editor means a conditional one, since hostname, user, port,
  password and forwards are all meaningless there. And an initial command is still not a parameter.*
  `Sources/tetmuxCore/Session/SessionService.swift:2323`, `Sources/tetmuxUI/AppModel.swift:926`

## Infrastructure

- [x] **The §2.4 portability hedge is already broken.** `PtyTransport` calls `Darwin.write`
  unqualified by any `#if canImport(Darwin)`, fifteen lines after the file carefully imports
  `Glibc`, and `forkpty` is not exposed by the Glibc module either. CI is macOS-only, against
  §2.4's explicit "CI must build that target on Linux even though nothing consumes it". A hedge
  that is never exercised has already stopped being a hedge.
  `Sources/tetmuxCore/Core/PtyTransport.swift:249`, `.github/workflows/ci.yml`

- [ ] **§2.5 distribution**: ad-hoc signing only (`codesign --force --sign - --timestamp=none`), no
  Developer ID, no notarisation, no hardened runtime, and no update mechanism anywhere in the tree —
  every user is on manual download plus a Gatekeeper fight on first open, which the release notes
  currently paper over with a quarantine workaround.
  `Scripts/package-dmg.sh:136`

- [x] **R3.6 fixture matrix is one version.** Everything is captured from 3.7b; the SRD asks for
  3.0, 3.2a, 3.3a, 3.4 and 3.5, and CI installs a single Homebrew tmux. The version-conditional
  code paths are therefore all untested on the versions they exist for — the integration tests
  self-skip on an old server rather than exercising the fallback, and `TmuxVersion`'s unit tests
  cover the predicate rather than the paths behind it.
  `.github/workflows/ci.yml`, `Tests/tetmuxTests/SessionIntegrationTests.swift:997`, `:1302`, `:1350`
  *All five versions build from pinned checksummed tarballs (`Scripts/build-tmux-matrix.sh`), and
  `Scripts/capture-fixtures.py` records ten scenarios from each under a pty — 50 fixtures, 200 KB.
  `ControlCodecMatrixTests` replays them and pins the layout-change field count, zoom's visible
  layout, octal escaping, rename ids, and `%exit` back to 3.0. Deliberately **not** a CI job: a
  fixture is a frozen record, and regenerating it each run makes the test a tautology.
  **Still open at the level below this:** the integration suite continues to run against whatever
  `tmux` is on PATH, so old-version *behaviour* — as opposed to parsing — is still untested. That is
  §8's containerised matrix, below.*

- [ ] **P6.1–P6.7 are unmeasured.** No latency, throughput, CPU or memory instrumentation exists —
  no `os_signpost`, no `measure(`, nothing in CI — against §8's "latency measurement in CI on real
  hardware, asserting P6.1". The P6 references in the source are design rationale, and the one
  backpressure test asserts that a pause happens, not how fast anything is.

- [~] **§8 testing strategy, absent items**: no containerised sshd/tmux matrix, no chaos tests
  (`SIGSTOP`, `pmset`, severed socket), no geometry regression suite or 50-resize storm, and no
  rendering-acceptance corpus — so T5.7's Unicode 15 width and ZWJ correctness is delegated entirely
  to SwiftTerm and asserted nowhere.
  *`TerminalGeometryTests` covers the reserved-scroller column loss and the font-derived cell round
  trip, which is the start of the geometry suite but not the resize storm. The rest is untouched:
  the only `container:` in CI is the Swift image for the Linux core build, and the only Unicode
  assertion is byte delivery through the paste path, never rendered width.*

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

Since the audit, and not on its list: the reserved-scroller gutter that made every full-width program
wrap a few columns early, the README rewritten against what the code actually does, and the Dock menu
— which offered New Window alone, and a window opened that way reconciles to the first host's
*active* session and window, so the only thing the Dock could do was make a second view of whatever
was already on screen. It now has New Window (tree shown, to navigate from), New Local Session, and
New Remote Session with one row per remote.

Two more found while fixing other things, both in the same arithmetic and both worth naming because
neither announces itself:

- **`TerminalGeometryTests` had been red since the commit that introduced it.** It measured the
  theme's cell at 2× against a view that resolves its own scale factor and, with no window and no
  screen under `xctest`, lands on 1×. The failure was nowhere near the defect the test exists to
  catch. Nothing in CI would have gone green over it — it was simply never run again after the commit
  that added it.
- **The pane's cell size was snapped to `NSScreen.main`'s density rather than the window's.**
  `NSScreen.main` is the screen holding whichever window has keyboard focus *anywhere on the system*,
  so on a desk with a 1× monitor beside a 2× built-in it changed answer every time the user clicked
  into another application on the other display. SwiftTerm meanwhile resolves its own `cellDimension`
  from `window?.backingScaleFactor`. Measured in that configuration: a 572pt pane on the Retina
  display asked tmux for 71 columns while its own grid drew 76. `@Environment(\.displayScale)` is the
  fix, plus an `onChange` to re-ask — a window dragged between displays keeps its size in points, so
  nothing else in the container would ever have noticed.
