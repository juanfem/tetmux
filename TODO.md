# TODO

Rewritten from scratch on 2026-08-05 against `tetmux-srd.md` v2.1, which absorbed the audit's
history: everything the old file recorded as done is now either an invariant in `CLAUDE.md` or an
amended requirement in the SRD, and repeating it here would be a second copy that drifts. This file
holds only what is **open**, with the evidence that it is open and instructions concrete enough
that the work can start from the entry alone. An unlisted requirement reads as done — that is the
failure mode this file exists to prevent, so anything the SRD asks for that the tree does not do
belongs here.

**1 feature, 1 blocked, 3 parked.** The six small items this file opened with, copy
mode, and the integration matrix were closed on 2026-08-05, and the matrix's own follow-ups on
2026-08-06; what they turned into is recorded in `CLAUDE.md`, not here. The five entries added on
2026-08-06 came out of an adherence review of the tree against SRD v2.1 — a review that mostly
found the *documents* behind the code, and amended the SRD's stale status notes in the same pass.
The launcher's half of that batch (F4.25/F4.26) closed the same day.

**The three tests the SRD was owed closed on 2026-08-06**, and §8's status notes moved with them.
T5.2 is asserted on both paths a pane's bytes arrive by. Sleep/wake is tested at its seam, and the
assertion is promptness rather than recovery — a dropped link comes back on its own, so the host is
driven to a parked retry first and the wake has to beat it. The program-level rendering corpus
(`vim`, `htop`, `less`, `top`, a Powerline prompt) is recorded by
`Scripts/capture-programs.py` and compared against **tmux's own** rendering of the same bytes; why
that is the right reference, and the three ways a recording of it can be a frame or a column wrong,
are in `CLAUDE.md`. Everything left below is a feature, a credential, or a decision.

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

Where that first pass left §6, and the honesty matters more than the tally. **P6.3 passes
outright**, with
6.5× of room. **P6.7's memory half passes the amended bound** — but that bound was drawn from these
measurements with headroom, so it passes nearly by construction; what it buys is a regression check,
not a validation. **P6.1's verdict is not yet knowable**: under the amended rule it passes on the
100 Hz external monitor, and passes on the built-in panel *if* that panel is at 60 Hz while failing
if it is at 120 — and nobody has measured which. **P6.6 and P6.7's launch half fail**, by 3.7× and
2.5×, each with an entry below carrying its measurement as evidence.

**A second pass on 2026-08-06 answered three of the four, and two of the answers were about the
harness rather than the product.** They are recorded in `docs/measurements.md` with the numbers.

*P6.1 is met on both displays, and is closed.* Every sample records the frame interval the compositor
was on at the moment of the draw, so the script applies the amended bound instead of a flat 12 ms:
**100.0 Hz over 4500 callbacks** on the external monitor and **60.0 Hz over 2610** on the built-in
panel, bounds of 12.00 and 18.67 ms against p95 of 11.37 and 11.28. The two earlier built-in runs
pass under the same rule (14.28 ms on AC, 17.84 on battery, both inside 18.67).

Two things the previous entry asserted turned out to be wrong, and they are why it stayed open. The
built-in panel is **not ProMotion** — this is a MacBook Air (Mac15,13), and
`CGDisplayCopyAllDisplayModes` offers 18 modes for it, every one 60.0 Hz, so it was never idling its
rate down, and the external monitor cannot have dropped it to 60 either: there is no higher mode to
drop from. And **`CGDisplayCopyDisplayMode` does not read 0 here** — it reports 60.0, with
`NSScreen.maximumFramesPerSecond` agreeing. That claim was the whole justification for building the
display link, and one line of `NSScreen` would have answered what four runs had left open. The
instrument is still the right one, because it measures the rate at the draw rather than the mode the
display is configured for, but it was built on a premise nobody checked first.

*P6.4 is closed.* The handoff is batched per display frame now, verified by counting: tmux emits
21 934 `%output` chunks a second for a busy pane — 219 per frame at 100 Hz — and the surface calls
`feed` exactly 100 times a second. It bought **no CPU at all** (108.2% of one core before, 106.9%
after), which is the finding: the dispatch is not where the time goes. It was kept because the
requirement is achievable and now achieved, not because it paid — and it cost no latency, which was
the risk.

*P6.6 is fixed and closed.* The ten-second spike was F4.29's round-trip reading living on the diffed
`HostState`: every probe answer was a state change, and every state change rebuilds a tree holding
every pane. It now travels on `SessionService.roundTripStream` and is read by one leaf view. On the
arrangement the requirement actually names — **20 panes, 4 hosts, on battery** — mean **1.83% of one
core became 0.14%** and the maximum 13.9% became 2.10%, against a 0.5% bar: inside it, where it had
been 3.7× over. The ten-second cadence is gone rather than reduced. Memory on the same arrangement is
unchanged at 550 MB.

*P6.7's launch half splits in two.* A third of every traced figure was `xctrace`: under the App
Launch template `Process Creation` is ~290 ms for tetmux and **413 ms for Calculator**, with no
main-thread samples in it at all. Untraced, the app times itself from the kernel's `p_starttime` to
first frame and a warm launch is **268–288 ms, inside the 400 ms floor**. Cold is a different answer:
purged and untraced the median is **897.8 ms**, so the page cache is worth ~630 ms and the
requirement — which says *cold* — is **missed by ~2.2×**.

References point into current `main`. Line numbers drift; the symbol names beside them do not.

---

## Features, sized like features

- [ ] **P6.7's launch half passes warm and misses cold by ~2.2× — and the old figure was partly the
  tracer.**
  The 711 ms and 985 ms in the table were taken under Instruments' App Launch template, and the
  overhead that is inside every one of its phases was assumed small. It is not: `Process Creation`
  is ~290 ms for tetmux and **413 ms for Calculator**, an application with no scene of ours in it,
  and the time profiler records **no main-thread samples in that phase at all**. Roughly a third of
  each traced number is `xctrace` launching a process under ktrace.
  Untraced — `Scripts/measure-launch.sh --untraced`, where `LaunchProbe` times the kernel's
  `p_starttime` to the first frame with nothing attached — the median is **268–288 ms across two
  sets of runs, inside the 400 ms floor**. The packaged `.app` is also not slower than the bare
  binary (699.8 ms against 710.8 traced), which removes that caveat too.
  *Also answered:* the Scene Creation window holds no hot spot and no tetmux symbol. Read out of the
  trace with `xctrace export` on the `time-profile` table, its 215 ms of main-thread samples are
  AppKit 30, libobjc 27, CoreFoundation 24, libswiftCore 20, SwiftUI 14, CoreUI 14, dyld 10 — class
  realization, category attachment, bundle localization scans, the font registry, asset lookups,
  `NSWindow` init and SwiftUI graph construction. Framework first-use, spread thin. There is no
  single change to make there, which is consistent with an empty page cache costing that phase
  210 ms while costing tetmux's own launch code nothing.
  *Ruled out already:* SwiftTerm ships `Shaders.metal` as source rather than a compiled
  `.metallib` (see the packaging note in `CLAUDE.md`), and `makeLibrary(source:)` would be exactly
  the kind of disk-read-then-compile that fits this shape — but tetmux never enables SwiftTerm's
  Metal renderer, so it is never on the launch path. Do not chase it again.
  **Cold is measured now and it fails**: purged and untraced, median **897.8 ms** against 400 ms,
  spread 579.7–1012.3 across five runs. The page cache is worth ~630 ms of that, and P6.7 says
  *cold*, so the warm pass does not discharge it — the requirement is missed by ~2.2×. A first
  launch of a freshly linked binary, which is the shape of a first launch after install, measured
  1192 ms independently.
  *Do:* the target is the **210 ms an empty page cache adds to AppKit Scene Creation** — the only
  phase that grows when the cache is emptied. Nothing tetmux does at launch grows, and the window
  holds no hot spot, so this is not about optimising our own code: the samples are class
  realization, category attachment, bundle localization scans, the font registry and asset lookups,
  each a first-use cost paid once per framework rather than per line of ours. What is worth trying is
  whether the first frame can be built touching fewer distinct SwiftUI/AppKit subsystems — the
  sidebar, the tab strip, the status bar and the menu-bar extra are all constructed before it — and
  measuring after each, since none of this is predictable from reading.
  Whoever runs it: **not under `sudo`**. The script escalates for `purge` itself and now refuses to
  run as root, because as root the app reads root's Application Support and gets no dyld launch
  closure; that produced 1100.7 ms, *above* the traced figure, which is backwards and is how the
  confound was spotted.
  `Scripts/measure-launch.sh`, `Sources/tetmuxUI/LaunchProbe.swift`

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
