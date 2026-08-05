# TODO

Rewritten from scratch on 2026-08-05 against `tetmux-srd.md` v2.1, which absorbed the audit's
history: everything the old file recorded as done is now either an invariant in `CLAUDE.md` or an
amended requirement in the SRD, and repeating it here would be a second copy that drifts. This file
holds only what is **open**, with the evidence that it is open and instructions concrete enough
that the work can start from the entry alone. An unlisted requirement reads as done — that is the
failure mode this file exists to prevent, so anything the SRD asks for that the tree does not do
belongs here.

**3 features, 1 blocked, 2 parked.** The six small items this file opened with, copy mode, and the
integration matrix were closed on 2026-08-05, and the matrix's own follow-ups on 2026-08-06; what
they turned into is recorded in `CLAUDE.md`, not here.

References point into current `main`. Line numbers drift; the symbol names beside them do not.

---

## Features, sized like features

- [ ] **Chaos tests (§8).** None exist. Each scenario must end in a defined state and recover.
  *Do,* as integration tests where the machinery allows: (1) kill the spawned process mid-stream
  (`SIGKILL` the transport's child — the fake-ssh script precedent shows how to interpose) and
  assert EOF → backoff → reattach → repaint; (2) `SIGSTOP` the tmux server, assert the RTT probe
  reports the stall and `sendAndAwait` times out without wedging the actor, then `SIGCONT` and
  assert recovery; (3) drop the `ControlMaster` socket file mid-session and assert the next
  channel rebuilds it. Sleep/wake stays manual — `pmset sleepnow` on a test box is not a CI
  citizen — but scriptable as a documented manual pass alongside the P6 harness.
  `Tests/tetmuxTests/SessionIntegrationTests.swift`

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
