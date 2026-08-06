#!/usr/bin/env bash
#
# Runs the integration suite against every tmux version R3.6 names, rather than against whichever
# one this machine happens to have on its PATH.
#
#   Scripts/test-matrix.sh                    # every built version
#   Scripts/test-matrix.sh 3.0 3.2a           # or just some
#   Scripts/test-matrix.sh --filter testDraggingATabReordersTheSession
#
# The parsing matrix — Scripts/build-tmux-matrix.sh plus Scripts/capture-fixtures.py — pins what
# each version *says*. This pins what tetmux *does* about it, which is a different property and the
# one with the version branches in it: per-window sizing is off below 2.9, tab reordering is
# `move-window -b` on 3.2 and a run of `swap-window`s below it, pane commands are subscribed to on
# 3.2 and polled below it, and flow control does not exist at all before 3.2. Every one of those was
# exercised on exactly one version, because a machine has one tmux.
#
# Most of the value needs no new tests. Several already assert an *outcome* and silently change
# which branch they take with the version — `testDraggingATabReordersTheSession` is the clearest:
# the same assertion, run under 3.0, is the only thing that has ever executed the `swap-window`
# fallback end to end.
#
# It is both a local command and the body of a CI job, and the two use it differently. Run here with
# no arguments it does all five in sequence, sharing one build of the test bundle — right on a laptop,
# where the alternative is five toolchain builds. In CI each version is its own parallel job passing
# one version, so a failure names the version in the checks list rather than in a log, and the wall
# clock is the slowest version instead of the sum. It runs weekly and on demand, never on a push:
# building tmux from a pinned tarball is minutes of `./configure && make`, and the answer only
# changes when the code under those branches does.
#
# Each version gets a TMUX_TMPDIR of its own, which is not tidiness. tmux's client and server speak a
# private protocol that is not compatible across versions, so a 3.0 client finding the 3.7b server
# this machine is already running would either fail in a way that looks like a tetmux bug or, worse,
# attach to it and let the suite kill sessions in somebody's real workspace.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.tmux-matrix/bin"

VERSIONS=(3.0 3.2a 3.3a 3.4 3.5)
FILTER="SessionIntegrationTests"

wanted=()
while [ $# -gt 0 ]; do
    case "$1" in
        --filter)
            FILTER="${2:?--filter needs a value}"
            shift 2
            ;;
        -h|--help)
            sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            wanted+=("$1")
            shift
            ;;
    esac
done
if [ ${#wanted[@]} -eq 0 ]; then
    wanted=("${VERSIONS[@]}")
fi

# Xcode's toolchain: XCTest is absent from CommandLineTools, which is what `xcode-select -p` points
# at on the development machine.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

missing=()
for version in "${wanted[@]}"; do
    [ -x "$BIN/$version/tmux" ] || missing+=("$version")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "building missing versions: ${missing[*]}"
    "$ROOT/Scripts/build-tmux-matrix.sh" "${missing[@]}"
fi

# Built once, deliberately, outside the per-version loop: `swift test` would otherwise rebuild
# nothing but still spend seconds deciding that, five times over.
echo "building the test bundle"
swift build --build-tests >/dev/null

failed=()
for version in "${wanted[@]}"; do
    tmux_bin="$BIN/$version/tmux"
    reported="$("$tmux_bin" -V)"
    echo
    echo "═══ $reported  ($tmux_bin)"

    # A directory per version *and* per run. tmux puts its socket under $TMUX_TMPDIR/tmux-<uid>/, so
    # this is the whole of the isolation: a server started here cannot be found by anything else and
    # goes away with the directory.
    #
    # Under /tmp rather than $TMPDIR, and that is not a style choice: a unix socket path is capped at
    # 104 bytes, and macOS's per-user $TMPDIR is a ~50-character path under /var/folders before
    # anything is appended to it.
    tmpdir="$(mktemp -d /tmp/tetmux-matrix-XXXXXX)"
    log="$tmpdir/test.log"

    # `env` rather than `export`: a failure must not leak the override into the next iteration, and a
    # leaked TETMUX_TMUX is the one mistake that would make the whole run a lie.
    status=0
    env TETMUX_TMUX="$tmux_bin" TMUX_TMPDIR="$tmpdir" \
        swift test --filter "$FILTER" >"$log" 2>&1 || status=$?

    # The server outlives the test process by design — tmux daemonises — so it is told to go, and
    # **with the same TMUX_TMPDIR**: without it this addresses the default socket, which is the real
    # tmux server the person running this script is very likely sitting in.
    env TMUX_TMPDIR="$tmpdir" "$tmux_bin" kill-server >/dev/null 2>&1 || true

    # A skip is exactly as green as a pass, and the versions this script exists for are precisely the
    # ones where a test may decide it does not apply. Both numbers are printed, so a run that quietly
    # tested nothing cannot read as a run that tested everything.
    #
    # The summary line has two shapes — `Executed 60 tests, with 0 failures` and, once anything
    # skips, `Executed 60 tests, with 2 tests skipped and 0 failures` — so the count is taken on its
    # own rather than by matching the whole sentence. Matching the sentence is what this did first,
    # and the moment a test started skipping it printed "no tests ran" and a tick beside it.
    skipped="$(grep -cE "^Test Case .* skipped" "$log" || true)"
    summary="$(grep -oE "Executed [0-9]+ tests?, with .*" "$log" | tail -1 || true)"
    count="$(printf '%s' "$summary" | grep -oE "^Executed [0-9]+" | grep -oE "[0-9]+" || true)"

    if [ "$status" -ne 0 ]; then
        echo "✗ ${summary:-the suite did not report a summary} — $skipped skipped"
        grep -E "error: -\[|error: " "$log" | head -20 || true
        echo "  full log: $log"
        failed+=("$version")
    elif [ -z "$count" ] || [ "$count" -eq 0 ]; then
        # Exit status zero having run nothing is the failure this whole script exists to prevent one
        # version of: a green tick that means the tests did not happen. It is never a pass.
        echo "✗ no tests ran at all against $reported — that is not a pass"
        echo "  full log: $log"
        failed+=("$version")
    else
        echo "✓ $summary — $skipped skipped"
        rm -rf "$tmpdir"
    fi
done

echo
if [ ${#failed[@]} -gt 0 ]; then
    echo "failed on: ${failed[*]}"
    exit 1
fi
echo "all ${#wanted[@]} versions passed"
