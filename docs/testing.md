# Testing and measuring

Split out of `CLAUDE.md`. How verification works here: §6's measurement discipline first (the
numbers themselves live in `docs/measurements.md`), then the test suite, its fixtures, and the tmux
version matrix.

## Measuring (§6)

Verification is **local and scripted, not CI** — the SRD's decision (§6, §8), on the same argument
the fixture matrix rests on: a hosted runner measures the runner. `docs/measurements.md` holds the
numbers with the machine beside each, and is written to rather than edited, because the point of the
table is the trend. Three things about the harness are worth knowing before extending it.

**A perf harness measures itself first, and the wrong answer looks exactly like a finding.** P6.3's
first run read 23 MB/s in release — half the floor, a plausible number with a plausible story. It
was the test: it sliced the fixture at its first `%output`, so the repeated body carried no
handshake, and `ControlCodec` skips everything before the first `%begin` with a substring search
that allocates at every position. A startup path the app runs a handful of lines through, run over
every line forever. Handshake once then output repeated, and the same bytes measured 396 MB/s. The
fully-decoded assertion beside the rate is the standing guard against the other direction: a parser
that is fast because it is dropping the payload measures wonderfully.

**A floor has to name its build.** A debug build of the codec is **17× slower** than the release one
— no optimisation, retain/release around every array, bounds checks on every subscript. So
`CodecThroughputTests` asserts P6.3's real 50 MB/s only when built release, and 5 MB/s in debug as an
order-of-magnitude tripwire that survives a slow runner while still catching the complexity class of
mistake above (which measured 2 MB/s in debug against 18 for the same bytes). Anything quoting a
debug number as a performance figure is quoting the wrong program.

**A tracer is inside every number it reports, and here it was a third of one.** P6.7's 711 ms warm
launch was taken under Instruments' App Launch template. Its `Process Creation` phase is ~290 ms for
tetmux — and **413 ms for Calculator**, with no main-thread samples in it at all, the first sample of
any trace landing where that phase ends. So it is mostly `xctrace` launching a process under ktrace.
`LaunchProbe` answers the other question — the kernel's `p_starttime` to the first frame, with
nothing attached, closed from a 1×1 probe view added at `applicationDidFinishLaunching` — and reports
268–288 ms, inside the floor. The trace is still what says *where* the time goes (`xctrace export` on
the `time-profile` table, aggregated over a phase window, needs no Instruments UI); the untraced probe
is what says how much of it a user pays. Neither replaces the other.
**P6.7 names *warm* launch** since the 2026-08-06 amendment. A cold one is ~898 ms, of which ~630 is
an empty page cache paid inside AppKit's framework first-use — no tetmux symbol in it — so that half
was amended out rather than chased, deliberately and not because it was incoherent. `TODO.md` keeps
what was ruled out.

**P6.1's two ends are in code we do not own, and neither could be an override.** SwiftTerm declares
`TerminalView.keyDown` and `draw` `public` rather than `open`, which closes both to a subclass in
another module. The keystroke end moved to `KeyEventMonitor` — a local `NSEvent` monitor runs before
`sendEvent` dispatches, so it is *earlier* than `keyDown` and is the honest start. The draw end has
no such hook, so `LatencyProbe` closes the interval from a 1×1 overlay **subview** of the pane,
marked dirty when the echo lands: AppKit draws a view's own content before its subviews, so the
overlay's `draw` runs in the same cycle, after the terminal has painted. `viewWillDraw` on the pane
was the alternative and would understate every sample by one full-screen draw. What is still outside
the interval is the window server and the display — unreachable from the process, so every P6.1
figure understates by up to a frame and the record says so.

The probe is off unless asked (`TETMUX_MEASURE_LATENCY`, or a live signpost trace), which is what
keeps the byte scan for the echo off the path P6.3 is a promise about. Same for
`TETMUX_MEASURE_LAUNCH`: no variable, no probe view, no `sysctl`.

**…and the bound P6.1 is judged against is the panel's rate, so the rate goes in the record.** The
probe carries a `CADisplayLink` and every sample records `targetTimestamp - timestamp` at the moment
of the draw; `measure-latency.sh` derives the bound from it instead of quoting a flat 12 ms the SRD
no longer states. Checked against two known answers — 10.00 ms over 4500 callbacks on a monitor fixed
at 100 Hz, 16.67 ms over 2610 on the built-in panel — which is what makes the numbers usable, and
under which **P6.1 passes on both**.

**The premise it was built on was wrong, which is the part worth remembering.** The justification was
that `CGDisplayCopyDisplayMode` reads 0 on a ProMotion panel. It does not read 0 here — it reports
60.0 for the built-in and 100.0 for the external, `NSScreen.maximumFramesPerSecond` agrees, and this
machine has no ProMotion at all (a MacBook Air; all 18 of the built-in's modes are 60.0 Hz, so it was
never idling down and the external monitor cannot have dropped it either). One line of `NSScreen`
would have answered what four runs had left open, and the "adaptive panel" story explaining the
slower built-in figures was explaining something that was not happening — a 60 Hz frame is simply
16.7 ms. The instrument is still the right one, because measuring the rate at the draw is what would
survive a display that really varies; but check the cheap API before building the instrument.
One caveat does survive for such a display: a display link is content that is not static, so the rate
it reports is an **upper bound** on what an unwatched panel would idle to — a run that passes would
also pass without it, a run that fails proves nothing.

**`HOME` does not isolate the app's state files, and assuming it did cost a real workspace.**
`TMUX_TMPDIR` genuinely gives a measurement run its own tmux server, so keystrokes land in a
throwaway shell. `HOME` does *not* do the equivalent for `~/Library/Application Support/tetmux`:
`FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)` resolves the real home
from the password database and ignores the environment, so a run launched with `HOME` pointed at a
scratch directory still reads and rewrites the user's actual `hosts.json` and `workspace.json`. The
measurement scripts therefore copy `workspace.json` aside and restore it in their exit trap.

Two things followed from getting this wrong, both worth knowing because they look like product bugs
and are not. A scratch-`HOME` run **restores the user's real windows**, so it can open a window per
saved host — which reads as "the app opens four windows on a fresh launch". And a `workspace.json`
written into the scratch directory is never read *or written* by the app, so watching it shows a
file that never changes: pending restores that appear never to resolve, and an apparent absence of
state broadcasts. Both were chased as defects. Neither exists.


## Testing

`SessionIntegrationTests` drives a **real PTY against the real tmux server** on the machine. It
creates and kills its own uniquely-named sessions, and skips entirely when tmux is absent. It also
spawns a dozen children concurrently on purpose — that is the fork-safety regression, and it fails
as a hang rather than an assertion. CI installs tmux and fails if that skip fires: a skipped test is
indistinguishable from a passing one in a green check.

**There are two test targets, split along AppKit.** `tetmuxCoreTests` depends on `tetmuxCore` alone
and holds everything that replays a fixture or exercises a pure value type — the codec, the matrix and
its `Fixtures/`, the layout parser, the prompt detector, `TmuxCommand`, `HostModel`. That target is
the entire reason the Linux job can run a test rather than only a build (see `docs/build-and-release.md`), so **anything
added there must not reach for AppKit, SwiftTerm or a live tmux server**; those belong in
`tetmuxTests`, which links `tetmuxUI`. `AppModelTests` covers the decisions that need no channel and
no window — the F4.9 close decision, scope resolution, keymap matching, tab-drop arithmetic, workspace
resolution, F4.31's activity transition — which were previously unreachable rather than untested.

**An `AppModel` in a test must be given a directory.** It writes files as a side effect of ordinary
operations: rebinding a chord persists `settings.json`, and selecting a session or registering a
window schedules a `workspace.json` save. A default-constructed one in a test therefore writes the
*user's* files, and did — running the app after the suite found `testOnlyEditedBindingsAreStored`'s
keymap in it. Hence `AppModel(directory:)` and the per-test temporary directory in `setUpWithError`.

**A test that needs a resource the machine may not have skips; it does not fail.** `setUp` skips the
whole suite when tmux is absent, and the `ControlMaster` scenario skips unless `TETMUX_SSH_HOST` names
a host ssh can reach **without a password** (`BatchMode=yes` is the check — a host that would prompt
is no use to a suite nobody is watching). Written with `XCTUnwrap` instead of `XCTSkip` it goes red on
every machine but one, which is how it was written the first time. A test against somebody's real
machine also has to leave nothing behind: only sockets that appeared during the run are removed, the
remote session is uniquely named and killed, and the `ControlPersist` master is closed with
`-O exit` **at tetmux's own control path** — ssh finds a master by path, so the default one exits zero
having done nothing and leaves a live connection open.

**Killing a channel is asynchronous, so a test has to watch the state *leave* `.connected` before
waiting for it to come back.** `SIGKILL` returns the moment the signal is delivered; the pty EOF that
turns a dead process into a dead channel arrives later. A test that kills and then waits for
`.connected` matches the *stale* value instantly, and everything it does next happens in the window
between teardown and the next spawn — where `connections[hostId]` is nil, `sendKeys` drops the
keystroke, and the evidence reads exactly like a session that reconnects and then ignores its
keyboard. That cost an evening and produced a TODO entry about a bug that did not exist. The dropped
keystroke is correct behaviour, incidentally, and consistent with the outbox's age limit: keys typed
at a host with no channel are not worth replaying.

**…and a recovery a test would get anyway is not evidence that the thing under test did it.** The
sleep/wake scenario is the case: a dropped link reconnects on its own, so a wake test that killed
the channel, called `probeAllConnections()` and asserted reconnection would pass with the entire
wake path deleted. What F4.18 actually buys is *promptness* — a machine shut for an hour is sitting
on a retry scheduled up to a minute out — so the test drives the backoff to a retry far enough away
to be told apart from a wake (attempt 5, whose delay is `2^4` s ±20% and therefore at least 12.8 s
out) and then asserts the host is back inside ten seconds. "Asleep" is a flag file the stand-in ssh
checks, which is what makes the attempts climb; removing it is the lid opening. Any test of a
mechanism that overtakes an existing one has to be written this way, or it asserts the mechanism it
is overtaking.

**A test's deadline has to be inside the work, not wrapped around it.** Pane output is read by
`collect(_:until:seconds:)`, which starts reading before the keystrokes that produce the output and
stops on the marker *or* on a deadline of its own. It replaced a `withTimeout` helper that raced an
arbitrary operation against a sleep in a task group — which cannot bound work it does not own. Its
callers all passed `{ await someTask.value }`, and awaiting an **unstructured** task's value is not
cancellable: when a marker never arrived, the timeout fired, `cancelAll()` could not stop that child,
and the group's teardown waited on it for ever. Every bound in the test was bypassed by the mechanism
meant to enforce them, and the suite stalled with no assertion, no output and no test name — which is
the worst failure mode a test can have. Both of `collect`'s children are structured, so cancellation
reaches them (`for await` on an `AsyncStream` returns nil, `Task.sleep` throws). It returns what
arrived rather than throwing, so a missed marker **fails with the output it did get** instead of
skipping — a skip being exactly as green as a pass.

Flow-control decisions are asserted through the **diagnostic logger**, not `HostState`: pausing a pane
is a property of the channel and deliberately invisible to the model, so `LogSink` is the only seam
there is. The stalled-viewer test never reads its stream, on purpose — reading it would make the test
measure nothing.

Protocol tests replay byte streams captured verbatim from tmux 3.7b. When fixing a protocol bug, add
the real captured bytes rather than a hand-written approximation.

**The R3.6 matrix is real now, and it is a local recording rather than a CI job.**
`Scripts/build-tmux-matrix.sh` builds tmux 3.0/3.2a/3.3a/3.4/3.5 from pinned, checksummed tarballs
into a gitignored `.tmux-matrix/`; `Scripts/capture-fixtures.py` drives each under a pty and writes
`Tests/tetmuxCoreTests/Fixtures/tmux-<version>.<scenario>.stream`; `ControlCodecMatrixTests` replays
them. Capture must **not** move into CI: a fixture's value is that it is a frozen record, so a
regression shows as the parser disagreeing with it — regenerate it each run and the test asserts
"the parser agrees with whatever tmux just said", which is true by construction. The inputs are
pinned releases, so a rebuild is byte-identical forever. The scripts exist for *provenance*: without
them the fixtures are one person's word about what they once saw.

**…and the integration suite runs across it too, which is a different property.** The fixtures pin
what each version *says*; `Scripts/test-matrix.sh` pins what tetmux *does* about it. It is a CI job
(`matrix` in `ci.yml`) rather than a per-push one: **weekly, plus `workflow_dispatch`, plus a `v*`
tag** — press the button after touching a version-conditional path. Not on pushes or pull requests,
because building tmux from a pinned tarball is minutes of `./configure && make`; `actions/cache`,
keyed per version, pays that once. The tag is the exception because a tag is the only event that
produces something a user installs, and a tag can be cut from a commit the cron has never swept — so
that is where R3.6's compatibility claim stops being a note and becomes a promise, and where the
matrix blocks the release rather than going red beside a published one. Two costs are accepted with
it: a 7-day cache eviction against a 7-day cron means a tag build usually rebuilds all five from
source, and a tarball fetch is now a network dependency in the release path.

**The CI job is a `strategy.matrix`, one parallel runner per version, and the script is still the
single implementation** — it takes a version list, and each job passes it one. Sequential is right on
a laptop, where five versions share one build of the test bundle; in CI it turns five ~90-second runs
into one eight-minute job with a single pass/fail at the end. Split, the wall clock is the slowest
version rather than the sum, each version has its own cache entry and its own line in the checks
list, and `fail-fast: false` means a 3.0 regression does not cancel the other four — which version
disagrees is the whole information the matrix exists to produce. It costs more machine-minutes than
it saves in wall clock, deliberately: the value of on-demand is an answer while you are still looking
at it.

**And "no tests ran" is never a pass.** `swift test` writes its summary two ways — `Executed 60
tests, with 0 failures`, and once anything skips, `Executed 60 tests, with 2 tests skipped and 0
failures` — so the script takes the count on its own rather than matching the sentence. Matching the
sentence is what it did first, and the day a test started skipping it printed "no tests ran" with a
tick beside it. A run that reports no count, or a count of zero, now fails: exit status zero having
run nothing is the same green-check-that-means-nothing this whole area exists to prevent. It is where the version branches live — per-window sizing off below 2.9, tab reordering as `move-window -b` on
3.2 and a run of `swap-window`s below it, pane commands subscribed on 3.2 and polled below, no flow
control at all before 3.2. `PtyTransport.resolveTmux` reads `TETMUX_TMUX` to pick the binary, and it
is **local-only by design**: a remote host runs whatever its own login shell finds, so a path on this
machine would name a binary that is not there. A named binary that cannot be executed returns `nil`
rather than falling back to `PATH`, because a typo that quietly used the system tmux would report
five passes for one version.

Most of the value needed no new tests: several already assert an *outcome* and take whichever branch
the server supports, so the same assertions under 3.0 are the only thing that has ever executed the
`swap-window` fallback end to end. What it did need was **isolation**, and finding that out was the
first thing the matrix did. Every test now gets a tmux server of its own (`TMUX_TMPDIR` per test,
`kill-server` in `tearDown`), because sharing the machine's server had been hiding two real defects:
a test that probed an untouched host and asserted a non-empty answer, which is true only on a machine
that already has sessions; and leaked clients — a `SessionService` that is never disconnected leaves
a live `tmux -CC` attached — accumulating until the run wedged, after which every remaining test
timed out at fifteen seconds saying nothing about why. Anything that stands in for a *remote* host
with a shell script has to put the matrix binary on its own `PATH` (`matrixPathExport`): those
scripts share this machine's `TMUX_TMPDIR`, so a stand-in running the system tmux starts a server of
the wrong version on the socket every later test is using, and a tmux client cannot speak to a server
of another version.

**…and `TMUX_TMPDIR` does not isolate anything from inside a tmux pane, which is where this app's
own author works.** A tmux client given neither `-S` nor `-L` derives its socket from **`$TMUX`**
when that is set, and only falls back to `$TMUX_TMPDIR/tmux-<uid>/` when it is not — so the whole
per-test isolation above silently inverts for a suite run from a pane. That is not a hypothetical:
it is exactly how a debug build launched with a scratch `TMUX_TMPDIR`, to keep it away from the
installed one, attached to the real server instead and detached nothing it was supposed to. The
sharp edge is `tearDown`'s `kill-server`, which under a leaked `$TMUX` names the user's own server.
Run the suite and the measurement scripts as `env -u TMUX swift test`; a stray `SIGKILL` of a
tetmux under test also leaves `window-size manual` on whatever session it was attached to, which is
the ordinary graceful-teardown promise going unkept and wants `set-option -u window-size` by hand.

Three things keep a capture a record of a **version** rather than of a machine, and each was a real
leak before it was fixed: `-f /dev/null` so nobody's `~/.tmux.conf` gets in; every pane running
`cat` so a fixture holds protocol instead of somebody's shell prompt; each binary installed as plain
`tmux` in a directory of its own, because tmux names a window after the command running in it and a
binary called `tmux-3.5` puts `%window-renamed @0 tmux-3.5` in the stream. Automatic rename is off
by default in the preamble for the same reason — one 3.0 capture came back naming a window
`kernel_task`.

Assertions are about **structure, not bytes**: captures carry wall-clock timestamps and server-wide
command numbers, so two recordings of one version are never identical and a golden file would fail
for reasons nobody can act on. What is pinned is that the same actions build the same model on every
version, plus the protocol facts the code branches on. `SshPromptDetectorTests` follows the
same rule with OpenSSH: its fixtures were captured by driving `ssh` and `ssh-keygen` under `pty.fork`,
and the details a plausible-looking fake gets wrong (the leading `\r`, the trailing space, the absent
newline) are exactly the ones detection depends on.

The password path is covered end to end without a password-accepting host: `writeFakePasswordSshScript`
stands in for ssh — it prompts on the pty, reads one line, and only then execs the tmux command it was
handed, so the real detect → publish → answer → handshake sequence runs against local tmux.

**§8's program corpus uses tmux as the reference terminal, and that is the claim rather than a
convenience.** `ProgramRenderingTests` replays a recorded `%output` stream for `vim`, `htop`, `less`, `top` and a
Powerline prompt into a `Terminal` and compares the grid cell for cell with
`capture-pane -p` on the pane it was recorded from. A third-party emulator would answer a more
general question than anything here depends on: tetmux asks tmux for `frame.width / cellWidth`
columns and renders the layout tmux computes from that answer, so the property that matters is that
*these two* build the same grid from the same bytes. Both halves come out of one run of one pane
(`Scripts/capture-programs.py`), which is what makes them describe the same instant.

Three things about it, each of which produced a failure that reads like an emulator disagreement and
is not one. **The reference must be frozen before it is read**: a program that repaints on a timer
writes more frames while `capture-pane`'s answer is being collected, so its process group is
`SIGSTOP`ped — the *group*, because a pane command that is a shell with a job in it does not `exec`
and `#{pane_pid}` then names the shell rather than the program. **And the stream is truncated at the
capture block's `%begin`**, because tmux writes a pane's `%output` and a command's `%begin` into one
client buffer in the order it dealt with them: everything before that line is in the grid being
answered with and everything after it is not. Freezing alone is not enough, and truncating alone
would be if the freeze failed silently, which is how the first two recordings passed inspection.
**A `\0` cell means two different things**: width 0 is a wide character's continuation and
contributes nothing, while width 1 is a cell nothing was ever written to and is a *space*. Treating
them alike collapses every run of untouched cells, which showed up as `top`'s header losing the gaps
between its columns while every other row matched exactly.

A program corpus is also a recording of a *program*, so each grid carries the version that produced
it in a header, and the recorder keeps the machine out of the fixture the same way
`capture-fixtures.py` does: `vim -u NONE`, a fixed sample file at a fixed path, and both process
viewers restricted to one process — `top` to a `sleep` this script started, `htop` to pid 1. Plain
`top` committed a corpus file naming every application the user had open.

`TerminalGeometryTests` covers the scroller gutter and the font-derived cell round trip but is not
the geometry suite §8 asks for; the seeded resize storm in `SessionIntegrationTests` is.

