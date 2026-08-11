# TODO

This file holds what is **open** — with the evidence that it is open and instructions concrete enough
that the work can start from the entry alone — and what is **parked**, marked `[~]`: work that could
be done and deliberately is not, carrying the reason and enough of the investigation that un-parking
it does not start from nothing. An unlisted requirement reads as done — that is the failure mode this
file exists to prevent, so anything the SRD asks for that the tree does not do belongs here.

**Closed work is not recorded here, deliberately.** It leaves as an invariant in `CLAUDE.md`, an
amended requirement in `tetmux-srd.md`, or a row in `docs/measurements.md` — where it is next to the
thing it constrains, and where somebody will actually meet it. A second copy in this file would be a
list nobody reads twice and one that drifts from the original the first time either is edited;
`git log` holds the narrative. This paragraph replaced ninety lines of exactly that on 2026-08-07.

**As of 2026-08-11: 1 open, 6 parked, and nothing here blocks a release.** On 2026-08-06 the last
two then-open entries left the list without being implemented, and both say so where it counts
rather than here: P6.7's launch half was amended to name **warm** launch (SRD §6,
`docs/measurements.md`), and signing moved from *blocked* to *parked* (SRD §2.5), because "blocked
on an Apple Developer account" described a purchase nobody intends to make as though it were a
queue. A decision recorded only in a TODO list reads as outstanding work forever, which is why
those two sentences are in the SRD.

References point into current `main`. Line numbers drift; the symbol names beside them do not.

---

## Open

- [ ] **Check F4.36's two ⌘ advertisements against the running app: does each surface actually
  update while it is visible?** Both were flagged by review on 2026-08-11 and neither is verified.
  The click paths are correct either way — they read live `CommandKey.isHeld` at click time — so
  what is at stake is only the *advertisement*; but the advertisement is the feature's whole answer
  to "the words and the click must agree", so a surface that does not update is worse than one that
  says nothing.
  (1) The sidebar context menu's title (`SidebarView.swift`, "Copy Attach Command Without ssh")
  switches on `menuModifiers.isCommandHeld` while the menu is open. That an *open* menu re-renders
  its SwiftUI content mid-tracking is demonstrated for `MenuBarExtra` and **assumed** for
  `.contextMenu`, whose `NSMenu` bridging is different and may snapshot its items at open. If it
  snapshots: right-click, *then* press ⌘ — the ordinary order — leaves the plain title up while the
  click copies the short line, and the tree's only in-place advertisement of the modifier never
  appears. The fix would be another channel (the item's `.help` is already there, or an armed
  appearance like the ⌥ close buttons), not more title logic.
  (2) The toolbar tooltip (`AttachCommandButton` in `AppMain.swift`): its `.help` string changes
  with ⌘, but an AppKit tooltip that is *already showing* may not redraw when the string changes —
  hover, read the ssh line and its "hold ⌘" hint, follow the hint without moving the mouse, and the
  tooltip may keep showing the ssh line while ⌘-click copies the short one, for the whole hover
  rather than the one frame the monitor convention budgets for.
  How to check is the convention `docs/behavior.md` already states for menus: against the running
  app, not by reading — remote host selected, press and release ⌘ with the menu open and with the
  tooltip up, watch whether the words move. Whichever half fails, record what was seen here and
  change that surface.

## Parked by decision

- [~] **`reachingHost:`'s polarity is inverted relative to the modifier that drives it.** Every UI
  call site writes `reachingHost: !CommandKey.isHeld` (or `!modifiers.isCommandHeld`), and that `!`
  is boilerplate whose absence reads plausibly: a future call site that writes
  `reachingHost: CommandKey.isHeld` — "pass the modifier through" — inverts the feature silently,
  and no test covers the UI call sites. Flipping the parameter to match its driver (e.g.
  `fromShellOnHost: Bool = false`) would remove every negation and let the tests' explicit `false`
  become the droppable default. Parked 2026-08-11 rather than folded into the review fixes, because
  the name is load-bearing prose by now: F4.36's amendment and `docs/behavior.md`'s entry both
  explain the feature as what "reaching the host" includes, and renaming the parameter means
  rewriting both for a saving of four `!`s. Un-park if a fifth call site appears, or the first time
  the sign is actually written backwards.
  `Sources/tetmuxCore/Session/TmuxCommand.swift` (`attachCommandLine(host:sessionName:reachingHost:)`)

- [~] **P6.7's cold launch: ~898 ms, amended out of the requirement rather than fixed.** The
  requirement now names **warm** launch, which passes at 268–288 ms (SRD §6, and the reasoning is
  there rather than here). This entry survives because it holds what was measured and what was ruled
  out, which is the expensive half and would otherwise have to be rediscovered.
  The 711 ms and 985 ms in `docs/measurements.md` were taken under Instruments' App Launch template, and the
  overhead that is inside every one of its phases was assumed small. It is not: `Process Creation`
  is ~290 ms for tetmux and **413 ms for Calculator**, an application with no scene of ours in it,
  and the time profiler records **no main-thread samples in that phase at all**. Roughly a third of
  each traced number is `xctrace` launching a process under ktrace.
  Untraced — `Scripts/measure-launch.sh --untraced`, where `LaunchProbe` times the kernel's
  `p_starttime` to the first frame with nothing attached — the median is **268–288 ms across two
  sets of runs**. The packaged `.app` is also not slower than the bare binary (699.8 ms against
  710.8 traced), which removes that caveat too.
  *Also answered:* the Scene Creation window holds no hot spot and no tetmux symbol. Read out of the
  trace with `xctrace export` on the `time-profile` table, its 215 ms of main-thread samples are
  AppKit 30, libobjc 27, CoreFoundation 24, libswiftCore 20, SwiftUI 14, CoreUI 14, dyld 10 — class
  realization, category attachment, bundle localization scans, the font registry, asset lookups,
  `NSWindow` init and SwiftUI graph construction. Framework first-use, spread thin. There is no
  single change to make there, which is consistent with an empty page cache costing that phase
  210 ms while costing tetmux's own launch code nothing — and it is why this was amended rather than
  chased: the 630 ms is not in code this project writes.
  *Ruled out already:* SwiftTerm ships `Shaders.metal` as source rather than a compiled
  `.metallib` (see the packaging note in `CLAUDE.md`), and `makeLibrary(source:)` would be exactly
  the kind of disk-read-then-compile that fits this shape — but tetmux never enables SwiftTerm's
  Metal renderer, so it is never on the launch path. Do not chase it again.
  *If it is ever un-parked*, the target is the **210 ms an empty page cache adds to AppKit Scene
  Creation** — the only phase that grows when the cache is emptied. What is worth trying is whether
  the first frame can be built touching fewer distinct SwiftUI/AppKit subsystems — the sidebar, the
  tab strip, the status bar and the menu-bar extra are all constructed before it — measuring after
  each, since none of this is predictable from reading. Purged and untraced the median is
  **897.8 ms**, spread 579.7–1012.3 across five runs, and a first launch of a freshly linked binary
  measured 1192 ms independently; those are the numbers to beat.
  Whoever runs it: **not under `sudo`**. The script escalates for `purge` itself and now refuses to
  run as root, because as root the app reads root's Application Support and gets no dyld launch
  closure; that produced 1100.7 ms, *above* the traced figure, which is backwards and is how the
  confound was spotted.
  `Scripts/measure-launch.sh`, `Sources/tetmuxUI/LaunchProbe.swift`

- [~] **Developer ID signing, notarisation, hardened runtime, and an updater (§2.5).** Signing is
  ad-hoc (`codesign --sign -`), so a first open is right-click → Open or
  `xattr -dr com.apple.quarantine`, which the release notes and the README both state at the
  download. Parked 2026-08-06, moved here from *blocked*: notarisation needs a paid Apple Developer
  account, §1 says tetmux is built for one person's daily use, and that person is content with the
  one-time step — so this is a purchase deliberately not made, not a queue. Calling it blocked
  implied somebody was waiting for it.
  *If an account arrives* — sponsored, bought, or because the friction started landing on somebody
  else — sign with the Developer ID Application cert plus `--options runtime --timestamp` in
  `package-dmg.sh` (the ad-hoc branch stays for local builds); `xcrun notarytool submit --wait` +
  `xcrun stapler staple` in the `v*` tag job, with the account's app-specific password as a repo
  secret; then Sparkle via SPM, an EdDSA key kept offline, and an appcast served from GitHub
  Releases. A Homebrew cask is worth doing at that moment and not before, since a cask of an
  un-notarised build hands the same Gatekeeper step to someone who did not read the README. The DMG
  stays arm64-only by decision — do not revisit universal as part of this.
  `Scripts/package-dmg.sh:136`, `.github/workflows/ci.yml`

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
