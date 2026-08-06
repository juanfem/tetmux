#!/usr/bin/env python3
"""Records the `%output` streams P6.3's throughput measurement is run against.

P6.3 asks for sustained `%output` throughput of 50 MB/s on one pane. `ControlCodec` is a pure value
type, so the parser's half of that can be measured with no app, no channel and no hardware variance
worth speaking of — but only against bytes tmux really produced. The escaping is the whole cost
(`\\033` is four bytes on the wire for one in the pane) and its *density* is what decides the rate,
so a hand-written approximation would be measuring a guess.

    Scripts/capture-throughput.py            # tmux from PATH
    Scripts/capture-throughput.py 3.2a       # a matrix binary, if built

Two workloads, because one number would hide the interesting half:

  * `text` — a build log's shape: printable ASCII, varying line lengths, some UTF-8. Almost the
    only escapes are the `\\015\\012` at each line end, which is the case the codec's
    "no backslash, return the input" fast path is for.
  * `escapes` — the same volume of text wearing SGR colour, so roughly one escaped byte in eight.
    This is the one that decides whether the floor holds, and it is what a colourised build, a
    Powerline prompt or anything full-screen actually looks like.

What is recorded and what is not. The *content* of the two workloads is chosen here — it has to be
something, and a fixed generator is what makes two recordings comparable. The **encoding and the
chunking are tmux's**, which is the part that could be got wrong by hand: how it escapes, where it
breaks a burst into `%output` lines, and how big those lines are. That is why this is a recording
rather than a generator in the test.

The fixtures are deliberately small — a couple of hundred kilobytes each, not the megabytes P6.3
talks about. `CodecThroughputTests` repeats them to reach its measurement size, because the quantity
being measured is a *rate*: a megabyte in git buys nothing a repeat does not, and every fixture this
size fits in L2 either way, so the cache advantage is not one the bigger file would take away.

Run occasionally and by hand, never in CI. See the head of `capture-fixtures.py`: a fixture
regenerated on every run asserts only that today's parser agrees with today's tmux.
"""

from __future__ import annotations

import os
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / ".tmux-matrix" / "bin"
OUT = ROOT / "Tests" / "tetmuxCoreTests" / "Fixtures"

# Enough `%output` lines that the chunk-size distribution is the server's rather than an accident of
# where the recording stopped, and small enough to read in a diff before committing.
TARGET_BYTES = 192 * 1024

# One line of the corpus, by index. Deterministic: two recordings differ only in tmux's timestamps
# and command numbers, the same rule the R3.6 fixtures follow.
LINE_WIDTHS = [12, 47, 8, 96, 31, 64, 3, 120, 25, 78]
WORDS = "the quick brown fox jumps over a lazy dog while building target".split()


def corpus_line(index: int, coloured: bool) -> str:
    width = LINE_WIDTHS[index % len(LINE_WIDTHS)]
    body = " ".join(WORDS[(index + n) % len(WORDS)] for n in range(width // 5 + 1))[:width]
    # A little UTF-8, at the rate a real log carries it: a check mark, an arrow, an accented name.
    if index % 17 == 0:
        body = f"✓ {body} → café"
    if not coloured:
        return body
    # SGR around two spans per line, which is about one escaped byte in eight once tmux has turned
    # each ESC into `\033`. `ls --color`, a Powerline prompt and any TUI are all denser than this.
    colour = 31 + (index % 7)
    return f"\033[{colour}m{body[:width // 2]}\033[0m\033[1m{body[width // 2:]}\033[0m"


def corpus(coloured: bool) -> bytes:
    lines = []
    total = 0
    index = 0
    # Generously more than TARGET_BYTES: the pane is what stops, and a `cat` that ends early leaves
    # the capture short of its target with nothing to say why.
    while total < TARGET_BYTES * 3:
        line = corpus_line(index, coloured) + "\n"
        lines.append(line)
        total += len(line.encode())
        index += 1
    return "".join(lines).encode()


def capture(tmux: Path, socket: str, payload: Path, config: Path) -> bytes:
    """Attaches to a session whose one pane cats `payload`, and returns every byte tmux wrote."""
    pid, fd = pty.fork()
    if pid == 0:
        # Child: syscalls only. Same three rules as the R3.6 recorder — no user config, a fixed
        # grid, and a pane command that emits exactly what we asked for and nothing else.
        os.environ["TERM"] = "xterm-256color"
        os.environ["LANG"] = "en_US.UTF-8"
        os.execv(str(tmux), [
            str(tmux), "-f", str(config), "-L", socket, "-CC", "-2", "-u",
            "new-session", "-s", "throughput", "-n", "throughput", "-x", "200", "-y", "50",
            # `cat` then hold the pane open: a session that ends mid-capture takes the client with
            # it, and the tail of the stream would be a teardown rather than output.
            f"sh -c 'cat {payload}; sleep 30'",
        ])

    collected = bytearray()
    deadline = time.time() + 60
    try:
        while len(collected) < TARGET_BYTES and time.time() < deadline:
            readable, _, _ = select.select([fd], [], [], 0.2)
            if not readable:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            collected.extend(chunk)
    finally:
        subprocess.run([str(tmux), "-L", socket, "kill-server"], capture_output=True, check=False)
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass

    return bytes(collected)


def trim_to_whole_lines(data: bytes) -> bytes:
    """Drops a truncated final line.

    The capture stops on a byte count, which lands mid-`%output` about as often as not. The codec
    would hold that fragment in its line buffer forever and the test would measure one line fewer
    than it fed — harmless, but it makes the fixture a record of where `os.read` happened to stop.
    """
    end = data.rfind(b"\n")
    return data[: end + 1] if end >= 0 else data


def main() -> int:
    version = sys.argv[1] if len(sys.argv) > 1 else None
    if version:
        tmux = BIN / version / "tmux"
        if not tmux.is_file():
            print(f"error: no binary for {version} — run Scripts/build-tmux-matrix.sh first",
                  file=sys.stderr)
            return 1
    else:
        found = shutil.which("tmux")
        if found is None:
            print("error: no tmux on PATH", file=sys.stderr)
            return 1
        tmux = Path(found)

    label = subprocess.run([str(tmux), "-V"], capture_output=True, text=True, check=False).stdout.strip()
    print(f"recording with {label} ({tmux})")

    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        # Not `-f /dev/null` plus a `set-option` down the pty, which is how the R3.6 recorder does
        # it: a pty starts in canonical mode and echoes what is written to it, and there the write
        # comes after a handshake pump that has had time to take the terminal out of that mode.
        # Here the pane is already flooding by then, so waiting would overshoot the target by
        # several hundred kilobytes — and not waiting puts the command itself in the recording.
        # A config file asks the same question before there is a pty to echo it.
        config = Path(scratch) / "tmux.conf"
        # tmux names a window after what is running in it, so without this the stream carries a
        # `%window-renamed` for `cat` and another for `sleep` — this script's own scaffolding,
        # recorded as though it were protocol.
        config.write_text("set-option -g automatic-rename off\n")

        for name, coloured in (("text", False), ("escapes", True)):
            payload = Path(scratch) / f"{name}.txt"
            payload.write_bytes(corpus(coloured))
            socket = f"tetmux-throughput-{name}-{os.getpid()}"
            data = trim_to_whole_lines(capture(tmux, socket, payload, config))
            path = OUT / f"throughput-{name}.stream"
            path.write_bytes(data)

            lines = data.count(b"\n")
            outputs = data.count(b"%output ")
            marker = "   ** no %output — suspect **" if outputs == 0 else ""
            print(f"  {name:<8} {len(data):>7} bytes  {outputs:>5} %output lines"
                  f"  {len(data) // max(lines, 1):>4} B/line -> {path.name}{marker}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
