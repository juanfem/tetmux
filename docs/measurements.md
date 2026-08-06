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
