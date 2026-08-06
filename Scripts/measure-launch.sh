#!/usr/bin/env bash
# P6.7's second half — cold launch to interactive. The floor is 400 ms.
#
#     Scripts/measure-launch.sh                    # 3 warm launches of the release binary
#     Scripts/measure-launch.sh 5 --purge          # 5, each preceded by `sudo purge`
#     Scripts/measure-launch.sh 3 --app dist/tetmux.app
#
# Instruments' App Launch template rather than a stopwatch, because "interactive" needs a definition
# and this one has it: the instrument breaks the launch into phases and the last of them is
# **Initial Frame Rendering**. First frame is where the number is taken, which is also where P6.7's
# "to interactive" stops — the local host connecting and a pane filling with a shell prompt are
# several round trips further on and are not what this bounds.
#
# **Warm by default, and that is not the requirement.** The first launch after a reboot is the one
# P6.7 is about: nothing in the page cache, no dyld launch closure for this binary, no prewarming.
# `--purge` is the closest approximation without rebooting — `sudo purge` empties the filesystem
# cache, which is most of the difference, though it leaves dyld's closure cache alone. Record which
# mode produced a number; a warm launch quoted as a cold one is the easiest wrong row in the table.
#
# **The bundle and the bare binary are two different numbers.** `--app` points at a built
# `tetmux.app` (`Scripts/package-dmg.sh`, then mount the image and copy it out): that is what
# somebody double-clicks, and it launches through a different dyld path with a Gatekeeper assessment
# in front of it. Without `--app` this measures `.build/release/tetmux`, which is the faster case.
#
# **Tracing is inside every number this produces, and it is not a rounding error.** The App Launch
# template samples context switches, and measured against a control it costs more than the phase
# breakdown makes it look: under this harness `Initializing - Process Creation` is ~290 ms for tetmux
# and **413 ms for Calculator**, an application with no scene of ours in it — so that phase is mostly
# `xctrace` getting a process launched under ktrace rather than the program being launched. What the
# trace is *for* is where the time goes, and it answered that: the cost is in AppKit Scene Creation,
# diffuse across framework first-use, with no tetmux symbol in it.
#
#     Scripts/measure-launch.sh 5 --untraced       # no Instruments; the app times itself
#
# `--untraced` is the number a user would actually experience: `LaunchProbe` reports `exec` (the
# kernel's `p_starttime`) to the first frame, with no tracer in the process at all. It has no phase
# breakdown — that is the trade, and it is why both modes exist rather than one replacing the other.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# `--purge` escalates on its own, one `sudo purge` per run, so this script must **not** be run under
# `sudo` itself — and refusing is worth more than a warning, because what it produces is a plausible
# number measuring something else. As root the app resolves *root's* Application Support (see the
# `HOME` note above: that path comes from the password database and ignores the environment), so it
# launches with no `hosts.json` and no workspace to restore, and root has no dyld launch closure for
# the binary. Both make the figure incomparable with every other row in the table. It happened:
# `sudo Scripts/measure-launch.sh 5 --untraced --purge` returned a median of 1100.7 ms against
# 985.3 ms for the *traced* purged run, which is backwards and was the clue.
if [[ "$(id -u)" -eq 0 ]]; then
    echo "Run this as yourself, not under sudo — it escalates for 'purge' on its own." >&2
    echo "As root the app reads root's Application Support and gets no launch closure, so the" >&2
    echo "number is not comparable with anything else in docs/measurements.md." >&2
    exit 2
fi

RUNS=3
PURGE=0
APP=""
UNTRACED=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge) PURGE=1; shift ;;
        --app) APP="$2"; shift 2 ;;
        --untraced) UNTRACED=1; shift ;;
        [0-9]*) RUNS="$1"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

scratch=$(mktemp -d /tmp/tetmux-launch.XXXXXX)
# `HOME` does not isolate `~/Library/Application Support/tetmux`: `FileManager`'s
# `.applicationSupportDirectory` resolves the real home from the password database and ignores the
# environment, so the app reads and rewrites the real `workspace.json` whatever `HOME` says. Saved
# and restored, because a measurement must not cost somebody their window arrangement.
state="$HOME/Library/Application Support/tetmux/workspace.json"
[[ -f "$state" ]] && cp "$state" "$scratch/workspace.json.saved"
cleanup() {
    pkill -f "$target" 2>/dev/null || true
    TMUX_TMPDIR="$scratch/tmux" tmux kill-server 2>/dev/null || true
    if [[ -f "$scratch/workspace.json.saved" ]]; then
        cp "$scratch/workspace.json.saved" "$state" 2>/dev/null || true
    fi
    rm -rf "$scratch"
}

if [[ -n "$APP" ]]; then
    target="$APP/Contents/MacOS/tetmux"
    [[ -x "$target" ]] || { echo "no executable at $target" >&2; exit 1; }
    what="$APP"
else
    echo "== building release"
    swift build -c release --product tetmux >/dev/null
    target="$PWD/.build/release/tetmux"
    what="$target (bare binary — see the header for why the .app is a different number)"
fi
trap cleanup EXIT

# The same isolation the other measurement scripts use: a private tmux server, an empty host list
# and a workspace file of its own, so a launch measurement does not open somebody's real session or
# rewrite their window arrangement. `.ssh` is linked through because the app resolves ssh config at
# launch and an absent one is a different launch.
mkdir -p "$scratch/home/tmux"
ln -s "$HOME/.ssh" "$scratch/home/.ssh" 2>/dev/null || true

echo "== hardware"
sysctl -n machdep.cpu.brand_string 2>/dev/null || true
sw_vers -productVersion | sed 's/^/macOS /'
echo "target   $what"
echo "mode     $([[ $PURGE -eq 1 ]] && echo 'purged (approximating cold)' || echo 'warm')$([[ $UNTRACED -eq 1 ]] && echo ', untraced')"
echo

if [[ $UNTRACED -eq 1 ]]; then
    for ((run = 1; run <= RUNS; run++)); do
        if [[ $PURGE -eq 1 ]]; then sudo purge; sleep 5; fi
        HOME="$scratch/home" TMUX_TMPDIR="$scratch/home/tmux" TETMUX_MEASURE_LAUNCH=1 \
            "$target" >"$scratch/run-$run.log" 2>&1 &
        launched=$!
        # Long enough for the window to be on screen and the probe to have drawn; the app is killed
        # rather than quit, because `applicationShouldTerminate` waits on a round trip per host and
        # that is not part of what is being measured.
        sleep 5
        kill "$launched" 2>/dev/null || true
        wait "$launched" 2>/dev/null || true
        if ! grep -qE '^LAUNCH ' "$scratch/run-$run.log"; then
            echo "FAILED: run $run reported no first frame" >&2
            sed -n '1,20p' "$scratch/run-$run.log" >&2
            exit 1
        fi
        awk '/^LAUNCH /{ printf "run '"$run"': %7.1f ms to first frame\nTOTAL %s\n", $2, $2 }' \
            "$scratch/run-$run.log"
    done | tee "$scratch/report.txt"
else

for ((run = 1; run <= RUNS; run++)); do
    if [[ $PURGE -eq 1 ]]; then
        # Before the launch, not after: the point is that the binary and its frameworks are not in
        # the cache when dyld goes looking for them.
        sudo purge
        # `purge` returns before the system has settled — everything else on the machine is also
        # re-faulting its pages, and a launch measured into that contends with it.
        sleep 5
    fi

    trace="$scratch/run-$run.trace"
    # `|| true`, and then the artefact is checked instead: `xctrace record` exits **54 on a
    # perfectly good recording** that ended by hitting its time limit, which is every recording this
    # script makes. Treating its status as the answer aborts the script on success — which it did,
    # silently, because the status was the only thing being read.
    xcrun xctrace record \
        --template 'App Launch' \
        --time-limit 12s \
        --no-prompt \
        --output "$trace" \
        --env HOME="$scratch/home" \
        --env TMUX_TMPDIR="$scratch/home/tmux" \
        --launch -- "$target" >"$scratch/xctrace-$run.log" 2>&1 || true

    pkill -f "$target" 2>/dev/null || true

    if [[ ! -e "$trace" ]]; then
        echo "FAILED: run $run produced no trace" >&2
        cat "$scratch/xctrace-$run.log" >&2
        exit 1
    fi

    xcrun xctrace export --input "$trace" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="life-cycle-period"]' \
        > "$scratch/run-$run.xml" 2>/dev/null

    python3 - "$scratch/run-$run.xml" "$run" <<'PY'
import sys, xml.etree.ElementTree as ET

path, run = sys.argv[1], sys.argv[2]
root = ET.parse(path).getroot()

# Values appear once and are referenced by id afterwards, so every row has to be resolved against
# what came before it. Reading a row in isolation gets `<duration ref="4"/>` and no number.
seen = {}


def value(node):
    ref = node.get("ref")
    if ref is not None:
        return seen.get(ref)
    # The period is carried in the attribute; times are the element's text.
    resolved = node.get("fmt") if node.tag == "app-period" else node.text
    node_id = node.get("id")
    if node_id:
        seen[node_id] = resolved
    return resolved


phases = []
for row in root.iter("row"):
    cells = list(row)
    # Schema column order: start, group, layout-id, duration, process, period, narrative.
    start = value(cells[0])
    duration = value(cells[3])
    period = value(cells[5])
    if start is None or duration is None or period is None:
        continue
    phases.append((period, int(start) / 1e6, int(duration) / 1e6))

if not phases:
    print(f"run {run}: FAILED — the trace carried no launch phases", file=sys.stderr)
    sys.exit(1)

frame = [p for p in phases if "Initial Frame Rendering" in p[0]]
if not frame:
    print(f"run {run}: FAILED — no Initial Frame Rendering phase; the app may not have shown a window",
          file=sys.stderr)
    sys.exit(1)

period, start, duration = frame[-1]
total = start + duration
print(f"run {run}: {total:7.1f} ms to first frame")
for period, start, duration in phases:
    if period.startswith("Foreground"):
        continue
    print(f"           {duration:8.2f} ms  {period}")
print(f"TOTAL {total:.1f}")
PY
done | tee "$scratch/report.txt"
fi

echo
echo "== P6.7 (launch)"
python3 - "$scratch/report.txt" <<'PY'
import sys, statistics

totals = [float(line.split()[1]) for line in open(sys.argv[1]) if line.startswith("TOTAL ")]
if not totals:
    print("FAILED: no run produced a number", file=sys.stderr)
    sys.exit(1)

median = statistics.median(totals)
print(f"runs {len(totals)}   min {min(totals):.1f} ms   median {median:.1f} ms   max {max(totals):.1f} ms")
print()
if median <= 400:
    print(f"PASS: median {median:.1f} ms is within P6.7's 400 ms")
else:
    print(f"FAIL: median {median:.1f} ms exceeds P6.7's 400 ms")
print()
print("Record the above in docs/measurements.md, with the machine, the mode and the target.")
sys.exit(0 if median <= 400 else 1)
PY
