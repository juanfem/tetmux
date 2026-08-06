#!/usr/bin/env python3
"""Records §8's rendering-acceptance corpus: a full-screen program's byte stream, and the grid
tmux itself renders from it.

§8/T5.7 ask for `vim`, `less`, a live full-screen program and a Powerline prompt to be checked
against a reference terminal. This is the recorder for both halves of that comparison, and the
choice worth explaining is **which terminal is the reference**: tmux's own.

That is not a shortcut, it is the property tetmux actually needs. The app asks tmux for
`frame.width / cellWidth` columns and then renders whatever tmux says the layout is, so the whole
correctness claim is that *the emulator in the app and the emulator in tmux build the same grid
from the same bytes*. A third-party reference would answer a more general question that nothing
here depends on, and would need a dependency nobody has installed.

Both halves come out of **one** run of **one** pane, which is what makes them comparable:

  * the stream is the `%output` payload for that pane, unescaped — byte for byte what
    `SessionService` hands a `TerminalView`, with tmux having already answered every device query
    the program asked;
  * the grid is `capture-pane -p` on the same pane, which is tmux's rendering of exactly those
    bytes.

The pane's process is stopped with `SIGSTOP` before the capture, so a program that redraws on a
timer (`htop`, `top`) cannot emit anything between the last byte recorded and the grid being read.
Without that the reference is a frame ahead of the stream, and the test fails for a reason that has
nothing to do with either emulator.

    Scripts/capture-programs.py                # everything available on this machine
    Scripts/capture-programs.py vim less       # a subset

Run by hand, never in CI, for the reason at the top of capture-fixtures.py: a fixture regenerated
on every run asserts that the parser agrees with whatever just happened, which is true by
construction. What is committed is a recording — and a recording of a *program*, so it is also a
record of that program's version on this machine, which is why the header written beside each one
says which.
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
OUT = ROOT / "Tests" / "tetmuxTests" / "Corpus" / "Programs"

# A fixed path rather than a temporary one: `vim` puts the filename in its status line and `less`
# in its prompt, so a per-run directory would put this machine's mktemp output in the corpus and
# make two recordings differ for no reason anyone can act on.
WORK = Path("/tmp/tetmux-corpus")
SAMPLE = WORK / "sample.txt"

GRID_COLUMNS = 80
GRID_ROWS = 24


def write_sample() -> None:
    WORK.mkdir(parents=True, exist_ok=True)
    lines = [
        f"{n:03d}  the quick brown fox jumps over the lazy dog — line {n}"
        for n in range(1, 201)
    ]
    SAMPLE.write_text("\n".join(lines) + "\n", encoding="utf-8")


# A Powerline prompt as bytes, because nothing on this machine renders one.
#
# It is written out rather than captured, and the header records that — but the bytes are the ones
# that matter and they are not an approximation of anything: truecolor SGR for each segment, and
# U+E0B0 as the separator, which is in the Private Use Area and therefore has *no* width anybody
# can look up. That is the whole reason a Powerline prompt is on §8's list: if tmux and the
# emulator disagree about how many cells that glyph takes, every segment after it is a column out
# and the prompt smears across the line.
POWERLINE = (
    r'printf "\033[38;2;255;255;255m\033[48;2;40;120;200m user \033[38;2;40;120;200m'
    r'\033[48;2;60;60;60m\033[38;2;220;220;220m ~/git/tetmux \033[38;2;60;60;60m'
    r'\033[48;2;180;80;40m\033[38;2;255;255;255m  main \033[0m\033[38;2;180;80;40m'
    r'\033[0m \r\n"'
)

# Each entry is the command the pane runs and the keys to drive it with, as `send-keys` arguments.
# Keys are sent one group at a time with a pause, so the program has finished redrawing before the
# next arrives — a burst would record a screen halfway through two of them.
SCENARIOS: dict[str, dict] = {
    # The editor: alternate screen, a status line, cursor addressing, and `set number` so the
    # left margin is redrawn under existing text rather than the whole screen being repainted.
    # `-u NONE -N` because a ~/.vimrc would make this a recording of one person's setup.
    "vim": {
        "command": f"vim -u NONE -N {SAMPLE}",
        "keys": [["G"], [":set number", "Enter"], ["gg"], ["3", "j"]],
    },
    # The pager: a full screen of text, a reverse-video prompt line, and a jump to the end, which
    # is where it repaints rather than scrolls.
    "less": {
        "command": f"less {SAMPLE}",
        "keys": [["Space"], ["G"]],
    },
    # A program that redraws on a timer, which is what makes the `SIGSTOP` below load-bearing.
    # §8 names `htop`; `top` is the same shape of program and is on every Mac, so both are listed
    # and whichever is present is recorded — `htop` is a homebrew install and a machine without one
    # should still be able to re-record the rest.
    #
    # `-p 1` for the same reason `top` gets `-pid`: pid 1 is `launchd` and is on every Mac, so the
    # process table has exactly one row and it is nobody's.
    "htop": {
        "command": "htop -d 10 -p 1",
        "keys": [],
        "requires": "htop",
    },
    # `-pid` on a `sleep` this script starts, and that is not tidiness: plain `top` paints the
    # machine's process list, so the first recording committed a corpus file naming every
    # application this user had open. A fixture is supposed to be a record of a *program*, and
    # this is the same leak `-f /dev/null` and `cat` panes exist to prevent in capture-fixtures.py.
    # One process nobody has to redact, and the timed repaint — which is the point — is unchanged.
    "top": {
        "command": "sh -c 'sleep 3600 & top -pid $! -s 2'",
        "keys": [],
        "requires": "top",
    },
    # See POWERLINE. `sleep` keeps the pane alive so the prompt is still on screen when the grid is
    # read; without it the pane exits, tmux closes the window, and there is nothing to capture.
    "powerline": {
        "command": f"sh -c '{POWERLINE}; sleep 3600'",
        "keys": [],
    },
}

STEP_PAUSE = 0.6
SETTLE = 1.5


class Channel:
    """Just enough control mode to collect one pane's output and read one command's answer.

    Framing outranks dispatch here for the same reason it does in `ControlCodec`: inside a
    `%begin` block every line is result content, including one that starts with `%`. `capture-pane`
    replays a screen, and a screen can contain anything.
    """

    def __init__(self, fd: int, pane: str = "%0") -> None:
        self.fd = fd
        self.pane = pane
        self.stream = bytearray()      # the pane's own bytes, unescaped
        self.block: list[bytes] | None = None
        self.blocks: list[list[bytes]] = []
        # How much of the stream had arrived when the most recent block opened. This is what makes
        # the two halves describe the same instant: tmux writes a pane's `%output` and a command's
        # `%begin` into one client buffer in the order it dealt with them, so everything before the
        # capture block's `%begin` is in the grid it answers with and everything after it is not.
        # Reading for another second after issuing the command — which is what it takes to be sure
        # the whole screen has arrived — otherwise appends frames the grid never saw.
        self.stream_at_block_start = 0
        self._buffer = bytearray()

    def pump(self, seconds: float) -> None:
        end = time.time() + seconds
        while time.time() < end:
            readable, _, _ = select.select([self.fd], [], [], 0.05)
            if not readable:
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            self._buffer.extend(chunk)
            while b"\n" in self._buffer:
                line, _, rest = self._buffer.partition(b"\n")
                self._buffer = bytearray(rest)
                self._line(line.rstrip(b"\r"))

    def _line(self, line: bytes) -> None:
        if self.block is not None:
            if line.startswith(b"%end ") or line.startswith(b"%error "):
                self.blocks.append(self.block)
                self.block = None
            else:
                self.block.append(line)
            return
        if line.startswith(b"%begin "):
            self.block = []
            self.stream_at_block_start = len(self.stream)
        elif line.startswith(b"%output "):
            _, _, rest = line.partition(b" ")
            pane, _, payload = rest.partition(b" ")
            if pane.decode(errors="replace") == self.pane:
                self.stream.extend(unescape_octal(payload))

    def send(self, command: str, seconds: float = STEP_PAUSE) -> list[bytes]:
        before = len(self.blocks)
        os.write(self.fd, (command + "\n").encode())
        self.pump(seconds)
        answers = self.blocks[before:]
        return answers[-1] if answers else []


def unescape_octal(payload: bytes) -> bytes:
    """tmux's `\\012` escaping, back to raw bytes. The mirror of `ControlCodec.unescapeOctal`."""
    if b"\\" not in payload:
        return payload
    out = bytearray()
    i = 0
    while i < len(payload):
        if payload[i : i + 1] == b"\\" and i + 3 < len(payload) + 1:
            digits = payload[i + 1 : i + 4]
            if len(digits) == 3 and all(0x30 <= d <= 0x37 for d in digits):
                out.append(int(digits, 8))
                i += 4
                continue
            if payload[i + 1 : i + 2] == b"\\":
                out.append(0x5C)
                i += 2
                continue
        out.append(payload[i])
        i += 1
    return bytes(out)


def version_of(command: str) -> str:
    """The program's own version line, for the header. A recording of a program is a recording of
    a *version* of it, and without this nobody can tell which one disagreed."""
    binary = command.split()[0]
    if binary == "sh":
        return "printf(1)"
    for flag in ("--version", "-v", "-V"):
        try:
            result = subprocess.run(
                [binary, flag], capture_output=True, timeout=5, text=True, check=False
            )
        except (OSError, subprocess.SubprocessError):
            continue
        output = (result.stdout or result.stderr).strip().splitlines()
        if output:
            return output[0].strip()
    return f"{binary} (version unknown)"


def capture(name: str, scenario: dict, socket: str) -> tuple[bytes, list[str]] | None:
    pid, fd = pty.fork()
    if pid == 0:
        # Child: syscalls only. No config file, a fixed grid, and the program as the pane command
        # so the pane's first byte is already the program's.
        os.environ["TERM"] = "xterm-256color"
        os.environ["LANG"] = "en_US.UTF-8"
        os.environ["LC_ALL"] = "en_US.UTF-8"
        os.execvp("tmux", [
            "tmux", "-f", "/dev/null", "-L", socket, "-CC", "-2", "-u",
            "new-session", "-s", "corpus", "-n", "corpus",
            "-x", str(GRID_COLUMNS), "-y", str(GRID_ROWS),
            scenario["command"],
        ])

    channel = Channel(fd)
    try:
        channel.pump(1.5)  # the handshake, and the program's first paint
        # tmux names a window after what is running in it, and the rename is a notification the
        # pane never sees — but it costs a redraw of nothing and makes the recording depend on the
        # process tree, exactly as it does in capture-fixtures.py.
        channel.send("set-option -g automatic-rename off")

        for group in scenario["keys"]:
            # Every key is quoted, because `send-keys` takes one argument per key sequence and
            # splits on spaces like everything else tmux parses: `send-keys :set number Enter` types
            # `setnumber`, which vim answers with `E492: Not an editor command` — recorded, and
            # committed, before anyone noticed the corpus was a record of that instead.
            channel.send("send-keys -t %0 " + " ".join(f"'{key}'" for key in group))
        channel.pump(SETTLE)

        answer = channel.send("display-message -p -t %0 '#{pane_pid}'")
        pane_pid = int(answer[0]) if answer and answer[0].strip().isdigit() else 0
        if not pane_pid:
            print(f"  {name}: could not find the pane's process", file=sys.stderr)
            return None

        # Freeze the program before reading the grid. Everything already written is in the stream;
        # nothing more can be written, so the grid below is the rendering of exactly these bytes
        # and not of one frame more. `SIGSTOP` rather than `SIGKILL`: killing the pane's process
        # ends the pane, and tmux clears what it was showing.
        #
        # The signal goes to the **process group**, not to `#{pane_pid}`. tmux makes the pane's
        # process a group leader, so the two numbers are the same — but a pane command that is a
        # shell with a job in it (`sh -c 'sleep & top'`) does not `exec`, so the pid names the
        # shell and the program repainting the screen is its child. Stopping the shell alone
        # freezes nothing: the first `top` recording had two frames more in the stream than in the
        # reference grid, which reads exactly like an emulator disagreement and is not one.
        os.kill(pane_pid, 0)
        subprocess.run(["kill", "-STOP", f"-{pane_pid}"], check=False)
        channel.pump(0.6)

        grid = channel.send("capture-pane -p -t %0", seconds=1.0)
        stream = bytes(channel.stream[: channel.stream_at_block_start])
        subprocess.run(["kill", "-CONT", f"-{pane_pid}"], check=False)
        return stream, [line.decode("utf-8", errors="replace") for line in grid]
    finally:
        subprocess.run(["tmux", "-L", socket, "kill-server"], capture_output=True, check=False)
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass


def main() -> int:
    wanted = sys.argv[1:] or list(SCENARIOS)
    unknown = [name for name in wanted if name not in SCENARIOS]
    if unknown:
        print(f"error: unknown scenario(s) {unknown}; have {list(SCENARIOS)}", file=sys.stderr)
        return 1

    write_sample()
    OUT.mkdir(parents=True, exist_ok=True)

    for name in wanted:
        scenario = SCENARIOS[name]
        required = scenario.get("requires")
        if required and shutil.which(required) is None:
            print(f"{name:<10} skipped — {required} is not installed")
            continue

        socket = f"tetmux-corpus-{name}-{os.getpid()}"
        result = capture(name, scenario, socket)
        if result is None:
            continue
        stream, grid = result

        # Trailing blank rows carry no information and differ with how far a program bothered to
        # paint; the test drops them on both sides, so they are dropped here too.
        while grid and not grid[-1].strip():
            grid.pop()

        (OUT / f"{name}.stream").write_bytes(stream)
        header = [
            f"# {name} — recorded by Scripts/capture-programs.py",
            f"# program: {version_of(scenario['command'])}",
            f"# reference: {subprocess.run(['tmux', '-V'], capture_output=True, text=True).stdout.strip()}"
            f" rendering the bytes in {name}.stream at {GRID_COLUMNS}x{GRID_ROWS}",
        ]
        (OUT / f"{name}.grid").write_text(
            "\n".join(header + grid) + "\n", encoding="utf-8"
        )
        print(f"{name:<10} {len(stream):>7} bytes, {len(grid):>2} rows -> {name}.stream/.grid")

    print(f"\nwrote to {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    if shutil.which("tmux") is None:
        print("error: tmux is the reference terminal here; install it first", file=sys.stderr)
        sys.exit(1)
    sys.exit(main())
