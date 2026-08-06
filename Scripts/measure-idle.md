# P6.6 and P6.7 — idle cost, memory, and cold launch

The two requirements no script can own end to end, and why: both are claims about a **loaded**
application — 20 panes across 4 hosts — and building that arrangement means four machines you can
reach and work worth having open in them. Neither can be conjured by a shell script without
measuring something else instead.

So this is a procedure rather than a program. Exact commands, exact numbers to write down, and the
two places where the obvious measurement is the wrong one.

    P6.6  Idle CPU with 20 panes across 4 hosts: < 0.5% of one core.
          Verify on battery — sustained wakeups matter more than average CPU.
    P6.7  Resident memory < 150 MB with 20 panes at default scrollback (10 000 lines/pane).
          Cold launch to interactive < 400 ms.

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

Record the mean. If it is near the bar, record the maximum too — a mean under 0.5% made of one busy
sample per minute is a different program from a flat one.

**Then wakeups, which is the number P6.6 actually cares about.** A process can average almost no CPU
and still keep the package out of its idle states by waking every few milliseconds; that is what
drains a battery, and `ps` cannot see it.

    sudo powermetrics --samplers tasks -n 3 -i 5000 | grep -E "^tetmux|Name.*ID.*CPU"

The column to read is **Intr Wakeups** (interrupt-driven wakeups per second) and its idle-state
sibling. There is exactly one polling timer in the whole application — `OptionKeyMonitor`, at 20 Hz,
and only between `NSMenu`'s begin- and end-tracking notifications, so with no menu open it is not
running. Anything above a handful of wakeups per second with every pane quiet is a finding: the
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
* **Fill the scrollback.** An empty pane's history costs nothing; P6.7 is a bound on 20 panes'
  worth of it, so the honest measurement has each pane holding real lines. `seq 1 20000` per pane,
  then let it settle, then measure. Measuring 20 empty panes and writing 150 MB in the "pass"
  column is the easiest wrong number to produce here.

## P6.7 — cold launch to interactive

Instruments has a template for exactly this and it is worth using rather than a stopwatch, because
"interactive" needs a definition and App Launch has one: first frame.

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcrun xctrace record --template 'App Launch' --launch -- .build/release/tetmux

Open the resulting `.trace`, and read the **App Launch** track's total to first frame. Record that.

Three things make the number mean what P6.7 means by it:

* **Cold.** The second launch of anything is warm — the dynamic linker's caches, the page cache, the
  prewarming macOS does after the first run. Reboot, or at least leave it alone for a while, and
  take the *first* launch. A warm launch is worth recording too, as a separate row; it is what the
  user sees most of the time.
* **`.app` or binary, but say which.** `Scripts/package-dmg.sh` produces the bundle people actually
  double-click, and a bundled launch goes through Gatekeeper's assessment and a different dyld path
  than `.build/release/tetmux` does. They are two numbers, not one.
* **"Interactive" is the window, not the panes.** The local host connects itself at launch, and a
  pane with a shell prompt in it is several round trips past first frame — tmux has to start, the
  handshake has to complete, and a `capture-pane` has to come back. P6.7 is a bound on the
  application being on screen and answering, not on tmux being ready. Record the pane time
  separately if it is interesting; do not add it to the launch number.
