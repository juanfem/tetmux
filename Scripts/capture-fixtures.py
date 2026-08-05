#!/usr/bin/env python3
"""Captures control-mode byte streams from each tmux in the R3.6 matrix.

R3.6 asks for the codec to be developed against recorded fixtures from tmux 3.0, 3.2a, 3.3a, 3.4
and 3.5 rather than by manual testing. This is the recorder. It drives a real `tmux -CC` under a
pty — the only way to see what the protocol layer actually receives, since a pipe changes tmux's
behaviour — and writes the raw bytes to Tests/tetmuxCoreTests/Fixtures.

    Scripts/build-tmux-matrix.sh          # once, to get the binaries
    Scripts/capture-fixtures.py           # then this

Run occasionally and by hand, never in CI: see the note at the top of build-tmux-matrix.sh for why
regenerating a fixture on every run deletes the thing it was testing.

Three things make the captures comparable across versions rather than a record of this machine:

  * `-f /dev/null` — the user's ~/.tmux.conf must not leak into a fixture. It would silently make
    the capture describe one machine's configuration instead of a tmux version.
  * every pane runs `cat`, so a pane emits exactly what is sent to it and nothing else. With a
    login shell the fixtures fill with somebody's prompt, their $PS1 escape sequences, and their
    hostname — none of which is protocol.
  * a fixed 80x24 and a private socket per version, so nothing depends on the terminal this was run
    from or on a server that happens to be running.
  * each binary installed as plain `tmux` — tmux names a window after the command running in it, so
    a binary called `tmux-3.5` puts `%window-renamed @0 tmux-3.5` into the fixture and makes it a
    record of this script's filenames rather than of a version.

Timestamps and command numbers still differ between runs — they are wall-clock and server-wide, and
that is the protocol's business, not ours. So fixtures are not byte-identical across recordings, and
the tests assert *structure*: what events a stream yields and what the model built from it looks
like. A fixture is a record of a conversation, not a golden file.
"""

from __future__ import annotations

import os
import pty
import select
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / ".tmux-matrix" / "bin"
OUT = ROOT / "Tests" / "tetmuxCoreTests" / "Fixtures"

VERSIONS = ["3.0", "3.2a", "3.3a", "3.4", "3.5"]

# Each scenario is a list of control-mode command lines. They are written to the pty one at a time
# with a pause between, because the point is to record what tmux emits *in response to each*, and a
# burst would interleave the answers into one indistinguishable run.
#
# The sequences are R3.6's: split, kill, resize, rename, copy-mode, detach — plus output, which is
# where the octal escaping lives (R3.4), and zoom, which is where `%layout-change`'s second and
# third fields matter and where a client that reads the wrong one paints the wrong grid.
# Run before every scenario, and deliberately part of the recorded stream rather than hidden.
#
# tmux's automatic rename walks the pane's process tree, and what it finds there is whatever the
# machine is doing: one 3.0 capture came back with `%window-renamed @0 kernel_task`. That is the
# machine leaking into a fixture in the same way a ~/.tmux.conf would, and it makes two recordings
# of the same version differ for no reason anyone can act on. The `rename` scenario turns it back on
# itself, because there it is the subject.
PREAMBLE = ["set-option -g automatic-rename off"]

SCENARIOS: dict[str, list[str]] = {
    # Nothing at all: just the handshake. The DCS preamble, tmux's own first %begin/%end block
    # before a client can write anything, and the notifications that follow an attach.
    "attach": [],
    "split": [
        "split-window -h cat",
        "split-window -v cat",
        "list-windows -F '#{window_id}|#{window_layout}'",
    ],
    "zoom": [
        "split-window -h cat",
        "resize-pane -Z",
        "list-windows -F '#{window_id}|#{window_layout}|#{window_visible_layout}|#{window_flags}'",
        "resize-pane -Z",
    ],
    "resize": [
        "split-window -h cat",
        "refresh-client -C 120,40",
        "resize-window -x 100 -y 30",
        "resize-pane -L 10",
    ],
    "rename": [
        "set-option -g automatic-rename on",
        "rename-window fixture-window",
        "rename-session fixture-session",
        "set-option -w automatic-rename off",
        "rename-window back",
    ],
    "copy-mode": [
        "copy-mode",
        "send-keys -X cursor-up",
        "send-keys -X cancel",
    ],
    # A *second* window before the kill, deliberately. Killing the only window destroys the
    # session — tmux discards a session with no windows — so without one the fixture ends in
    # `%exit` and never shows a `%window-close` at all. That is captured too, as `kill-session`.
    "kill": [
        "split-window -h cat",
        "split-window -v cat",
        "kill-pane",
        "new-window cat",
        "kill-window -t @0",
    ],
    # The other half of the pair, and the one the recovery path turns on: an ending session and a
    # detaching client both announce themselves with a bare `%exit`, while a dropped link produces
    # EOF and nothing. Told apart wrongly, a deliberate close is treated as a blip and reconnected
    # with `new-session -A`, recreating the session the user just closed.
    "kill-session": [
        "kill-session",
    ],
    "detach": [
        "detach-client",
    ],
    # `cat` is the pane command, so this comes straight back as %output — which is where the octal
    # escaping is. The bytes are chosen to cover what R3.4 cares about: an ESC, a high byte, a
    # backslash that is data rather than an escape, and a newline inside a payload.
    "output": [
        "send-keys -H -t %0 68 65 6c 6c 6f 0a",
        "send-keys -H -t %0 1b 5b 31 6d 62 6f 6c 64 1b 5b 30 6d 0a",
        "send-keys -H -t %0 5c 6e 6f 74 2d 61 6e 2d 65 73 63 61 70 65 0a",
        "send-keys -H -t %0 c3 a9 c3 bc e2 82 ac 0a",
    ],
}

# How long to wait after each command before writing the next, and how long to keep reading once the
# script is done. Generous rather than tight: a fixture that truncates mid-block is worse than a
# slow capture, and this runs by hand.
STEP_PAUSE = 0.45
DRAIN = 2.0


def capture(tmux: Path, socket: str, commands: list[str]) -> bytes:
    """Runs one scenario against one tmux and returns every byte it wrote."""
    pid, fd = pty.fork()
    if pid == 0:
        # Child: syscalls only from here. No config file, a fixed grid, and `cat` as the pane
        # command so the pane is silent until something is sent to it.
        os.environ["TERM"] = "xterm-256color"
        os.environ["LANG"] = "en_US.UTF-8"
        os.execv(str(tmux), [
            str(tmux), "-f", "/dev/null", "-L", socket, "-CC", "-2", "-u",
            "new-session", "-s", "fixture", "-n", "fixture", "-x", "80", "-y", "24", "cat",
        ])

    collected = bytearray()

    def pump(seconds: float) -> None:
        end = time.time() + seconds
        while time.time() < end:
            readable, _, _ = select.select([fd], [], [], 0.05)
            if not readable:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            collected.extend(chunk)

    try:
        pump(1.2)  # the handshake
        for command in PREAMBLE + commands:
            os.write(fd, (command + "\n").encode())
            pump(STEP_PAUSE)
        pump(DRAIN)
    finally:
        # Kill the server rather than the client: a detached session would outlive this script and
        # the next scenario would attach to it instead of starting clean.
        subprocess.run([str(tmux), "-L", socket, "kill-server"],
                       capture_output=True, check=False)
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass

    return bytes(collected)


def main() -> int:
    wanted = sys.argv[1:] or VERSIONS
    unknown = [v for v in wanted if v not in VERSIONS]
    if unknown:
        print(f"error: unknown version(s) {unknown}; have {VERSIONS}", file=sys.stderr)
        return 1

    missing = [v for v in wanted if not (BIN / v / "tmux").is_file()]
    if missing:
        print(f"error: no binary for {missing} — run Scripts/build-tmux-matrix.sh first",
              file=sys.stderr)
        return 1

    OUT.mkdir(parents=True, exist_ok=True)

    for version in wanted:
        tmux = BIN / version / "tmux"
        for name, commands in SCENARIOS.items():
            socket = f"tetmux-fixture-{version}-{name}-{os.getpid()}"
            data = capture(tmux, socket, commands)
            path = OUT / f"tmux-{version}.{name}.stream"
            path.write_bytes(data)
            marker = "" if b"%begin" in data else "   ** no %begin — suspect **"
            print(f"{version:<5} {name:<10} {len(data):>7} bytes -> {path.name}{marker}")

    print(f"\nwrote {len(wanted) * len(SCENARIOS)} fixtures to {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    if shutil.which("tmux") is None and not BIN.is_dir():
        print("error: no tmux matrix — run Scripts/build-tmux-matrix.sh", file=sys.stderr)
        sys.exit(1)
    sys.exit(main())
