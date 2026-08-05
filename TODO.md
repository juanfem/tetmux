# TODO

Rewritten from scratch on 2026-08-05 against `tetmux-srd.md` v2.1, which absorbed the audit's
history: everything the old file recorded as done is now either an invariant in `CLAUDE.md` or an
amended requirement in the SRD, and repeating it here would be a second copy that drifts. This file
holds only what is **open**, with the evidence that it is open and instructions concrete enough
that the work can start from the entry alone. An unlisted requirement reads as done — that is the
failure mode this file exists to prevent, so anything the SRD asks for that the tree does not do
belongs here.

**8 features, 1 blocked, 2 parked.** The six small items this file opened with were closed on
2026-08-05; what they turned into is recorded in `CLAUDE.md`, not here.

References point into current `main`. Line numbers drift; the symbol names beside them do not.

---

## Features, sized like features

- [ ] **Copy mode.** Keys reach the pane via `send-keys -H`, so tmux's key table is never
  consulted and `C-b` lands in the shell as a literal control character;
  `grep -rni copy-mode Sources/ Tests/` is empty. Search and zoom have app-level substitutes
  (⌘F, ⇧⌘Z) and pane navigation has ⌥⌘[/⌥⌘] — but tmux's own copy mode (keyboard selection, its
  search, its buffers) has no replacement, and SwiftTerm's local selection cannot reach text that
  has scrolled out of the local scrollback but is still in tmux's history.
  *Do, in order:* (1) surface the mode — handle `%pane-mode-changed` into a per-pane
  `inCopyMode` flag on `TmuxPane` and show it (status bar and a pane badge), which also fixes
  "another client entered copy mode and the pane looks frozen" with no way to learn why.
  (2) Enter/leave: a menu item + rebindable chord sending `copy-mode -t %pane`, and `q` handling
  left entirely to tmux. (3) Drive it with `send-keys -X <command>` (`begin-selection`,
  `cursor-*`, `page-up`, `search-backward`, `copy-selection-and-cancel`) behind menu items with
  chords, all through `KeymapPolicy` per F4.22 — do not translate raw keystrokes into `-X`
  commands wholesale; the point is a small, documented vocabulary, not an emulation of tmux's
  key table. (4) On copy, read the buffer back with `show-buffer` (a user command, so failures
  surface per §7) and put it on the local pasteboard — that is the half tmux cannot do.
  *Test:* integration — enter copy mode, select, copy, assert the buffer's content round-trips;
  and `%pane-mode-changed` from a second client flips the flag.
  `Sources/tetmuxCore/Session/SessionService.swift:2589`, `Sources/tetmuxUI/KeymapPolicy.swift:10`

- [ ] **Pin F4.23 (mouse modes) and F4.24 (IME) with tests.** Both are delegated wholesale to
  SwiftTerm and asserted nowhere — the exact position the plain-text URL matcher sat in before a
  test went under it: already true, believed rather than known, and free to stop being true on a
  dependency bump with nothing to say so. The keystroke path (an event monitor ahead of dispatch,
  per-frame coalescing) was not written with composition in mind, which makes F4.24 the likelier
  silent break.
  *Do:* two focused tests in the UI test target. Mouse: feed the pane's terminal
  `ESC[?1006h`/`ESC[?1000h` through the emulator, synthesise a scroll event, assert bytes go to
  the channel; reset the modes, assert the same event scrolls locally and sends nothing. IME:
  drive `PaneTerminalView` through `NSTextInputClient` — `setMarkedText` twice, then
  `insertText` — asserting nothing reaches the channel until commit and the committed string
  arrives as one `send-keys -H`; add a dead-key sequence (⌥e, e → é).
  `Sources/tetmuxUI/TerminalSurface.swift:133`, `Sources/tetmuxUI/KeyEventMonitor.swift`

- [ ] **Run the integration suite across the version matrix (§8).** The parsing matrix is done —
  50 fixtures from five built versions — but the suite still runs against whatever `tmux` is on
  PATH, so every version-conditional *behaviour* (per-window sizing off below 2.9, `swap-window`
  reorders below 3.2, polling below 3.2, the 2.4–2.9 warning) is untested on the versions it
  exists for; those tests self-skip on a new server.
  *Do:* teach `SessionIntegrationTests` a `TETMUX_TMUX` environment variable that overrides the
  binary path (thread it through to `PtyTransport`'s argv where the command is built). Add
  `Scripts/test-matrix.sh`: build the matrix if absent, then loop the versions running
  `swift test --filter SessionIntegrationTests` with `TETMUX_TMUX` set, failing on first
  failure. Local and scripted like the capture pipeline, and for the same reason — CI's tmux is
  one version, and the point is the ones it is not. Where a version-conditional path currently
  self-skips, make the skip *conditional on the version actually not applying* rather than on
  convenience, so the matrix run genuinely exercises it.
  `Tests/tetmuxTests/SessionIntegrationTests.swift`, `Scripts/build-tmux-matrix.sh`

- [ ] **Chaos tests (§8).** None exist. Each scenario must end in a defined state and recover.
  *Do,* as integration tests where the machinery allows: (1) kill the spawned process mid-stream
  (`SIGKILL` the transport's child — the fake-ssh script precedent shows how to interpose) and
  assert EOF → backoff → reattach → repaint; (2) `SIGSTOP` the tmux server, assert the RTT probe
  reports the stall and `sendAndAwait` times out without wedging the actor, then `SIGCONT` and
  assert recovery; (3) drop the `ControlMaster` socket file mid-session and assert the next
  channel rebuilds it. Sleep/wake stays manual — `pmset sleepnow` on a test box is not a CI
  citizen — but scriptable as a documented manual pass alongside the P6 harness.
  `Tests/tetmuxTests/SessionIntegrationTests.swift`

- [ ] **The resize storm (§8's geometry suite, second half).** `TerminalGeometryTests` covers the
  scroller gutter and the font-derived cell round trip; the storm — 50 rapid size requests
  including mid-flight contradictions, asserting convergence with tmux's final reported layout —
  does not exist, and it is the test that would have caught the oscillation bugs this project
  spent its hardest weeks on.
  *Do:* integration test against local tmux: drive `requestSizes`-equivalent calls with 50
  randomised (seeded) sizes without awaiting between them, then wait for quiescence and assert
  the model's layout matches one final authoritative `list-windows`, and that no further
  `%layout-change` arrives within a grace window — convergence, not a byte-for-byte transcript.
  `Tests/tetmuxTests/TerminalGeometryTests.swift`

- [ ] **Rendering acceptance corpus (T5.7, §8).** The only Unicode assertion in the tree is byte
  delivery through the paste path; width and grapheme handling are delegated to SwiftTerm and
  asserted nowhere, and under control mode a width bug corrupts geometry, not just appearance.
  *Do:* a fixture-driven test at the emulator boundary, no live tmux needed: feed
  `TerminalView`'s terminal a corpus (CJK, emoji ZWJ sequences, combining marks, box drawing —
  one file per case, real bytes) and assert the resulting **grid**: cursor column after each
  string, cells occupied, wide-char continuation cells. That pins the property control mode
  cares about — agreement between the emulator's grid and the cell arithmetic — without
  attempting pixel comparison. `vim`/`htop`/Powerline stay a documented manual pass; scripting a
  full-screen TUI comparison is a project, not a test.
  `Tests/tetmuxTests/` (new). The corpus needs a `resources:` declaration of its own on the
  `tetmuxTests` target — `Fixtures/` moved to `tetmuxCoreTests` when the suite was split for the
  Linux job, and this test needs `TerminalView`, so it cannot follow it there.

- [ ] **The P6 measurement harness.** No latency, throughput, CPU, or memory instrumentation
  exists — the P6 references in the source are design rationale. Verification is local and
  scripted by SRD decision (§6, §8), so this is a script-writing job, not a CI job.
  *Do:* (1) P6.1: `os_signpost` intervals at keyDown-in and draw-out, a
  `Scripts/measure-latency.sh` that launches the app under `xctrace`, replays scripted
  keystrokes (CGEvent), and prints the p95. (2) P6.3: an XCTest `measure` block feeding
  `ControlCodec` + the octal decoder a recorded megabyte-scale `%output` stream — the codec is
  pure, so this one *can* assert a floor in CI without hardware variance dominating.
  (3) P6.6/P6.7: a documented `Scripts/measure-idle.md` procedure (Instruments template, what to
  open, what number to record). Record results in the repo the way fixture provenance is
  recorded.

- [ ] **Terminal theme and ANSI palette.** Settings cover font, size, ligatures, and scrollback;
  panes follow the system appearance and nothing else. No colour scheme, no ANSI 16 palette —
  the second-most-adjusted terminal preference after font size.
  *Do:* extend `TerminalTheme` with foreground/background/cursor and the 16 ANSI slots, applied
  through SwiftTerm's `installColors`/native-colour APIs on theme change (the propagation path —
  theme on `AppModel`, value passed down, re-applied to live panes — already exists for
  scrollback). Ship a small set of built-in schemes rather than 19 colour wells; keep storage in
  `UserDefaults` with the rest of appearance. Honour the §7 rule: the *chrome* keeps compositing
  from system colours; only pane content takes the scheme. Mind `ContrastPolicy`'s pane rules —
  the unfocused-pane dimming exemption must survive a custom background.
  `Sources/tetmuxUI/TerminalSurface.swift:19-64`, `Sources/tetmuxUI/SettingsView.swift`

## Blocked on credentials

- [ ] **Developer ID signing, notarisation, hardened runtime, and an updater (§2.5).** Signing is
  ad-hoc (`codesign --sign -`); every user is on manual download plus a Gatekeeper fight the
  release notes paper over with a quarantine workaround. Blocked on an Apple Developer account —
  a decision with money attached, not an engineering task.
  *When unblocked:* sign with the Developer ID Application cert plus
  `--options runtime --timestamp` in `package-dmg.sh` (the ad-hoc branch stays for local
  builds); `xcrun notarytool submit --wait` + `xcrun stapler staple` in the `v*` tag job, with
  the account's app-specific password as a repo secret; then Sparkle via SPM, an EdDSA key
  kept offline, and an appcast served from GitHub Releases. The DMG stays arm64-only by
  decision — do not revisit universal as part of this.
  `Scripts/package-dmg.sh:136`, `.github/workflows/ci.yml`

## Parked by decision

- [~] **VoiceOver: announcing new output and per-line navigation.** The readable half is done —
  `accessibilityValue` is the visible viewport, bounded by the grid. Nothing posts
  `.valueChanged` (announcing means diffing for new lines; re-reading a build-log screen per
  chunk is worse than silence), and there is no per-line navigation. Parked 2026-08-05: there is
  one user and they do not need it. The entry stays because it names what is missing and why it
  is hard, which is the expensive half of the work.
  `Sources/tetmuxUI/TerminalSurface.swift` (`PaneTerminalView` accessibility overrides)

- [~] **Desync recovery.** Detection is done — a `%begin` whose number fails to increase, a
  terminator closing nothing, a `%begin` with nothing pending are all logged — but detecting is
  not recovering, and there is still no recovery: a desynced channel keeps running with responses
  landing one command off. Parked for three reasons, and the first alone would not be enough.
  Everything that can *cause* one (partial writes, secrets near the FIFO) is treated as fatal
  instead, so the detectors should never fire. More importantly, **they are diagnostics, and
  promoting a diagnostic into a trigger changes what a false positive costs**: today a detector
  that is wrong about some tmux version's numbering produces a spurious log line; wired to a
  teardown it produces a reconnect storm on a healthy channel — teardown, reattach, handshake
  *succeeds*, detector fires again — and the backoff never engages, because each cycle's completed
  handshake resets the attempt counter. So the real fix is not the one-line teardown it first
  appears to be: it needs a recovered-once-already guard per host, where a second desync in the
  same epoch stops and surfaces instead of looping. And there is nothing to calibrate against —
  the log line has never been observed outside the tests that forge one. **That log line
  appearing in real diagnostics is the trigger to un-park this**, because it means an unknown
  cause exists and there is finally an example to design against.
  `Sources/tetmuxCore/Session/SessionService.swift` (desync logging beside the `%begin` handling)
