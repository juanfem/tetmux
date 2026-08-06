# Measurements

What §6's performance requirements actually measure, on real hardware, with the date and the
machine beside each number.

Verification is **local and scripted, not CI** (§6, §8). That is the same decision the R3.6 fixture
matrix rests on: a measurement worth trusting is a reproducible local artefact, and a hosted runner
measures the runner. So the numbers below are recordings, in the same sense the `.stream` fixtures
are — a record of what this machine did on that day, which is a thing the next person can disagree
with. A number with no hardware beside it is not a measurement.

Each entry names the script that produced it. Re-run the script, add a row; do not edit an old one,
because the point of the table is the trend.

---

## P6.1 — keypress → glyph, local session

**Floor:** ≤ 12 ms at p95.
**Script:** `Scripts/measure-latency.sh` (release build, private tmux server, synthetic keystrokes).
**Instrumentation:** `Sources/tetmuxUI/LatencyProbe.swift`.

| Date | Display | Power | Samples | p50 | **p95** | max | |
|---|---|---|---|---|---|---|---|
| 2026-08-06 | external 3440×1440 @ 100 Hz | AC | 38 | 13.50 ms | **24.43 ms** | 24.88 ms | trailing-edge flush |
| 2026-08-06 | external 3440×1440 @ 100 Hz | AC | 148 | 11.11 ms | **11.54 ms** | 11.84 ms | leading-edge flush |
| 2026-08-06 | built-in 2880×1864 (ProMotion) | battery | 148 | 12.07 ms | **17.84 ms** | 17.94 ms | leading-edge flush |

All on an Apple M3, macOS 26.5.1.

**Missed by 2×, then met.** The split is what found it:

| | p50 before | p95 before | p50 after | p95 after |
|---|---|---|---|---|
| keypress → echo (off-machine and back) | 9.76 ms | 19.72 ms | 0.92 ms | 1.72 ms |
| echo → glyph drawn (AppKit + SwiftTerm) | ~3.7 ms | ~4.7 ms | ~10.2 ms | ~9.8 ms |

The round trip was the whole problem, and **8 ms of it was a timer we set ourselves**.
`SessionService.sendKeys` started a task that slept `keyFlushInterval` (8 ms) and *then* wrote, so a
keystroke with nothing to coalesce with — which is every keystroke at typing speed — waited the full
interval before anything left the process. p50 echo was 9.76 ms: 8 ms of sleep and 1.8 ms of real
work, on a session where tmux is on the same machine.

The fix was the edge, not the interval. Writing the first keystroke immediately and coalescing what
arrives during the window that follows leaves P6.4's batching exactly where it is needed — under
sustained typing the command rate is unchanged, one per interval — and takes the timer off the
keystroke somebody is waiting on. **19.72 ms p95 of round trip became 1.72.**

### What is left is the display, and the third run proves it

After the fix the round trip is under 2 ms everywhere, and the remainder is between the bytes
reaching the emulator and AppKit having drawn — which is one display frame. The echo column is what
makes this checkable, and across the two leading-edge runs it moves the *wrong* way for any
protocol-side explanation:

| | echo p50 | echo p95 | total p95 |
|---|---|---|---|
| external 100 Hz, AC | 0.92 ms | 1.72 ms | 11.54 ms |
| built-in ProMotion, battery | 0.64 ms | **0.78 ms** | **17.84 ms** |

The round trip got **faster** and the total got 6 ms **slower**. Whatever the second run is measuring
extra, it is not tetmux talking to tmux — it is the wait for a frame. tetmux is frame-bound here, and
that reframes what P6.1's 12 ms can mean:

* At **100 Hz** a frame is 10 ms, leaving about 2 ms of slack, and the measurement passes at 11.54.
* On the **built-in ProMotion panel** it fails at 17.84. ProMotion is adaptive and drops its refresh
  rate when content is static, which a terminal at a prompt is — a 17.8 ms p95 is one frame at
  ~60 Hz plus the draw, and at 16.7 ms per frame **no application can meet a 12 ms budget**.

**The two runs changed two variables at once** — display *and* power — so the split between them is
not established. The evidence points at the display (the protocol half improved on battery, and
16.7 ms is exactly a 60 Hz frame), but a run on the built-in panel while plugged in is what would
settle it, and it has not been done. Until it is, "P6.1 passes" is a claim about the 100 Hz external
monitor and nothing broader.

Two things the measurement still does not include, both of which make the real figure worse rather
than better. The interval closes when AppKit has drawn the view, **not** when the window server has
composited it or the display has scanned it out — unreachable from inside the process. And the
samples are synthetic keystrokes posted by `osascript`: they arrive as ordinary events but at
machine-perfect spacing, and a human types less evenly, which is the case that finds a tail.

## P6.3 — sustained `%output` throughput

**Floor:** ≥ 50 MB/s on one pane.
**Script:** `Scripts/measure-throughput.sh` (release build; `swift test` builds debug, which is a
different question — see below).
**Fixtures:** `Tests/tetmuxCoreTests/Fixtures/throughput-{text,escapes}.stream`, recorded by
`Scripts/capture-throughput.py` from tmux 3.7b.

This measures the **parser**, not the pipeline. `ControlCodec` is pure and touches every byte, so
what it costs here is what it costs in the app; the rest of the chain — pty read, delivery, the
emulator — needs a machine and a window server and is not this. Clearing the bar here is a
necessary condition, not the requirement met.

Two rates per run, because they answer different questions. **Wire** is what the parser consumed,
which is what a link delivers. **Pane** is what came out the other side, which is what P6.3 is a
promise about — always the smaller of the two once escaping is accounted for, and so the one the
floor is asserted against.

| Date | Machine | Workload | Pane | Wire |
|---|---|---|---|---|
| 2026-08-06 | Apple M3, macOS 26.5.1, Swift 6.3.3 | text | 339 MB/s | 382 MB/s |
| 2026-08-06 | Apple M3, macOS 26.5.1, Swift 6.3.3 | escapes | 327 MB/s | 416 MB/s |

**6.5× over the floor**, on the workload that has one escaped byte in eight and never takes
`unescapeOctal`'s fast path. P6.3's parser half is met with room.

### Debug is 17× slower, and that is why there are two floors

The same test in a debug build measures 17–19 MB/s pane — no optimisation, a retain/release around
every array, bounds checks on every subscript. `CodecThroughputTests` therefore asserts 50 MB/s only
when built release, and 5 MB/s in debug as an order-of-magnitude tripwire that survives a slow
runner. The debug number is not a performance figure and should not be recorded here as one.

| Configuration | text | escapes |
|---|---|---|
| release | 339 MB/s | 327 MB/s |
| debug | 19 MB/s | 17 MB/s |

### What the first run of this harness measured

23 MB/s wire, in **release** — half of P6.3's floor, which would have read as the requirement being
missed by 2×. It was the harness. The fixture was being sliced at its first `%output` so that the
repeated body carried no handshake, and `ControlCodec` skips everything before the first `%begin`
with a substring search that allocates at every position — a startup path the app runs a handful of
lines through, and this ran every line through it forever. Feeding the handshake once, then
repeating the output, moved the same bytes from 23 MB/s to 396.

Worth writing down for two reasons. A performance harness gets one thing badly wrong before it is
right, and the wrong answer looks exactly like a real finding — 23 MB/s was a plausible number
attached to a plausible story. And it is the standing argument for the fully-decoded assertion
beside the rate: a parser that is fast because it is dropping the payload measures wonderfully.

---

## P6.7 — cold launch to interactive

**Floor:** ≤ 400 ms.
**Script:** `Scripts/measure-launch.sh` (Instruments' App Launch template; the number is the end of
the **Initial Frame Rendering** phase, which is what "to interactive" means here — the local host
connecting and a pane filling with a shell prompt are several round trips further on).

| Date | Machine | Target | Mode | Runs | min | **median** | max |
|---|---|---|---|---|---|---|---|
| 2026-08-06 | Apple M3, macOS 26.5.1 | `.build/release/tetmux` | warm | 2 | 689.6 ms | **710.8 ms** | 732.0 ms |
| 2026-08-06 | Apple M3, macOS 26.5.1 | `.build/release/tetmux` | purged | 5 | 877.8 ms | **985.3 ms** | 1027.0 ms |

**Missed by 1.8× warm and 2.5× purged.** Warm means the frameworks were resident and dyld had a
launch closure for the binary; purged is after `sudo purge` has emptied the filesystem cache, which
is most of what "cold" means but leaves dyld's closure cache alone — so a true first-launch-after-
reboot is at or beyond the purged figure. The bare binary is also the faster target: the `.app`
launches through a different dyld path with a Gatekeeper assessment in front of it.

Where it goes, and the phase that moved is not the expected one:

| Phase | warm (median of 2) | purged (median of 5) |
|---|---|---|
| Launching — AppKit Scene Creation | 257 ms | **470.7 ms** |
| Initializing — Process Creation | 267 ms | 280.9 ms |
| Launching — applicationDidFinishLaunching() | 53 ms | 47.9 ms |
| Launching — applicationWillFinishLaunching() | 41 ms | 55.4 ms |
| Launching — Initial Frame Rendering | 31 ms | 28.5 ms |
| Initializing — System Interface Initialization | 17 ms | 17.6 ms |

**An empty page cache costs AppKit Scene Creation 210 ms and process creation 14.** That is
backwards from the obvious expectation — dyld mapping a framework graph is the part everyone assumes
a cold cache punishes — and it says the launch is not dominated by loading code. Something in scene
creation is reading from disk on first use. Which is worth knowing before anybody optimises: the
whole of what tetmux's own code does at launch (`applicationWillFinishLaunching` through
`didFinishLaunching`, where `bootstrap` reads the workspace and connects the local host) is about
100 ms warm and does not grow when the cache is emptied.

One caveat that cuts the right way for reading all of this: the App Launch template samples context
switches, so tracing is inside every number above. An untraced launch is faster. It is not 2.5×
faster.

## P6.6 — idle CPU, and P6.7 — resident memory

**Measured 2026-08-06**, on the arrangement P6.6 actually specifies: 20 panes across 4 real hosts,
every pane displayed, every shell at a prompt, each pane's scrollback filled by streaming 12 000
lines through the live channel (filling server-side first would not reach tetmux's emulator — a
reattach replays only a bounded `capture-pane`).

| Host | tmux | Panes |
|---|---|---|
| local (M3) | 3.7b | 5 |
| `server.example.org:2222` (Linux, WAN) | 3.5a | 5 |
| `vm.example.net` | 3.2a | 5 |
| `login.example.net` | 3.2a | 5 |

Panes were 55–112 columns × 10–12 rows, scrollback at the default 10 000 lines.

### P6.7 — memory: missed by 3.6×

| Arrangement | `phys_footprint` |
|---|---|
| 20 panes / 4 hosts | **547 MB** |
| 1 pane / 1 host | 72 MB |

**Against a 150 MB bound.** The differential is the useful part: 475 MB across 19 extra panes is
**~25 MB per pane**, at 10 000 lines of 55–112 columns. That is not a leak and not a surprise once
stated — it is the emulator's scrollback, which is what P6.7's own parenthesis asks to be measured —
but it means the requirement is arithmetically out of reach at the default: twenty panes cannot cost
under 150 MB while each costs 25. Either the per-cell footprint comes down or one of the two numbers
in P6.7 is wrong. `TODO.md` carries it.

### P6.6 — idle CPU: missed on battery, met on AC

| Condition | mean | median | max | |
|---|---|---|---|---|
| battery, 20 panes | **1.83%** | 0.30% | 13.9% | missed (bar is 0.5%) |
| AC, 20 panes | **0.48%** | 0.30% | 1.8% | inside the bar |
| AC, 1 pane | ~0.01% | 0.0% | 0.2% | |

P6.6 says verify **on battery**, so 1.83% is the number that answers it, and it is missed by ~3.7×.
Two caveats on that comparison, both of which want a cleaner rerun before anybody optimises against
it: the battery run was taken closer in time to the scrollback fill than the AC one, and `ps %cpu`
is a decaying average over about a minute, so residue is plausible. The AC/battery gap may also be
nothing but clock scaling — the same work on a slower core is a larger share of "one core".

**The shape is the finding, not the mean.** Idle baseline is ~0.25% in both conditions. The entire
miss is a spike **every 10 seconds**, reaching 13.9% on battery and 1.8% on AC.

Two things about that spike are measured, and the third is not. Measured: the **cadence** is 10 s,
which is `rttTask`'s — it sleeps 10 s and sends `display-message -p ''` per host, and it is the only
10 s timer in the application. Measured: the cost **scales with pane count**, since the single-pane
arm shows the same probe at the same cadence for ~0.01%.

Not measured: *why* work proportional to pane count happens when an RTT answer lands. The obvious
candidate is that `rttMilliseconds` is a field on `HostState`, so a probe answer diffs as a real
state change, broadcasts, and rebuilds a SwiftUI tree holding 20 panes — four `display-message`
round trips certainly cannot cost 13.9% of a core on their own. But an attempt to confirm that path
in an isolated harness was **inconclusive**: the harness ran the app against a scratch `HOME`, and
in that configuration it behaved anomalously in ways that did not reproduce in an ordinary run, so
nothing it showed about the broadcast path can be trusted. The mechanism is a hypothesis with the
cadence and the scaling behind it, and no more than that. Anybody acting on it should confirm it
first — on a normal run, with Instruments, not with a scratch `HOME`.

### Wakeups: fine, and worth saying so

`sudo powermetrics --samplers tasks`, three samples on battery:

| | sample 1 | sample 2 | sample 3 |
|---|---|---|---|
| CPU ms/s | 41.79 | 20.85 | 36.97 |
| User% | 95.39 | 94.35 | 95.27 |
| Intr wakeups/s | 44.69 | 44.57 | 44.79 |
| **Pkg idle wakeups/s** | **0.00** | **0.40** | **0.00** |

P6.6's note says sustained wakeups matter more than average CPU. They are not the problem here.
44.7 interrupt wakeups per second sounds like a lot, but the package idle exits — which is what
actually keeps a laptop awake — are ~0. And 95% user time says the cost is computation in the
application, not syscalls or I/O, which is the same finger the 10 s spike points at.
