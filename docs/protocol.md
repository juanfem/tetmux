# Protocol gotchas

Split out of `CLAUDE.md`. Read this before touching `ControlCodec`, `LayoutParser`, or anything
else that parses the control-mode wire; `docs/invariants.md` holds the correlation and framing
rules that sit one layer above these.

`ControlCodec` is a pure value type: `mutating func feed(_:) -> [ControlEvent]`, no I/O, no async.
Keep it that way — it is the only reason the protocol layer is testable against fixtures.

- `%layout-change @w <layout> <visible-layout> <flags>` — **three** fields since tmux 2.5, and all
  three are load-bearing. Folding them into one string makes the layout unparseable and the window
  renders nothing; dropping the second and third instead parses fine and renders the wrong grid
  whenever a pane is zoomed.
- `%extended-output %p <age> : <data>` — the colon is a reserved field and must be skipped. A layout
  with no colon field must fail the parse rather than yield empty data, or a build that varies the
  field layout makes every pane go quietly dead.
- `%subscription-changed <name> <session> <window> <index> <pane> : <value>` — same reserved colon.
  The name must be checked: another control client can hold subscriptions of its own.
- **`#{session_attached}` does not count a control-mode client on tmux 3.0.** Verified across the
  built matrix: 3.0 answers `0` for the very session this client is attached to, and 3.2a onward
  answer `1`. So `TmuxSession.isAttached` is always false on a 3.0 server for tetmux's own sessions —
  cosmetic, because nothing decides anything from it. `HostState.liveSessionIds` is what answers "are
  these panes live", it is tetmux's own record, and it is the same on every version. Anything
  asserting that a client moved must use it.
- `%output` payloads are octal-escaped and arbitrary binary. Decode on bytes, never via `String`.
- Lines are bounded at 16 MiB, after which the buffer resets. A control stream that never sends a
  newline is otherwise unbounded memory growth.
- **Command *arguments* are parsed by tmux's own lexer, and a shell cannot tell you how.** Passing argv
  from a shell parses no tmux quoting at all, so probe questions like this over a real channel. Verified
  on 3.7b, inside double quotes: `\n`/`\r`/`\t`/`\e` work, `$VAR` **expands**, `\$` and `\#` are literal,
  raw ESC/0x01/0x7f pass through, octal `\101` works, and `\xHH` does *not* (it yields a literal `x`).
  NUL cannot survive at all — commands are C strings.
- Command response bodies are *not* escaped, so `capture-pane -e` output arrives as raw escape
  sequences; `commandResultLine` carries raw `bytes` alongside the lossy `line`.
- The stream opens with a DCS preamble (`ESC P 1000 p`) glued to the first `%begin`, and over ssh
  there may be banner text ahead of it. Anything before the first `%begin` is not protocol.
- Unknown `%` notifications are logged and ignored, never fatal — tmux adds them between versions.
- `LayoutParser` runs on bytes from the wire, so it must never trap: overflow is checked rather than
  arithmetic-trapped, and recursion is depth-capped. `try?` catches neither.
- **The layout checksum is verified (R3.5), and what makes that safe is that a rejection is
  all-or-nothing.** `layoutTree == nil` renders an *empty window*, so validation that blanks the tree
  on a mismatch would cost the user their panes on the first `%layout-change` — which is why it
  defaulted to off for so long. `TmuxWindow.apply` instead parses both fields up front and either
  commits both or keeps the previous layout, string and tree together: the worst case is a grid that
  was right a moment ago, and the next notification replaces it. Both fields go down together on one
  bad parse deliberately — they describe one window and arrive in one notification, and applying the
  full layout alone would set `isZoomed` with no visible tree, which is the wrapped-and-truncated
  failure `window_visible_layout` exists to prevent. `apply` returns a `LayoutApplyResult` because the
  model has no logger and a silently discarded layout is the exact shape of bug this list is made of.

