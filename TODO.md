# TODO

Rewritten from scratch on 2026-08-05 against `tetmux-srd.md` v2.1, which absorbed the audit's
history: everything the old file recorded as done is now either an invariant in `CLAUDE.md` or an
amended requirement in the SRD, and repeating it here would be a second copy that drifts. This file
holds only what is **open**, with the evidence that it is open and instructions concrete enough
that the work can start from the entry alone. An unlisted requirement reads as done — that is the
failure mode this file exists to prevent, so anything the SRD asks for that the tree does not do
belongs here.

**3 features, 3 tests owed, 1 blocked, 2 parked.** The six small items this file opened with, copy
mode, and the integration matrix were closed on 2026-08-05, and the matrix's own follow-ups on
2026-08-06; what they turned into is recorded in `CLAUDE.md`, not here. The five entries added on
2026-08-06 came out of an adherence review of the tree against SRD v2.1 — a review that mostly
found the *documents* behind the code, and amended the SRD's stale status notes in the same pass.
The launcher's half of that batch (F4.25/F4.26) closed the same day.

**The P6 harness closed on 2026-08-06 and replaced itself with what it measured.** The entry asking
for instrumentation is gone — `Scripts/measure-latency.sh`, `Scripts/measure-throughput.sh` and
`Scripts/measure-idle.md` exist, and `docs/measurements.md` holds the numbers. The two entries
below are its output: P6.3 passes with 6.5× of room, P6.1 misses by 2×, and P6.6/P6.7 need an
arrangement of real machines that no script can build. That is what a measurement harness is for,
and it is the reason the count above went up rather than down.

References point into current `main`. Line numbers drift; the symbol names beside them do not.

---

## Features, sized like features

- [ ] **P6.1 is missed by 2×, and 8 ms of the 12 ms budget is a timer we set ourselves.**
  Measured 2026-08-06 on an M3: **p95 24.43 ms** keypress → glyph on a *local* session, against
  P6.1's 12 ms (`docs/measurements.md`). The split is the finding — 19.72 ms p95 of it is
  keypress → echo, and `SessionService.sendKeys` (`keyFlushInterval`, 8 ms) accounts for most of
  that: it starts a task that *sleeps and then writes*, so a keystroke with nothing to coalesce
  with — every keystroke at typing speed — waits the full interval before anything leaves the
  process. Measured p50 echo is 9.76 ms: 8 ms of sleep and 1.8 ms of work.
  *Do:* flush on the **leading** edge — write the first keystroke immediately, then coalesce
  whatever arrives during the next 8 ms into the following `send-keys`. That keeps P6.4's
  batching exactly where it is needed (a paste, a held key, a fast burst) and takes 8 ms off the
  isolated keystroke. Two things to get right: the flush task must not be scheduled when the
  write already happened, or every burst pays the interval twice; and the batching under load is
  what P6.4 asks for, so the fix is verified by re-running `Scripts/measure-latency.sh` **and**
  by checking a fast burst still coalesces rather than sending one command per key. The
  remaining ~4 ms (echo → drawn) is AppKit and SwiftTerm and is not ours; the compositor and the
  display are outside the measurement entirely, so the real figure is worse than 24 ms and the
  budget after this fix is tighter than it looks.
  `Sources/tetmuxCore/Session/SessionService.swift` (`sendKeys`, `flushKeys`)

- [ ] **P6.6 and P6.7 have a procedure and no numbers.** `Scripts/measure-idle.md` is written —
  idle CPU on battery, wakeups under `powermetrics`, `footprint` for resident memory, the App
  Launch template for cold launch, and the traps in each. Nobody has run it, because both
  requirements are claims about 20 panes across 4 hosts and that arrangement has to be built by
  hand on machines somebody can reach.
  *Do:* build the arrangement, follow the procedure, add the rows to `docs/measurements.md`. If
  the four hosts are not four real machines, record what they were — a loopback ssh leg has no
  network stack worth the name, and P6.6 is partly a claim about what an idle ssh connection
  costs.

- [ ] **P6.4's output half: the byte handoff is per-chunk, not per display frame.** The input
  direction complies — keystrokes coalesce into one `send-keys -H` per 8 ms flush, and
  acknowledgements batch at 16 KiB — but the surface feeds the emulator once per `%output` chunk
  and nothing in the tree is ProMotion-aware; there is no display link anywhere. SwiftTerm's own
  redraw coalescing is what keeps the paint rate sane, which may make this a non-problem in
  practice, but P6.4 as written asks for per-frame batching of the handoff itself.
  *Do:* measure first — the P6 harness above is the tool. If per-chunk feeding shows up, coalesce
  chunks in `TerminalSurface.Coordinator.attach` behind `NSView.displayLink(target:selector:)`
  and flush once per frame; if it does not, amend P6.4 to record per-chunk feeding over
  SwiftTerm's coalescing as the accepted design. Until one of those happens the requirement reads
  as done while the tree does not do it.
  `Sources/tetmuxUI/TerminalSurface.swift` (`Coordinator.attach`)

## Tests owed by the SRD

- [ ] **The sleep/wake chaos scenario (§8's fourth).** Killing the channel mid-stream and
  `SIGSTOP`ping the server run in `SessionIntegrationTests`; the ControlMaster scenario runs
  behind `TETMUX_SSH_HOST`; nothing exercises the sleep/wake boundary. A test cannot sleep the
  machine, so test the seam instead: the wake path is `NSWorkspace.didWakeNotification` →
  `probeAllConnections`, so an integration test that kills the link while "asleep", calls
  `probeAllConnections()`, and asserts reconnect plus repaint covers the core's half — watching
  the state *leave* `.connected` first, per the kill-test rule. The outbox age rule across the
  boundary is already covered via the injected clock.
  `Tests/tetmuxTests/SessionIntegrationTests.swift`,
  `Sources/tetmuxUI/NetworkStateMonitor.swift`

- [ ] **Rendering acceptance, the program-level half (§8, T5.7).** The CJK/emoji width corpus
  exists (`RenderingCorpusTests`); `vim`, `htop`, `less`, and a Powerline prompt against a
  reference terminal exist nowhere. Same provenance discipline as every other fixture: capture
  each program's real byte stream once under a pty (the `capture-fixtures.py` pattern), commit
  it, replay it into the emulator, and assert the grid against a reference terminal's rendering
  of the same bytes — recorded, never regenerated.
  `Tests/tetmuxTests/RenderingCorpusTests.swift` is the pattern to extend.

- [ ] **T5.2 has no assertion.** Truecolor works by architecture — `%output` carries raw pane
  bytes and SwiftTerm renders 24-bit SGR — but no test or line of code anywhere mentions it, and
  §5's preamble promises "exact, testable commitments". One pane test feeding `ESC[38;2;R;G;Bm`
  through the same replay path as the width corpus and asserting the colour survives to the
  buffer closes it, beside the existing invocation assertions that pin `-2`.
  `Tests/tetmuxTests/RenderingCorpusTests.swift`

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
  Everything known to *cause* one (partial writes, secrets near the FIFO, and now unsolicited
  mode-table blocks) is prevented or treated as fatal instead, so the detectors should never
  fire. More importantly, **they are diagnostics, and promoting a diagnostic into a trigger
  changes what a false positive costs**: a detector that is wrong produces a spurious log line;
  wired to a teardown it produces a reconnect storm on a healthy channel — teardown, reattach,
  handshake *succeeds*, detector fires again — and the backoff never engages, because each
  cycle's completed handshake resets the attempt counter. So the real fix is not the one-line
  teardown it first appears to be: it needs a recovered-once-already guard per host, where a
  second desync in the same epoch stops and surfaces instead of looping.
  The copy-mode work (commit `1849b15`) proved this caution right rather than loosening it: the
  "`%begin` with nothing pending" detector's false positive turned out to be *real* — tmux opens
  an unsolicited block for every command a pane's mode table dispatches, so any copy-mode
  keystroke, from any client, would have fired it — and the right fix was neither recovery nor
  teardown but classification: `ControlCodec.blockAnswersOurCommand` reads the flags bitfield and
  the FIFO no longer consumes blocks that answer nothing we sent. Had detection been wired to
  teardown before that was understood, `prefix [` in a pane would have dropped the connection.
  The first real desync cause was found by feature work, not by the log line firing — which is
  the pattern to expect. **The log line appearing in real diagnostics remains the trigger to
  un-park this**: it means another unknown cause exists and there is finally an example to
  design against.
  `Sources/tetmuxCore/Session/SessionService.swift` (desync logging beside the `%begin` handling),
  `Sources/tetmuxCore/Core/ControlCodec.swift` (`blockAnswersOurCommand`)
