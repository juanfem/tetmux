#!/usr/bin/env bash
# P6.3 — sustained `%output` throughput, measured on the parser.
#
# `swift test` builds debug, and a debug build of this codec runs 17× slower than the one that
# ships: no optimisation, a retain/release around every array, bounds checks on every subscript.
# Measuring that would answer a question nobody asked. So this runs the same test in **release**,
# which is the only configuration whose number means anything against P6.3's 50 MB/s.
#
#     Scripts/measure-throughput.sh
#
# Local and by hand, per §6's closing note and §8: a hosted runner measures the runner. The debug
# floor inside the test is a tripwire for CI, not this. Write what this prints into
# docs/measurements.md with the machine it came from — a rate with no hardware beside it is not a
# measurement, and the point of recording it is to have something for the next person to compare.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# XCTest is absent from CommandLineTools, which is what `xcode-select -p` points at on the machine
# this was written on. Same override the test commands in CLAUDE.md use.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

echo "== hardware"
sysctl -n machdep.cpu.brand_string 2>/dev/null || true
sw_vers -productVersion | sed 's/^/macOS /'
swift --version | head -1
echo

echo "== building release (this is the slow part; the measurement is milliseconds)"
output=$(swift test -c release --filter CodecThroughputTests 2>&1) || {
    echo "$output"
    echo
    echo "FAILED: the measurement did not pass its own floor — see above" >&2
    exit 1
}

echo
echo "== P6.3"
# The rates the test printed. Fail rather than print a tick if they are missing: a run that measures
# nothing and exits zero is the green check that means nothing, which is the thing this whole area
# of the repo exists to prevent.
rates=$(printf '%s\n' "$output" | grep '^P6.3 ' || true)
if [[ -z "$rates" ]]; then
    echo "$output"
    echo
    echo "FAILED: no measurement was printed — did the test run?" >&2
    exit 1
fi
printf '%s\n' "$rates"

echo
echo "Floor is 50 MB/s on pane bytes (P6.3). Record the above in docs/measurements.md."
