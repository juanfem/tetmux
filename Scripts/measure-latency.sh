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
# **The tmux side is isolated; the app's state files are not, so they are saved and put back.**
# `TMUX_TMPDIR` gives the run a private tmux server, so the keystrokes land in a throwaway shell and
# your real session is never typed into. `HOME` does **not** do the equivalent for
# `~/Library/Application Support/tetmux`: `FileManager.urls(for: .applicationSupportDirectory, …)`
# resolves the real home from the password database and ignores the environment, so the app reads
# and rewrites your actual `workspace.json` whatever `HOME` says. This was discovered the hard way —
# an earlier version of this comment claimed isolation it did not have, and measurement runs
# overwrote a real window arrangement while asserting they could not. So the file is copied aside
# before the run and restored after, including when the run fails.

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
# The one piece of real state this cannot keep the app away from. See the header.
state="$HOME/Library/Application Support/tetmux/workspace.json"
[[ -f "$state" ]] && cp "$state" "$scratch/workspace.json.saved"
cleanup() {
    [[ -n "$app_pid" ]] && kill "$app_pid" 2>/dev/null || true
    # The private server too: the app's own teardown does not run when it is killed, and a stray
    # tmux against a socket in a directory about to be deleted is a process nobody will notice.
    TMUX_TMPDIR="$scratch/tmux" tmux kill-server 2>/dev/null || true
    # Put the window arrangement back before the scratch goes. A measurement must not cost somebody
    # their workspace, and the app has been writing to the real one throughout.
    if [[ -f "$scratch/workspace.json.saved" ]]; then
        cp "$scratch/workspace.json.saved" "$state" 2>/dev/null || true
    fi
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

# Focus the window that has a *pane* in it, which is not reliably the frontmost one.
#
# The app discovers hosts from `~/.ssh/config` (F4.2), which is symlinked into the scratch home so
# ssh keys still work — so a machine with saved hosts launches with a window per host, and the one
# in front may be an unconnected host showing a Connect placeholder. That window has no terminal
# view, so nothing takes the keystrokes and the run records zero samples while every check above
# still passes: the app is up, it is frontmost, and `osascript` reports no error because posting the
# key succeeded. Only the *local* host is connected at this point, so its window is the target, and
# it is found by title rather than by position.
window=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $app_pid) to get {position, size} of (first window whose name contains \"localhost\")" 2>/dev/null || true)
if [[ -z "$window" ]]; then
    echo "FAILED: no window for the local host — it may not have connected" >&2
    sed -n '1,40p' "$log" >&2
    exit 1
fi
wx=$(echo "$window" | cut -d, -f1 | tr -d ' ')
wy=$(echo "$window" | cut -d, -f2 | tr -d ' ')
ww=$(echo "$window" | cut -d, -f3 | tr -d ' ')
wh=$(echo "$window" | cut -d, -f4 | tr -d ' ')
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $app_pid) to perform action \"AXRaise\" of (first window whose name contains \"localhost\")" >/dev/null 2>&1 || true
sleep 1
# The click is what makes the pane first responder; raising alone leaves the keyboard elsewhere.
osascript -e "tell application \"System Events\" to click at {$((wx + ww / 2)), $((wy + wh / 2))}" >/dev/null 2>&1 || true
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
total, echo, frame, drops = [], [], [], 0
# Once-a-second summaries from the display link: ticks, mean nominal frame duration, mean measured
# interval between callbacks. Kept whole rather than averaged, because an adaptive panel changing
# rate mid-run is exactly what a single average would hide.
windows = []
for line in open(log, errors="replace"):
    if line.startswith("LATENCY-DROP"):
        drops += 1
    elif line.startswith("LATENCY "):
        _, t, e, f = line.split()
        total.append(float(t))
        echo.append(float(e))
        frame.append(float(f))
    elif line.startswith("FRAME "):
        _, ticks, nominal, measured = line.split()
        windows.append((int(ticks), float(nominal), float(measured)))

total, echo, frame = total[warmup:], echo[warmup:], frame[warmup:]
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

# The panel's rate, taken from the compositor at the moment each glyph was drawn rather than from
# `CGDisplayCopyDisplayMode`, which answers what the display is *configured* for rather than what it
# was on when the glyph landed. This is what chooses the bound below.
interval = pct(frame, 50) if frame and max(frame) > 0 else 0
if interval > 0:
    rates = sorted({round(1000 / n, 1) for _, n, _ in windows if n > 0})
    drift = f"   rates seen {rates}" if len(rates) > 1 else ""
    print(f"frame interval p50 {interval:6.2f} ms   = {1000 / interval:.1f} Hz at the draw{drift}")
    measured = sum(t * m for t, _, m in windows) / sum(t for t, _, _ in windows) if windows else 0
    if measured:
        print(f"  callbacks arrived every {measured:.2f} ms over {sum(t for t, _, _ in windows)} of them")
print()

# P6.1 as amended 2026-08-06: 12 ms at p95 on a 100 Hz-or-faster display, one refresh interval + 2 ms
# below that. A flat 12 ms is not the requirement and quoting it as one is what made the first four
# runs unable to say whether they had passed.
p95 = pct(total, 95)
if interval <= 0:
    bound, basis = 12.0, "P6.1's 12 ms (no frame interval sampled — assuming ≥ 100 Hz)"
elif interval <= 10:
    bound, basis = 12.0, f"P6.1's 12 ms at {1000 / interval:.0f} Hz"
else:
    bound = interval + 2
    basis = f"P6.1's one refresh interval + 2 ms at {1000 / interval:.0f} Hz"
print(f"{'PASS' if p95 <= bound else 'FAIL'}: p95 {p95:.2f} ms against {bound:.2f} ms — {basis}")

# The application-controlled half, which is the number a change is judged by (P6.1 as amended). The
# end-to-end figure above is a claim about a display as much as about this program; this one is not.
echo95 = pct(echo, 95)
print(f"{'PASS' if echo95 <= 3 else 'FAIL'}: keypress→echo p95 {echo95:.2f} ms against P6.1's 3 ms")
print()
print("Record the above in docs/measurements.md, with the machine, the display and the rate.")
sys.exit(0 if p95 <= bound and echo95 <= 3 else 1)
PY
