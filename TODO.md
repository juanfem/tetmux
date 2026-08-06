# TODO

Rewritten from scratch on 2026-08-05 against `tetmux-srd.md` v2.1, which absorbed the audit's
history: everything the old file recorded as done is now either an invariant in `CLAUDE.md` or an
amended requirement in the SRD, and repeating it here would be a second copy that drifts. This file
holds only what is **open**, with the evidence that it is open and instructions concrete enough
that the work can start from the entry alone. An unlisted requirement reads as done — that is the
failure mode this file exists to prevent, so anything the SRD asks for that the tree does not do
belongs here.

**4 features, 3 tests owed, 1 blocked, 3 parked.** The six small items this file opened with, copy
mode, and the integration matrix were closed on 2026-08-05, and the matrix's own follow-ups on
2026-08-06; what they turned into is recorded in `CLAUDE.md`, not here. The five entries added on
2026-08-06 came out of an adherence review of the tree against SRD v2.1 — a review that mostly
found the *documents* behind the code, and amended the SRD's stale status notes in the same pass.
The launcher's half of that batch (F4.25/F4.26) closed the same day.

**The P6 harness closed on 2026-08-06 and paid for itself the same day.**
`Scripts/measure-latency.sh`, `Scripts/measure-throughput.sh`, `Scripts/measure-launch.sh` and the
`Scripts/measure-idle.md` procedure exist, and `docs/measurements.md` holds every number with the
machine, display and power state beside it.

It found one bug and two broken requirements. The bug: P6.1 missed by 2× — p95 24.43 ms against
12 — because of an 8 ms timer of our own in the keystroke coalescer, which flushed on the trailing
edge and so made every keystroke at typing speed wait out a window it had nothing to share. Flushing
on the leading edge took the round trip from 19.72 ms p95 to under 1 and the whole figure to 11.54.
The broken requirements: **P6.1 named no display**, and at 60 Hz a 12 ms budget is spent before the
compositor can present anything, so it was unmeetable by any application; and **P6.7's memory total
contradicted its own scrollback parenthesis**, asking for two things that could not both hold. Both
were amended against the measurements rather than chased, which is what having numbers is for.

Where that leaves §6, and the honesty matters more than the tally. **P6.3 passes outright**, with
6.5× of room. **P6.7's memory half passes the amended bound** — but that bound was drawn from these
measurements with headroom, so it passes nearly by construction; what it buys is a regression check,
not a validation. **P6.1's verdict is not yet knowable**: under the amended rule it passes on the
100 Hz external monitor, and passes on the built-in panel *if* that panel is at 60 Hz while failing
if it is at 120 — and nobody has measured which. **P6.6 and P6.7's launch half fail**, by 3.7× and
2.5×, each with an entry below carrying its measurement as evidence.

References point into current `main`. Line numbers drift; the symbol names beside them do not.

---

## Features, sized like features

- [ ] **P6.1's application half is met; whether the whole of it is turns on a refresh rate nobody
  has measured.**
  Four runs (`docs/measurements.md`): p95 **11.54 ms** on a fixed-rate 100 Hz external monitor on
  AC, **14.28 ms** on the built-in ProMotion panel on AC, **17.84 ms** on the built-in on battery,
  against a 12 ms bar. Both variables matter and neither alone explains the gap.
  The protocol half is **under 2 ms in all four**, and lowest in the two that fail, so this is not
  the channel: it is the wait between the bytes reaching the emulator and the glyph being on
  screen. The likely mechanism is that **ProMotion idles the refresh rate down when content is
  static**, which a terminal at a prompt is, so a keystroke waits for a frame at whatever rate the
  panel has drifted to — 17.8 ms is about one 60 Hz frame plus the draw.
  *Do:* first establish the panel's actual refresh rate *during* a run rather than inferring it
  from the arithmetic — `CGDisplayCopyDisplayMode`'s refresh rate reads 0 for ProMotion, so this
  wants a `CADisplayLink`/`NSView.displayLink` sampling its own callback interval, which is a few
  lines in the existing probe and would put the number in the record instead of a hypothesis.
  If it confirms the panel idling, the fix is to ask for a higher rate while a pane is being typed
  into: `NSView.preferredFrameRateRange` (or the display link's) is the supported way to tell the
  compositor that this view wants frames now. That is a real change to how a pane schedules
  drawing, so it needs P6.4's output half thought about at the same time — the two are the same
  question from opposite ends.
  **P6.1 was amended on 2026-08-06** to name a refresh rate — 12 ms at p95 on a 100 Hz-or-faster
  display, one refresh interval + 2 ms below that — and to state the number a change is judged by:
  keypress → echoed bytes at the emulator, ≤ 3 ms p95, currently 0.78–1.72 and comfortably met.
  **That makes the refresh rate the thing that decides pass or fail, not a curiosity.** At 60 Hz the
  bound is 18.7 ms and both built-in runs pass (14.28 and 17.84); at 120 Hz the bound is 12 ms and
  both fail. So this entry cannot be closed *or* confirmed until the panel's actual rate during a
  run is known — which is the first task below and is a few lines, not an investigation.
  `Sources/tetmuxUI/LatencyProbe.swift`, `Sources/tetmuxUI/TerminalSurface.swift`

- [ ] **P6.7's launch half misses by 2.5×, and the cold penalty lands where nobody would look.**
  Measured 2026-08-06 on an M3 (`docs/measurements.md`): median **710.8 ms** warm and **985.3 ms**
  after `sudo purge`, against a 400 ms floor — on the bare binary, which is the *faster* target,
  and under tracing, which inflates but not by a factor. The phase breakdown is the useful part.
  Emptying the page cache costs **AppKit Scene Creation 210 ms** (257 → 471) and process creation
  **14 ms** (267 → 281). That is backwards from the obvious expectation: the launch is not
  dominated by dyld mapping a framework graph, it is dominated by something in SwiftUI's scene
  creation reading from disk on first use. Everything tetmux's own code does at launch —
  `applicationWillFinishLaunching` through `didFinishLaunching`, where `bootstrap` reads the
  workspace and connects the local host — is about 100 ms and does **not** grow when the cache is
  emptied, so it is not the place to start.
  *Ruled out already:* SwiftTerm ships `Shaders.metal` as source rather than a compiled
  `.metallib` (see the packaging note in `CLAUDE.md`), and `makeLibrary(source:)` would be exactly
  the kind of disk-read-then-compile that fits this shape — but tetmux never enables SwiftTerm's
  Metal renderer, so it is never on the launch path. Do not chase it again.
  *Do:* the traces `Scripts/measure-launch.sh` records already carry a time profile, so open one in
  Instruments and read the samples inside the Scene Creation window rather than guessing. Then
  re-measure with `--app` against a built bundle: an app bundle gets a dyld launch closure the bare
  binary does not, so that number may be *better* and is in any case the one a user experiences.
  `Scripts/measure-launch.sh`, `Sources/tetmuxUI/AppMain.swift`

- [ ] **P6.6's idle CPU is missed on battery, and it is one timer's answer rebuilding the tree.**
  Measured 2026-08-06 with 20 panes across 4 hosts: **mean 1.83% of one core on battery** against
  a 0.5% bar, median 0.30%, max 13.9%. On AC the same arrangement means 0.48% and passes, so the
  battery figure is the one P6.6 asks for and the gap may be nothing but clock scaling — a clean
  rerun on battery, settled longer after the scrollback fill, should come first. Wakeups are
  **fine** and should not be chased: package idle exits are ~0/s.
  The shape is the finding. Baseline idle is ~0.25%; the whole miss is a spike **every 10
  seconds**, which is `rttTask`'s cadence and the only 10 s timer in the app — and the cost scales
  with pane count, since the one-pane arm shows the same probe at the same cadence for ~0.01%.
  *Not* established: why work proportional to pane count follows an RTT answer. The obvious
  candidate is that `rttMilliseconds` lives on `HostState`, so a probe answer diffs as a real state
  change, broadcasts, and rebuilds a SwiftUI tree holding 20 panes — four `display-message` round
  trips cannot cost 13.9% of a core by themselves. An attempt to confirm that in an isolated
  harness was inconclusive and is not evidence: the harness ran the app against a scratch `HOME`
  and behaved in ways that did not reproduce in an ordinary run.
  *Do:* **confirm the mechanism first**, on a normal run under Instruments — the cadence and the
  scaling are facts, the broadcast path is a guess, and it would be easy to "fix" the wrong thing.
  If it is the broadcast: the RTT is a status-bar readout (F4.29) and nothing about a pane depends
  on it, so it can be excluded from the diff that decides whether to broadcast and published on a
  narrower channel, or coalesced so it cannot fire more often than the tree can afford. Verify by
  re-running the arrangement, not by reasoning: the cost is in the rebuild, which no unit test sees.
  `Sources/tetmuxCore/Session/SessionService.swift` (`rttTask`, `ingest`),
  `Sources/tetmuxCore/Session/HostModel.swift` (`rttMilliseconds`)

- [ ] **P6.4's output half: the byte handoff is per-chunk, not per display frame.** The input
  direction complies — keystrokes coalesce into one `send-keys -H` per 8 ms flush, and
  acknowledgements batch at 16 KiB — but the surface feeds the emulator once per `%output` chunk
  and nothing in the tree is ProMotion-aware; there is no display link anywhere. SwiftTerm's own
  redraw coalescing is what keeps the paint rate sane, which may make this a non-problem in
  practice, but P6.4 as written asks for per-frame batching of the handoff itself.
  *Do:* measure first — `Scripts/measure-latency.sh` is the tool, and the P6.1 entry above is the
  other end of this question: with the protocol under 2 ms, everything left in keypress→glyph is
  the draw side, so a change to how panes schedule drawing shows up in that measurement. If
  per-chunk feeding shows up, coalesce
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

- [~] **P6.7's memory: the bound is met and the cell is 24 bytes. What is left is an optimisation
  nobody is owed.** Measured 2026-08-06 on the real arrangement (`docs/measurements.md`): **72 MB**
  with one pane and **547 MB** with 20 across 4 hosts, which is 25 MB per additional pane at the
  default 10 000 lines. Against the amended bound — < 90 MB with one, < 30 MB for each additional —
  that **passes**, and it passes nearly by construction, since the bound was drawn from these
  numbers with headroom. What it buys is a regression check rather than a validation, which is why
  the arithmetic is pinned (`PaneMemoryTests`) rather than trusted.
  The cause is settled and is not a defect: `SwiftTerm.CharData` is **24 bytes**, of which
  `Attribute` is 14 — two 4-byte `Color`s, because truecolor needs three components and a tag,
  twice. 10 000 lines of an 80-column pane is 18.3 MB in cell data alone. **Nothing is leaked and
  nothing is wrongly retained**, which is the thing worth knowing before anybody goes looking.
  The user-facing half **shipped on 2026-08-06**: the settings pane shows the per-pane cost beside
  the scrollback picker and updates it as you choose, and the README carries the table and the
  advice for anyone wanting a smaller footprint.
  Parked rather than open, because the requirement is met and the two remaining levers are choices
  rather than work owed. (1) **Lower the default from 10 000**, which scales the dominant term
  exactly — but that is a question about what a terminal's history is worth, not one measurement
  answers, and the setting now makes it the user's call. (2) **Pack the attribute** into a palette
  index, taking a cell from 24 bytes toward 8 — upstream work in SwiftTerm, worth raising there and
  not worth forking for. Un-park this if the default changes or if SwiftTerm's cell size moves, in
  which case `PaneMemoryTests` fails first and says so.
  `Sources/tetmuxUI/TerminalSurface.swift` (`TerminalTheme.scrollbackLines`),
  `Tests/tetmuxTests/PaneMemoryTests.swift`

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
