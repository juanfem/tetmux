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

| Date | Machine | Display | Samples | p50 | **p95** | max |
|---|---|---|---|---|---|---|
| 2026-08-06 | Apple M3, macOS 26.5.1 | 3440×1440 @ 100 Hz | 38 | 13.50 ms | **24.43 ms** | 24.88 ms |

**Missed, by 2×.** And the split says where it goes:

| | p50 | p95 |
|---|---|---|
| keypress → echo (off-machine and back) | 9.76 ms | 19.72 ms |
| echo → glyph drawn (AppKit + SwiftTerm) | ~3.7 ms | ~4.7 ms |

The round trip is the whole problem, and **8 ms of it is a timer we set ourselves**.
`SessionService.sendKeys` starts a task that sleeps `keyFlushInterval` (8 ms) and *then* writes, so
a keystroke with nothing to coalesce with — which is every keystroke at typing speed — waits the
full interval before anything leaves the process. Measured p50 echo is 9.76 ms: 8 ms of sleep and
about 1.8 ms of real work, on a local session where tmux is on the same machine.

That is not an argument against coalescing. P6.4 asks for it and a paste or a held key needs it.
It is an argument about *which edge*: flushing the first keystroke immediately and coalescing
everything that arrives during the next 8 ms would leave the batching intact under load and take 8
ms off the isolated keystroke. `TODO.md` carries it as its own entry, with this measurement as the
evidence.

Two things this measurement does not include, both of which make the real figure worse rather than
better. The interval closes when AppKit has drawn the view, **not** when the window server has
composited it or the display has scanned it out — at 100 Hz that is up to another 10 ms, and it is
not reachable from inside the process. And the samples are synthetic keystrokes posted by
`osascript`, which arrive as ordinary events but at machine-perfect spacing; a human types less
evenly, which is the case that finds the tail.

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

## P6.6 and P6.7 — idle cost, memory, cold launch

**Not yet measured.** `Scripts/measure-idle.md` is the procedure — both requirements are claims
about 20 panes across 4 hosts, which is an arrangement that has to be built by hand on machines
somebody can actually reach, so there is nothing to record here until that has been done on real
hardware. The procedure names the two places where the obvious measurement is the wrong one
(`ps` RSS instead of `phys_footprint`, and average CPU instead of wakeups).
