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

| Date | Machine | Display | Samples | p50 | **p95** | max | |
|---|---|---|---|---|---|---|---|
| 2026-08-06 | Apple M3, macOS 26.5.1 | 3440×1440 @ 100 Hz | 38 | 13.50 ms | **24.43 ms** | 24.88 ms | trailing-edge flush |
| 2026-08-06 | Apple M3, macOS 26.5.1 | 3440×1440 @ 100 Hz | 148 | 11.11 ms | **11.54 ms** | 11.84 ms | leading-edge flush |

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

### What is left is the display, and it is most of the budget now

After the fix the round trip is under 2 ms and the remaining ~10 ms is between the bytes reaching
the emulator and AppKit having drawn — which at 100 Hz is one frame. tetmux is frame-bound here, not
protocol-bound, and that reframes P6.1's 12 ms:

* At **100 Hz** a frame is 10 ms, leaving about 2 ms of slack. The measured p95 of 11.54 ms fits,
  but not with room to spare — a p95 that drifts past 12 on this hardware is a frame being missed,
  not the protocol slowing down, and the echo column is how to tell.
* At **60 Hz** a frame is 16.7 ms and P6.1 cannot be met by *any* application, this one included.
  A future run on a 60 Hz panel that reports ~18 ms is not a regression. This is why the display is
  recorded beside the machine.

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

**Missed by 1.8×, and that is the favourable case.** Warm means the frameworks were already resident
and dyld had a launch closure; a genuinely cold launch is slower. The bare binary is also the faster
target — the `.app` goes through a different dyld path with a Gatekeeper assessment in front of it.

Where it goes, per run:

| Phase | run 1 | run 2 |
|---|---|---|
| Initializing — Process Creation | 272.90 ms | 261.37 ms |
| Launching — AppKit Scene Creation | 237.79 ms | 276.78 ms |
| Launching — applicationDidFinishLaunching() | 49.19 ms | 56.35 ms |
| Launching — applicationWillFinishLaunching() | 43.96 ms | 38.62 ms |
| Launching — Initial Frame Rendering | 30.99 ms | 30.33 ms |
| Initializing — System Interface Initialization | 18.90 ms | 16.19 ms |
| remainder (runtime init, AppKit init, first scene) | ~3.8 ms | ~3.6 ms |

Two terms are three quarters of it and neither is in tetmux's own code: **process creation** — dyld
mapping the framework graph, which includes SwiftTerm, AppKit and Metal — and **AppKit Scene
Creation**, which is SwiftUI building the scene. Everything the application itself does at launch
(`applicationWillFinishLaunching` through `didFinishLaunching`, which is where `bootstrap` reads the
workspace and connects the local host) is under 100 ms combined.

One caveat that cuts the right way for reading this: the App Launch template samples context
switches, so tracing is inside every number above. An untraced launch is faster than 711 ms. It is
not 1.8× faster.

## P6.6 and P6.7 — idle cost and memory

**Not yet measured.** `Scripts/measure-idle.md` is the procedure — both are claims about 20 panes
across 4 hosts, which has to be built on machines somebody can actually reach. The procedure names
the two places where the obvious measurement is the wrong one (`ps` RSS instead of `phys_footprint`,
and average CPU instead of wakeups).
