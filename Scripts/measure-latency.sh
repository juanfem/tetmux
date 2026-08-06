#!/usr/bin/env bash
# P6.1 — keypress → glyph on a local session, at p95. The floor is 12 ms.
#
#     Scripts/measure-latency.sh            # 120 keystrokes
#     Scripts/measure-latency.sh 400        # more, for a tighter p95
#
# Local and by hand (§6, §8). It builds release — a debug build measures a binary nobody runs —
# launches tetmux, types at it, and reads back the intervals the app timed between the `NSEvent`
# arriving and the pane drawing the echoed glyph. `Sources/tetmuxUI/LatencyProbe.swift` is where
# those three points are and why they are there.
#
# **It needs Accessibility permission**, for whichever terminal you run it from: posting a keystroke
# to another application is what that permission is for. macOS will ask on the first run, and if it
# is refused the keystrokes go nowhere with no error — so this sends a few warm-up keys first and
# stops with a diagnosis if nothing comes back, rather than reporting a confident p95 over zero
# samples.
#
# **It touches nothing of yours.** The app runs with `HOME` and `TMUX_TMPDIR` pointed at a scratch
# directory, so it gets a private tmux server, an empty host list and its own workspace file: the
# keystrokes land in a throwaway shell, and your real session, window arrangement and saved hosts
# are not opened, typed into or rewritten. The scratch directory goes at the end.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SAMPLES="${1:-120}"
# Typed slower than the round trip, deliberately. Two keystrokes in flight are two intervals whose
# ends cannot be told apart, and the probe abandons the first rather than mismeasure it — so a
# faster loop would not produce more samples, only fewer and a `LATENCY-DROP` for each. This is also
# roughly a fast typist, which is the case P6.1 is about.
INTERVAL=0.15
# Dropped before the statistics: the first keystrokes pay for a cold path — first draw of that pane,
# first trip through code nothing has run yet — and P6.1 is a claim about typing, not about the
# first character after launch.
WARMUP=5

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

scratch=$(mktemp -d /tmp/tetmux-latency.XXXXXX)
app_pid=""
cleanup() {
    [[ -n "$app_pid" ]] && kill "$app_pid" 2>/dev/null || true
    # The private server too: the app's own teardown does not run when it is killed, and a stray
    # tmux against a socket in a directory about to be deleted is a process nobody will notice.
    TMUX_TMPDIR="$scratch/tmux" tmux kill-server 2>/dev/null || true
    rm -rf "$scratch"
}
trap cleanup EXIT

mkdir -p "$scratch/tmux"
log="$scratch/samples.txt"

echo "== hardware"
sysctl -n machdep.cpu.brand_string 2>/dev/null || true
sw_vers -productVersion | sed 's/^/macOS /'
# The display is half the answer at this scale: 8.3 ms of a 12 ms budget is one frame at 120 Hz and
# two at 60. A p95 that misses on an external 60 Hz panel and passes on the built-in display is not
# a contradiction, so the panel goes in the record beside the number.
system_profiler SPDisplaysDataType 2>/dev/null \
    | awk -F': ' '/Resolution|UI Looks like/ { gsub(/^ +/, "", $2); print "display " $2 }' | head -4
echo

echo "== building release"
swift build -c release --product tetmux >/dev/null

echo "== launching against a private tmux server in $scratch"
HOME="$scratch" \
TMUX_TMPDIR="$scratch/tmux" \
TETMUX_MEASURE_LATENCY=1 \
    .build/release/tetmux >"$log" 2>&1 &
app_pid=$!

# The local host connects itself at launch (it is always reachable and cannot prompt), then a
# session has to be created, a window laid out and a pane focused — a couple of round trips through
# a server that is starting cold.
sleep 6
if ! kill -0 "$app_pid" 2>/dev/null; then
    echo "FAILED: tetmux exited during launch" >&2
    cat "$log" >&2
    exit 1
fi

osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $app_pid) to true" \
    >/dev/null 2>&1 || true
sleep 1

type_keys() {
    local count=$1
    for ((i = 0; i < count; i++)); do
        # One character, no Return: the pane's shell accumulates a line of `a`s and runs nothing.
        osascript -e 'tell application "System Events" to keystroke "a"' >/dev/null 2>&1 || true
        sleep "$INTERVAL"
    done
}

echo "== warm-up"
type_keys 3
sleep 1
if ! grep -q '^LATENCY ' "$log"; then
    echo >&2
    echo "FAILED: the app recorded no keystroke at all." >&2
    echo >&2
    echo "  Most likely this terminal does not have Accessibility permission, which is what" >&2
    echo "  posting a keystroke to another application requires. System Settings > Privacy &" >&2
    echo "  Security > Accessibility, add the terminal you are running this from, and try again." >&2
    echo >&2
    echo "  Otherwise: no pane had keyboard focus, or the local tmux server did not come up." >&2
    echo "  The app's output is in $log — it is copied below before this directory goes." >&2
    echo >&2
    sed -n '1,40p' "$log" >&2
    exit 1
fi

echo "== typing $SAMPLES keystrokes at ${INTERVAL}s"
type_keys "$SAMPLES"
sleep 1

echo
echo "== P6.1"
python3 - "$log" "$WARMUP" <<'PY'
import sys

log, warmup = sys.argv[1], int(sys.argv[2])
total, echo, drops = [], [], 0
for line in open(log, errors="replace"):
    if line.startswith("LATENCY-DROP"):
        drops += 1
    elif line.startswith("LATENCY "):
        _, t, e = line.split()
        total.append(float(t))
        echo.append(float(e))

total, echo = total[warmup:], echo[warmup:]
if len(total) < 20:
    print(f"FAILED: {len(total)} samples after discarding {warmup} warm-up — too few to quote a p95",
          file=sys.stderr)
    sys.exit(1)


def pct(values, p):
    # Nearest-rank. No interpolation: with a hundred-odd samples an interpolated p95 invents a
    # number between two real ones, and every sample here is a real keystroke.
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(p / 100 * len(ordered) + 0.5)) - 1)]


print(f"samples        {len(total)} (+{warmup} warm-up discarded, {drops} overlapped and dropped)")
print(f"keypress→glyph p50 {pct(total, 50):6.2f} ms   p95 {pct(total, 95):6.2f} ms   max {max(total):6.2f} ms")
print(f"  of which echo p50 {pct(echo, 50):6.2f} ms   p95 {pct(echo, 95):6.2f} ms   max {max(echo):6.2f} ms")
print()
p95 = pct(total, 95)
if p95 <= 12:
    print(f"PASS: p95 {p95:.2f} ms is within P6.1's 12 ms")
else:
    print(f"FAIL: p95 {p95:.2f} ms exceeds P6.1's 12 ms")
print()
print("Record the above in docs/measurements.md, with the machine and the display.")
sys.exit(0 if p95 <= 12 else 1)
PY
