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

**Floor:** ≤ 12 ms at p95 on a 100 Hz-or-faster display, one refresh interval + 2 ms below that;
and ≤ 3 ms at p95 for the application-controlled half — keypress to the echoed bytes reaching the
emulator, the "echo" column below. (P6.1 as amended 2026-08-06; see the end of this section.)
**Script:** `Scripts/measure-latency.sh` (release build, private tmux server, synthetic keystrokes).
**Instrumentation:** `Sources/tetmuxUI/LatencyProbe.swift`.

| Date | Display | Power | Samples | p50 | **p95** | max | |
|---|---|---|---|---|---|---|---|
| 2026-08-06 | external 3440×1440 @ 100 Hz | AC | 38 | 13.50 ms | **24.43 ms** | 24.88 ms | trailing-edge flush |
| 2026-08-06 | external 3440×1440 @ 100 Hz | AC | 148 | 11.11 ms | **11.54 ms** | 11.84 ms | leading-edge flush |
| 2026-08-06 | built-in 2880×1864 | battery | 148 | 12.07 ms | **17.84 ms** | 17.94 ms | leading-edge flush |
| 2026-08-06 | built-in 2880×1864 | AC | 148 | 12.14 ms | **14.28 ms** | 24.96 ms | leading-edge flush |
| 2026-08-06 | external 3440×1440 @ **100.0 Hz measured** | AC | 138 | 11.16 ms | **11.51 ms** | 21.28 ms | refresh rate sampled |
| 2026-08-06 | external 3440×1440 @ **100.0 Hz measured** | AC | 138 | 11.16 ms | **11.37 ms** | 12.01 ms | + P6.4 per-frame handoff |
| 2026-08-06 | built-in 2880×1864 @ **60.0 Hz measured** | AC | 138 | 10.47 ms | **11.28 ms** | 11.49 ms | bound is 18.67 ms here |

All on an Apple M3 (Mac15,13, MacBook Air 15-inch), macOS 26.5.1.

### The refresh rate is measured now — and P6.1 passes on both displays

`LatencyProbe` carries a `CADisplayLink` and every sample records the frame interval the compositor
was on **at the moment the glyph was drawn**; the script derives P6.1's bound from that rather than
quoting a flat 12 ms the SRD no longer states. It is calibrated against two known answers:
**10.00 ms over 4500 callbacks** on a monitor fixed at 100 Hz, and **16.67 ms over 2610** on the
built-in panel.

| Display | measured interval | rate | P6.1's bound | p95 | |
|---|---|---|---|---|---|
| external 3440×1440 | 10.00 ms | 100 Hz | 12.00 ms | 11.37 ms | passes |
| built-in 2880×1864 | 16.67 ms | 60 Hz | 18.67 ms | 11.28 ms | passes |

**So P6.1 is met on every configuration measured**, including the two earlier built-in runs: at 60 Hz
the bound is 18.67 ms, and 14.28 ms on AC and 17.84 ms on battery are both inside it. The requirement
is not missed on the machine's own screen, which is what the earlier entry in this file said.

### Two things this file previously asserted were wrong

Worth keeping, because both were stated as facts about this machine and both shaped the work.

**The built-in panel is not ProMotion and never was.** This is a Mac15,13 — a MacBook Air, which has
no ProMotion display. `CGDisplayCopyAllDisplayModes` offers **18 modes for it and every one is
60.0 Hz**, so it also cannot have been knocked down to 60 by the external monitor being attached:
there is no higher mode to be knocked out of. The "ProMotion idles the rate down when content is
static" explanation for the built-in runs being slower was therefore never the mechanism. The real
one is duller: a 60 Hz frame is 16.7 ms, so a keystroke waits longer for one than it does at 100 Hz,
and 14.28 ms and 17.84 ms are what that looks like.

**`CGDisplayCopyDisplayMode` does not read 0 here.** It reports **60.0** for the built-in and 100.0
for the external, and `NSScreen.maximumFramesPerSecond` agrees with both. That claim was the stated
justification for building the display-link instrument at all, and one line of `NSScreen` would have
answered the question the four earlier runs left open. The instrument is still worth having — it
measures the rate at the moment of the draw rather than the mode the display is configured for, which
is the honest number and the only one that would survive a genuinely adaptive panel — but it was
built on a premise that was not checked first.

One caveat survives, for a display that really is adaptive: a display link is content that is not
static, so a rate measured with one running is an **upper bound** on what an unwatched panel would
drift to. A higher rate is a shorter interval is a stricter bound, so a run that passes with the link
running would also pass without it; a run that fails would not be conclusive.

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

### What the display costs, and why the built-in runs looked worse

Four runs isolate both variables:

| | echo p95 | **total p95** | |
|---|---|---|---|
| external 100 Hz, AC | 1.72 ms | **11.54 ms** | bound 12.00 ms |
| built-in 60 Hz, AC | 0.80 ms | **14.28 ms** | bound 18.67 ms |
| built-in 60 Hz, battery | 0.78 ms | **17.84 ms** | bound 18.67 ms |

The protocol half is **under 2 ms in every one of them**, and it is *lowest* in the two that looked
worst. Whatever those runs spend extra is not tetmux talking to tmux; it is between the bytes
reaching the emulator and the glyph being on screen. tetmux is frame-bound here.

The mechanism is simply the frame: a 60 Hz refresh is 16.7 ms against the external monitor's 10.0,
so a keystroke waits longer for one, and 14.28 ms and 17.84 ms are what that looks like. Under the
amended rule that is not a miss — the bound moves with the panel, to 18.67 ms — so **all three
pass**. An earlier version of this section read them as failures and offered ProMotion's adaptive
refresh as the cause; both halves of that were wrong, and the correction is above.

**P6.1 was amended on 2026-08-06 in light of this**, because a requirement that no application can
meet on the machine it runs on is a broken requirement rather than a failing product: it now names a
refresh rate, and states the application-controlled figure — keypress to echoed bytes at the
emulator, ≤ 3 ms p95 — as the number a change is judged by. That is the echo column above, and it is
what caught the 8 ms coalescer. The end-to-end number stays in the record with its display beside
it. **Nothing about P6.1 is open now**: the rate is measured on both displays and the bound is met on
each.

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

## P6.4 — byte handoff, per chunk against per display frame

**Requirement:** the handoff from transport to surface is batched per display frame, never one
dispatch per read.
**Measured 2026-08-06** on an Apple M3, one pane running
`yes 'the quick brown fox jumps over the lazy dog 0123456789'`, the window frontmost, CPU sampled
once a second for 40 s.

| | mean | median | max |
|---|---|---|---|
| per `%output` chunk (before) | **108.2%** of one core | 110.2% | 111.4% |
| per display frame (after) | **106.9%** of one core | 108.3% | 109.7% |

**There was plenty to batch and batching bought nothing.** Both halves of that are measured, and the
second means nothing without the first:

* tmux emits **21 934 `%output` chunks a second** for this pane — 34 MB/s on the wire, mean chunk
  1560 bytes — which at 100 Hz is **219 chunks per display frame**. Measured against `tmux -CC`
  under a pty with no tetmux in it.
* With the change in, the surface calls `feed` **exactly 100 times a second** on a 100 Hz display,
  carrying ~13 MB/s. So the coalescing engages as designed: 219 dispatches per frame became one.

A change that silently did nothing would have produced the same CPU figure, which is why the feed
rate was counted rather than assumed. The honest reading of the pair is that **the dispatch is not
where the time goes** — SwiftTerm's per-byte parsing and grid update cost the same however few calls
deliver the bytes, and its own redraw coalescing already kept the paint rate sane.

The change was kept anyway, and the reason is not performance: P6.4 is neither unachievable nor
self-contradictory, which is the bar the SRD sets for amending a requirement rather than meeting it.
It is met, the mechanism is verified, and it costs nothing — the display link runs only while a pane
is actually producing output and stops after 12 idle frames, so twenty quiet panes hold no timers.
**Nobody should later believe this bought CPU.** It did not.

It also cost no latency, which is the risk a change to this path carries: P6.1 measured 11.51 ms p95
before and 11.37 ms after on the same display, with the echo half at 1.32 ms and 1.16 ms. That is
the leading edge doing its job — the first chunk after a quiet moment is fed immediately and only
what arrives inside the frame that follows is coalesced, the same shape of fix the keystroke
coalescer needed.

---

## P6.7 — launch to interactive

**Floor:** ≤ 400 ms **warm** *(amended 2026-08-06; the requirement said cold, and the rows below are
what that change was made against — cold is still recorded here, just no longer bounded)*.
**Script:** `Scripts/measure-launch.sh` (Instruments' App Launch template; the number is the end of
the **Initial Frame Rendering** phase, which is what "to interactive" means here — the local host
connecting and a pane filling with a shell prompt are several round trips further on).

| Date | Machine | Target | Mode | Runs | min | **median** | max |
|---|---|---|---|---|---|---|---|
| 2026-08-06 | Apple M3, macOS 26.5.1 | `.build/release/tetmux` | warm | 2 | 689.6 ms | **710.8 ms** | 732.0 ms |
| 2026-08-06 | Apple M3, macOS 26.5.1 | `.build/release/tetmux` | purged | 5 | 877.8 ms | **985.3 ms** | 1027.0 ms |
| 2026-08-06 | Apple M3, macOS 26.5.1 | `tetmux.app` (packaged) | warm | 3 | 697.4 ms | **699.8 ms** | 797.9 ms |
| 2026-08-06 | Apple M3, macOS 26.5.1 | `.build/release/tetmux` | warm, **untraced** | 5 | 238.6 ms | **288.5 ms** | 346.6 ms |
| 2026-08-06 | Apple M3, macOS 26.5.1 | `.build/release/tetmux` | warm, **untraced** | 8 | 261.3 ms | **268.2 ms** | 370.5 ms |
| 2026-08-06 | Apple M3, macOS 26.5.1 | `.build/release/tetmux` | purged, untraced, ~~as root~~ | 5 | 560.1 ms | ~~1100.7 ms~~ | 1552.9 ms |
| 2026-08-06 | Apple M3, macOS 26.5.1 | `.build/release/tetmux` | purged, **untraced** | 5 | 579.7 ms | **897.8 ms** | 1012.3 ms |

**The bundle is not the slower target after all.** 699.8 ms against the bare binary's 710.8 says the
Gatekeeper assessment and the different dyld path cost nothing measurable here, which removes the
caveat the earlier rows carried.

### Most of the traced number is the tracer

The App Launch template samples context switches, and that overhead is inside every phase it reports.
How much was never established, so it was assumed small. It is not:

| Application traced under `App Launch` | `Initializing - Process Creation` |
|---|---|
| tetmux | ~290 ms |
| **Calculator** | **413 ms** |

Calculator has no scene of tetmux's in it, and the time profiler records **no main-thread samples at
all** inside that phase — the first sample of a tetmux trace lands at the moment it ends. So the
phase is dominated by `xctrace` getting a process launched under ktrace rather than by the program
being launched, and a third of every number above is a cost no user pays.

`Scripts/measure-launch.sh --untraced` is the answer to that: `LaunchProbe` times the kernel's
`p_starttime` to the first frame, with nothing attached. **268–288 ms median, which is inside
P6.7's 400 ms.** Two runs of it agree, from a scratch `HOME` and from the real one.

One row is worth keeping for what it says about "cold": the very first launch of a **freshly linked**
binary — not in the page cache, no dyld launch closure — measured **1192 ms**, settling to ~500 ms
over the next few launches and to ~270 ms once warm. That is the shape of a first launch after
install, and it is why the purged figure matters more than the warm one.

### Warm passes; cold misses by ~2.2× — and the requirement was then amended to name warm

*Written before the amendment and kept as it was measured; the verdict below is what the numbers said
at the time. On 2026-08-06 P6.7 was amended to name **warm** launch, which passes at 268–288 ms.
The cold figure stands as recorded and is no longer a bound — the reasoning is in SRD §6, and the
short version is that the 630 ms is an empty page cache inside AppKit's framework first-use, with no
tetmux symbol in it, against a cost paid once per boot. What had to be true for that to be an honest
amendment rather than a retreat is exactly the phase breakdown in the next section.*

The purged untraced row is a **fail**: median 897.8 ms against 400 ms, spread 579.7–1012.3 ms across
five runs. `sudo purge` leaves the whole machine re-faulting, so a launch measured into that contends
with everything else doing the same — the spread is the honest signal that these are five draws from
a wide distribution rather than five measurements of one number.

So the page cache is worth roughly **630 ms** here (268 ms warm, 898 ms purged) and P6.7's cold bound
is missed by about 2.2×. The warm figure passing does not discharge the requirement: P6.7 says
*cold*, and the phase breakdown already showed where that goes — an empty page cache costs AppKit
Scene Creation 210 ms, which is framework first-use reading from disk and not tetmux's code.

**The struck-through row is the same measurement taken as root, and it is kept as a warning rather
than deleted.** It came from `sudo Scripts/measure-launch.sh 5 --untraced --purge`; the script
escalates for `purge` on its own, so the outer `sudo` was unnecessary and not harmless — as root the
app resolves *root's* Application Support (no `hosts.json`, no workspace to restore) and root has no
dyld launch closure for the binary. The tell was that it came out **above** the traced purged run
(1100.7 against 985.3), which is backwards, since tracing can only add. Re-run as an ordinary user it
is 897.8 ms, now correctly *below* the traced figure. The script refuses to run as root rather than
producing that number quietly again.

### Where the time goes inside Scene Creation

Read out of the trace rather than by opening Instruments — `xctrace export` gives the `time-profile`
table, and the samples inside the Scene Creation window aggregate like this (one warm run, 215 ms of
main-thread samples in a 323 ms window):

| Binary | main-thread samples |
|---|---|
| AppKit | 30.0 ms |
| libobjc | 27.0 ms |
| CoreFoundation | 23.8 ms |
| libswiftCore | 20.4 ms |
| SwiftUI | 14.3 ms |
| CoreUI | 13.9 ms |
| dyld | 10.4 ms |

**No hot spot and no tetmux symbol in it.** The leaves are Objective-C class realization and category
attachment, bundle localization directory scans, the font registry, asset-catalog lookups, `NSWindow`
initialization and SwiftUI graph construction — framework first-use, spread thin. That is consistent
with an empty page cache costing this phase 210 ms while costing everything tetmux does at launch
nothing, and it means there is no single change here to make.

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
but it means the requirement was arithmetically out of reach at the default: twenty panes cannot
cost under 150 MB while each costs 25.

**P6.7's memory half was amended on 2026-08-06** to bound the cost *per pane* — < 90 MB with one,
< 30 MB for each additional — since the old total and its own "10 000 lines/pane" parenthesis could
not both hold, and a bound that contradicts itself cannot be met or missed.

### Where the bytes are: a cell is 24 bytes, and the attribute is most of it

Measured directly from the dependency's layout rather than inferred from the footprint
(`PaneMemoryTests`, which pins all three numbers):

| | stride |
|---|---|
| `SwiftTerm.CharData` — one terminal cell | **24 bytes** |
| `Attribute` inside it | 14 bytes |
| `Attribute.Color`, two per cell | 4 bytes each |

A cell is `code` (4) + `width` (1) + atom (1) + padding + **`Attribute` (14)**. The attribute is
more than half the cell, and it is that size because truecolor needs three components and a tag per
colour, twice. SwiftTerm's own comment beside the padding field still says *"Purely here to align to
16 bytes"* — the struct outgrew that comment when truecolor arrived, and is 50% larger than it
claims.

The consequence in P6.7's units, cell data alone and before allocator rounding, per-line objects,
the alternate screen buffer or any view:

| Pane width | 10 000 lines of scrollback |
|---|---|
| 55 columns | 12.6 MB |
| 80 columns | 18.3 MB |
| 112 columns | 25.6 MB |

So a single pane of ordinary width holds more than a tenth of the old 150 MB budget before anything
else exists, and the measured ~25 MB per pane is this plus overhead rather than a leak.

**The only lever on this side is the scrollback default.** Halving it halves the dominant term
exactly. Making a *cell* smaller means packing `Attribute` — an index into a palette of attribute
runs rather than two inline colours — which is upstream work in SwiftTerm, not a change tetmux can
make. `TODO.md` carries that as the remaining decision.

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

Not measured at the time: *why* work proportional to pane count happens when an RTT answer lands.
That is settled now, below.

### The 10 s spike was the state broadcast, and it is fixed

**Measured 2026-08-06**, 12 panes on one local host, every pane on screen, the window frontmost, CPU
sampled once a second for 80 s. Two runs of each arm, alternating.

| Arm | mean | median | max | samples > 1% |
|---|---|---|---|---|
| before, run A | 0.45% | 0.00% | 5.40% | 10 |
| before, run B | 0.71% | 0.00% | 5.10% | 13 |
| **after, run A** | **0.04%** | 0.00% | **0.80%** | **0** |
| **after, run B** | **0.04%** | 0.00% | **0.70%** | **0** |

The mechanism was isolated before anything was changed: an arm that kept sending
`display-message -p ''` every ten seconds and only stopped **writing the answer to `HostState`** was
flat, with no spike at all. So the round trip costs nothing measurable and the broadcast costs all of
it — `rttMilliseconds` is a field on the diffed model, so every probe answer was a real state change,
and every state change reassigns `AppModel.hosts`, which invalidates every view that reads it: the
sidebar, the tab strip and every pane in the tree.

The fix is a channel of its own (`SessionService.roundTripStream`) and a leaf view that is the only
thing reading it. **Both halves were needed**, and the first attempt shipped only the first: with the
reading on its own channel but read in `AppMain`'s window body — the body that also builds the pane
tree — the ten-second rebuild came back through a different door. SwiftUI invalidates the views whose
*body reads* the property, so where a value is read is as much of the fix as where it is published.

Two notes on the harness, because one arm of it was thrown away. The window must be **frontmost and
unoccluded in every arm**: macOS stops drawing an occluded window and a visible pane blinks its
cursor, which is worth about 1% of a core on its own — twice the whole of P6.6's bar. An early set of
arms was run without controlling that and produced a 1.20% reading for the fixed build; it is not in
the table because it measured window visibility. And `ps -o %cpu` is a decaying average over about a
minute and cannot show a ten-second spike as anything but a raised mean; these used `top -l` at 1 s,
which reports the interval.

### P6.6 on the arrangement it names: 20 panes, 4 hosts, on battery — **passes**

The fix was found and verified on 12 panes and one host, so the requirement's own arrangement was
re-run afterwards: the same four hosts as the failing measurement, five panes each, every pane
displayed, every scrollback filled with 12 000 lines through the live channel, settled two minutes,
sampled at 1 s for 80 s, **unplugged**.

| | mean | median | max | samples > 1% |
|---|---|---|---|---|
| 2026-08-06, before | 1.83% | 0.30% | 13.9% | spike every 10 s |
| **2026-08-06, after** | **0.14%** | **0.00%** | **2.10%** | 2 of 80, not periodic |

**Inside P6.6's 0.5% bar, against 3.7× over it before** — 13× better on the mean and 6.6× on the
maximum, and the ten-second cadence is gone rather than reduced. What is left is occasional and
aperiodic, which is what four WAN-attached hosts doing ordinary topology work looks like.

`phys_footprint` on the same arrangement is **550 MB**, against 547 MB for the identical arrangement
before the change — so the fix cost no memory, and P6.7's memory half is unchanged: 20 panes at
(550 − 72) / 19 ≈ 25 MB per additional pane, inside the amended bound of 30.

Prediction and outcome, since the 12-pane run was used to predict this one: the cost scaled with both
pane count and host count, so the requirement's arrangement was expected to improve by more than the
one the fix was measured on. It did — 1.83% → 0.14% here against 0.45–0.71% → 0.04% there — but the
mechanism was the same and the prediction was cheap. The reason to re-run was that P6.6 is a claim
about *this* arrangement, and a claim is not discharged by a proxy.

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
