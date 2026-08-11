# P6.6 and P6.7 — idle cost, memory, and launch

The two requirements no script can own end to end, and why: both are claims about a **loaded**
application — 20 panes across 4 hosts — and building that arrangement means four machines you can
reach and work worth having open in them. Neither can be conjured by a shell script without
measuring something else instead.

So this is a procedure rather than a program. Exact commands, exact numbers to write down, and the
two places where the obvious measurement is the wrong one.

    P6.6  Idle CPU with 20 panes across 4 hosts: < 0.5% of one core.
          Verify on battery — sustained wakeups matter more than average CPU.
    P6.7  Resident memory < 90 MB with one pane at default scrollback (10 000 lines/pane),
          and < 30 MB for each additional pane.
          Warm launch to interactive < 400 ms.

Both halves of P6.7 were **amended on 2026-08-06 against what this procedure measured**, and the
originals are worth knowing because they are what these steps were written for. Memory said
"< 150 MB with 20 panes at default scrollback", which contradicted its own parenthesis — a pane's
scrollback is ~25 MB at that depth, so twenty of them cannot fit in 150 MB and the sentence could
not hold both ways. Launch said *cold*; it now says warm, because cold is ~898 ms of which ~630 is an
empty page cache inside AppKit's framework first-use. Keep taking the cold number anyway (below):
it is unbounded, not uninteresting.

Results go in `docs/measurements.md`, with the machine beside them. See the head of that file for
why they are recordings rather than a pass mark.

---

## Setting up the load

Release build, always: a debug build is a different program for measurement purposes.

    swift build -c release --product tetmux
    .build/release/tetmux

Four hosts. Four *real* ones if you have them. Otherwise four ssh entries pointing at machines you
can reach — and if some of them are `localhost` under different names, **write that down**, because
a loopback ssh leg has no network stack worth the name and P6.6 is partly a claim about what an idle
ssh connection costs. Two remote and two local is a more honest hedge than four of either.

Twenty panes: five per host is the even split. Split a window with ⌥⌘D / ⌥⌘⇧D until each host's
session has five panes across two or three windows. Every pane must be **on screen at some point** —
a pane that has never been displayed has no `TerminalView` behind it and no subscription, so a
20-pane arrangement where 12 are in unselected tabs is a 20-pane arrangement for tmux and an 8-pane
one for this measurement. Unselected tabs are built and hidden with `.opacity(0)` rather than
dropped (see CLAUDE.md), so visiting each tab once is enough; they keep measuring afterwards.

Idle means idle: no pane running anything, every shell sitting at a prompt. `yes` in one pane makes
this measurement meaningless, which is the point of P6.5 and not of this.

---

## P6.6 — idle CPU

**On battery, unplugged.** macOS runs timers at a different coalescing policy on power, and P6.6 is
a claim about a laptop on a desk with the lid open.

Let it settle for two minutes after the last pane is opened — the topology refreshes, the first
`capture-pane` repaints and the discovery probes all fire early and then stop, and averaging them in
answers a question about connecting rather than about idling.

    pid=$(pgrep -x tetmux)
    # Mean CPU over 60 s, sampled every 2 s. `ps` reports a percentage of one core, which is the
    # unit P6.6 is written in.
    for i in $(seq 30); do ps -o %cpu= -p "$pid"; sleep 2; done \
        | awk '{ total += $1; n += 1 } END { printf "mean %.3f%% of one core over %d samples\n", total/n, n }'

**Record the series, not just the mean.** This was the difference between a number and an answer the
first time it was run: the mean was 1.83% against a 0.5% bar, and the series showed a flat 0.25%
baseline with a spike every fifth sample. A mean hides that; a spike every ten seconds names its own
cause. Keep the maximum too.

Note that `ps -o %cpu` is a **decaying average over about a minute**, not an instantaneous reading.
So the first samples after any burst of activity — the scrollback fill above, or an Instruments run
— still carry it, and a settle shorter than that window measures the setup rather than the idle.

**Then wakeups, which is the number P6.6 actually cares about.** A process can average almost no CPU
and still keep the package out of its idle states by waking every few milliseconds; that is what
drains a battery, and `ps` cannot see it.

    sudo powermetrics --samplers tasks -n 3 -i 5000 | grep -E "^tetmux|Name.*ID.*CPU"

The column to read is **Intr Wakeups** (interrupt-driven wakeups per second) and its idle-state
sibling. There is exactly one polling timer in the whole application — `MenuModifierMonitor.shared`,
at 20 Hz, and only between `NSMenu`'s begin- and end-tracking notifications, so with no menu open it
is not running. Anything above a handful of wakeups per second with every pane quiet is a finding: the
suspects are a `%output` nobody stopped, a reconnect backoff still ticking, or a SwiftUI view
rebuilding on a state broadcast that should not have been sent.

`powermetrics` needs `sudo` and there is no way around it — it reads counters the kernel does not
export to an unprivileged process.

---

## P6.7 — resident memory

    footprint -p "$(pgrep -x tetmux)"

`footprint` rather than Activity Monitor or `ps -o rss`: it reports **phys_footprint**, which is what
macOS itself uses to decide memory pressure and what the "Memory" column in Activity Monitor shows.
`ps`'s RSS counts shared pages — the whole of AppKit and Metal mapped into the process — and reports
a number that is both larger and not the one anybody is deciding anything with.

Write down the `phys_footprint` line. Two things to check before believing it:

* **Scrollback must be at its default** (10 000 lines/pane). It is a `UserDefaults` setting, so a
  machine where it has been raised for real work measures that instead. Settings → Terminal.
* **Fill the scrollback, and fill it through the live pane.** An empty pane's history costs
  nothing; P6.7 is a bound on 20 panes' worth of it, so the honest measurement has each pane
  holding real lines. Measuring 20 empty panes and writing the result in the "pass" column is the
  easiest wrong number to produce here — and it is what made the original 150 MB total look
  achievable.

  The fill has to happen **while the pane is on screen**. Sending it before tetmux attaches fills
  tmux's history and not the emulator's: a reattach replays a bounded `capture-pane`, so the pane
  comes back holding a couple of thousand lines however many were produced. And send more than the
  target — tmux's own `history-limit` defaults to 2000, so `capture-pane` will only ever show you
  2000 lines back and cannot confirm the emulator holds 10 000. What confirms it is the footprint.

## P6.7 — launch to interactive

Instruments has a template for exactly this and it is worth using rather than a stopwatch, because
"interactive" needs a definition and App Launch has one: first frame.

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcrun xctrace record --template 'App Launch' --launch -- .build/release/tetmux

Open the resulting `.trace`, and read the **App Launch** track's total to first frame. Record that.

**But do not quote it as the launch time.** Roughly a third of it is `xctrace` — `Process Creation`
measures ~290 ms for tetmux and 413 ms for Calculator, with no main-thread samples in it at all.
What the trace is for is *where* the time goes; `Scripts/measure-launch.sh --untraced` is what says
how much of it a user pays, and that is the number P6.7 is judged on.

Three things make the number mean what P6.7 means by it:

* **Warm is the bound; cold is the row beside it.** The second launch of anything is warm — the
  dynamic linker's caches, the page cache, the prewarming macOS does after the first run — and since
  the amendment that is what the 400 ms applies to, because it is what the user sees nearly every
  time. Take a cold one as well, from a reboot or with `Scripts/measure-launch.sh --purge`, and
  record it as its own row: nothing fails on it, but a cold figure drifting upward is still the
  earliest sign that something new is being touched before the first frame.
* **`.app` or binary, but say which.** `Scripts/package-dmg.sh` produces the bundle people actually
  double-click, and a bundled launch goes through Gatekeeper's assessment and a different dyld path
  than `.build/release/tetmux` does. They are two numbers, not one.
* **"Interactive" is the window, not the panes.** The local host connects itself at launch, and a
  pane with a shell prompt in it is several round trips past first frame — tmux has to start, the
  handshake has to complete, and a `capture-pane` has to come back. P6.7 is a bound on the
  application being on screen and answering, not on tmux being ready. Record the pane time
  separately if it is interesting; do not add it to the launch number.
