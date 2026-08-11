# Behaviour worth knowing before changing it

Part of the project guidance; `CLAUDE.md` holds the orientation and the index. One entry per
feature or mechanism, each recording what the behaviour is, why it is that way, and which parts are
load-bearing. Entries lead with the rule; the history after it is what makes the rule concrete.

## Channels, attachment, and streaming

**Passthrough is a different channel, not control mode with features off (§4.6, F4.27).** A server
below the version floor gets `PassthroughChannel`: one `tmux` on a pty with no `-CC`, painting
itself into one `TerminalView`, with tmux's own status bar and prefix key doing the jobs tetmux
normally does. Four things about it are load-bearing:

- **The version probe ends the channel.** `complete(.version)` hands over and *returns*, because
  applying the window-size, flow-control and subscription policies to a server that has none of
  those commands is what the old "banner and carry on" did.
- **Geometry inverts.** §3.3 gives tmux geometry because tmux is laying panes out and reporting
  where they went; here the surface *is* the client's terminal, so `sizeChanged` is acted on
  rather than ignored and `TIOCSWINSZ` is the entire mechanism — two macOS windows take turns,
  last one winning, exactly as two tmux clients of different sizes do.
- **There is nothing to repaint from**, so the channel keeps a 128 KiB replay buffer and hands it
  to each new subscriber: without it, a second window is a black rectangle nothing will ever fill,
  and one line drawn wrongly from a mid-stream start is the better failure. Output is bounded by
  dropping chunks for the same reason — `refresh-client -A` is tmux 3.2, so there is no pause to
  ask for — and this is the one place in the app where bytes are discarded without owing a repaint.
- **The plain shell (R3.8's last row) is offered, never started.** Nothing on a host with no tmux
  persists, so opening one unbidden would invent the only promise this mode cannot make.

A host in the mode is `.degraded`, which is *active* — so `connectHost` stops the passthrough
channel itself, or an explicit "try control mode again" would be refused by the idempotence guard
and there would be no way back. A workspace entry naming such a host also has to *land* rather than
stay pending: an unresolved restore re-asserts its host on every snapshot, and since a passthrough
host never gains a session, clicking any other host in the tree was silently undone by the next
topology change.

**Control mode only streams `%output` for the attached session.** Selecting another session must
issue `switch-client`, or its panes render once from `capture-pane` and then sit frozen.

**Nothing repaints on its own.** Attaching to an existing session shows an empty terminal until
`capture-pane -p -e -J` runs. That is what `subscribeToPane` triggers on first subscription, and
what `completeHandshakeIfNeeded` re-triggers for every already-subscribed pane on reattach (F4.16).

**One tmux client per session on screen — and the extra ones are not the connection.** `%output`
arrives only for the session a client is attached to, and a client has exactly one session. With a
single channel per host, every window on a second session was a `capture-pane` still frame, and the
only cure (`switch-client`) moved the freeze to the other window rather than removing it. So a host
has a **primary** channel and any number of **followers**: `connections[hostId]` is the primary,
`followerChannels[hostId][sessionId]` is one client per additionally-displayed session.
`setDisplayedSessions` is the only input — `AppModel` recomputes it from every open window's
selection — and `reconcileChannels` makes reality match it.

The two kinds are deliberately not symmetrical, and treating a follower as a connection is the way
to break this. The primary *is* the host: its state is the host's `connectionState`, its `%exit` is
the server ending, its prompt is the authentication sheet, it owns the reconnect backoff and
circuit breaker, and every command anyone issues goes down it. A follower does exactly one thing —
make one more session's panes move. It raises no prompt, changes no connection state, and when it
dies it says only that one session stopped streaming; there is no backoff, because the usual reason
a follower dies is that its session did. Sharing is by session, not by window: two windows on one
session are two views of one client, since a second client there would stream the same panes twice.

The primary is *moved* rather than duplicated when its own session leaves the screen: it has to be
attached to something, and `switch-client` only strands panes when somebody is watching them, which
is precisely the case `reconcileChannels` checks before doing it. Retiring a follower is a
check-then-act across an `await`, so it re-checks after the wait: tabbing away and back inside the
grace period otherwise tore down the client the reconcile had just decided to keep, and nothing was
scheduled to notice.

**A pane belongs to one channel, or it is painted twice.** A window can be linked into several
sessions (F4.9's subject), and every attached client streams `%output` for every pane it can see —
verified on 3.7b by attaching two control clients to two sessions sharing a window: both emit the
same `%output %p` line. Two copies fed to one emulator is a corrupted screen, which is worse than
the frozen one this whole mechanism exists to fix. `paneOwners` is first-come ownership by channel
epoch; everyone else's bytes for that pane are dropped, and when the owner goes away the pane is
released *and repainted*, because whoever picks it up has been having its bytes discarded and is
mid-stream on a screen it never drew. `refresh-client -A` (the pause) has to go to the owning
client too — asking the primary to pause a pane it is not streaming does nothing at all, silently.

**`HostState.liveSessionIds` is what tetmux is attached to, and it counts channels that are still
connecting.** `TmuxSession.isAttached` is tmux's own client count and includes terminals elsewhere
on the machine, so it cannot answer "are these panes live?". Liveness deliberately includes a
follower that is still handshaking and a `switch-client` that has not landed
(`Connection.pendingSessionId`): attaching is a round trip, and the strictly honest answer for its
duration makes `NotAttachedBanner` appear for a tenth of a second and withdraw, which reads as a
glitch rather than as information. A *failed* `switch-client` must clear `pendingSessionId`, or a
dead session reports live forever and the banner never appears over a window that has stopped
moving.

**Stale tetmux clients are detached on attach (F4.17), and the tag is `client_control_mode`.** The
SRD asks for a distinctive client name; tmux has none to give — `client_name` *is* the tty, and
there is no command to set it (verified on 3.7b). So an orphan is "a control-mode client whose tty
is not one of ours", which means the handshake must learn its own `#{client_tty}` *before* the
`list-clients` response arrives — the two are issued in that order deliberately, and the FIFO is
what makes it work. The whole pass is skipped if any channel of the host has not yet answered its
tty query, because a handshaking follower is indistinguishable from an orphan. Ordinary
`tmux attach` terminals are never candidates. Known blast radius: two live tetmuxen against one
server (a `swift run` beside an installed build) detach each other, as would iTerm2's tmux
integration.

**Pane commands are subscribed to on tmux ≥ 3.2 and polled below it.**
`refresh-client -B tetmuxPaneCommand:%*:"#{pane_current_command}"` is what reports a command
started in a *background* pane — nothing announces `pane_current_command` otherwise: it arrives
only with a `list-panes`, and the refreshes that trigger one fire on renames and pane switches. So
`schedulePaneRefresh` on `%window-renamed` and `%window-pane-changed` is the fallback path, not the
mechanism. Subscriptions are issued on the **primary only**: they are per client but the values are
server-wide, so a follower subscribing multiplies identical notifications.

**Nothing switches sessions on focus any more.** `AppModel.focus` used to call `switchSession` so
the window you clicked into became the live one; with a client per displayed session there is
nothing to move, and moving it would freeze the window you just left. Focus now only republishes
scope and re-runs `syncDisplayedSessions`. That call is made from everywhere the answer can change
— focus, `select`, a window registering or unregistering, and every topology snapshot, since a
session put on screen before tmux has named it cannot be attached to by id until the snapshot
arrives.

## Connecting and recovery

**Discovery asks `tmux -C list-sessions` and attaches nothing (F4.4).** The list is not the point:
clicking an unconnected host runs `new-session -A -s <a generated name>`, so a host with the user's
own work on it used to get a second, empty session made before anyone saw what was there. A
discovered session attaches *by name* with `attach-session`, which cannot create. Four things are
load-bearing:

- **`tmux -C` reads commands until its input ends.** `tmux -C list-sessions` prints the answer and
  then hangs forever, so every caller gives it `/dev/null`; a probe that hangs is worse than none,
  because nothing is watching it.
- **The answer is `%begin`-framed and the failures are not.** That is what lets `ControlCodec` find
  the list under an ssh banner, and what separates "this host has nothing" (tmux's own
  `no server running`) from "we could not ask" — hence `discoveredSessions` being an *optional*:
  recording an unreachable host as empty tells somebody their sessions are gone because their
  laptop is on a train.
- **It runs through `CommandProbe`, not `PtyTransport`**, because a pty is somewhere ssh can
  prompt. A pipe plus `BatchMode=yes` is the whole of "this cannot interrupt anybody", and the
  price is that a password host with no live `ControlMaster` answers nothing until it has been
  connected once.
- **`browsableSessions` is the one place that decides which list a surface shows**, because the
  sidebar, the launcher and the menu bar all ask.

**The local host connects itself at launch; remote ones wait to be asked.** This is not a general
auto-connect policy. Local tmux is always reachable, needs no credentials and cannot prompt for
anything, so the click was a step with no decision in it. A remote host connecting unbidden can
raise a password sheet, and several of them at launch is worse than a click.

**The backoff is for a connection that dropped, not for one that never started.** Authentication
failures are not retried, and neither is a connect the *user* asked for that never reached a
handshake: it failed at something they are standing there to read — a wrong hostname, a refused
port, a host that is off — and eight silent attempts over ninety seconds neither fix that nor say
what it is. The reason goes on screen with the Retry beside it. What does back off (1 s → 60 s with
jitter, circuit breaker after 8 attempts — F4.14) is a channel that handshaked and then died, and a
recovery attempt that fails before its handshake — the lid closing on a train, where failing is the
expected state for the next several attempts. `Connection.isRecoveryAttempt` is the difference. An
explicit connect clears the breaker, because a click is the user asserting the host is reachable,
and a host that spent its attempts must still come back. A pending backoff is a *task*, and both
`disconnectHost` and `reconnectNow` cancel it: a host the user deliberately closed used to
reconnect a minute later, possibly raising a password prompt, because `.disconnected.isActive` is
false and `connectHost`'s guard never saw it.

**A reconnect reattaches to `reconnectTarget`, not to the session it first connected with.** The
target is tracked from `%session-changed`, so it follows `switch-client`. Reattaching to the
original target strands the user on a session that gets no `%output` — the frozen-panes failure
above, one layer up.

**A dead channel is not noticed promptly.** ssh takes `ServerAliveInterval` × `CountMax` (~45 s) to
turn a dead link into EOF, and until then writes into the pty still succeed — which is why
`probeAllConnections` cannot detect a stale-but-`.connected` host by writing to it.
`ConnectionBanner` exists because automatic recovery is best-effort: the panes stay on screen
holding real scrollback, so the user needs to be told they are a snapshot and given a button. A
10 s `display-message -p ''` round trip is what the status bar's RTT dot reports (F4.29).

**Everything that can hang has a bound, because the failure of an unbounded wait is "Connecting…"
forever.** A 45 s handshake watchdog covers a blocking MOTD or a hung `ProxyCommand`; without it, a
version probe that never answered also left `connection.version` nil, and `applyWindowSizePolicy`
returned at its first guard, so every resize was silently dropped for the life of the channel. The
pre-handshake outbox caps at 256 commands and drops the *oldest* — the newest is what the user just
typed. `sendAndAwait` times out at 2 s, and every path that could strand a waiter (write failure,
`%error`, `teardown`) resumes it.

**The outbox is bounded by age as well as by size, and the clock is `ContinuousClock`.** The size
cap says how much may wait and nothing about how long: a host that came back after ten minutes of
outage still replayed the survivors in one burst — keystrokes typed at a shell that had long moved
on, executed rather than read. Each queued command is stamped on enqueue, and anything older than
10 s is dropped at flush, with the count logged. Never `Date`: this is the one code path that lives
on the sleep/wake boundary, which is exactly where a wall clock jumps. The clock is injected
through `SessionService(now:)` so a test can move it — waiting ten real seconds to assert a
ten-second rule is a test nobody runs. There is deliberately no distinction between kinds of
command: the age alone disqualifies.

**An empty server is not an unreachable host, and the sidebar says which.** A tmux client cannot
stay attached to a server with no sessions — tmux exits — so an empty server *is* a disconnected
host, and "not connected" read as a failure on a machine that is perfectly reachable. That is the
ordinary state of the local host once its last session goes. `HostState.serverIsEmpty` is the
distinction, and it keys on `endedSessionName`, never on an empty session list: a host that was
never connected has one of those too, and about that host nothing is known. This is deliberately
*not* fixed by having the local host make itself a session — that was tried, and it breaks F4.15's
two tests and silently removes the ended-session offer, since a window with a new session to show
never presents one.

The local host's menu drops **Disconnect**, **Detach This Client** and **Reconnect** for the same
reason its label changed: it is connected at launch, needs no credentials, and New Session attaches
on its way to creating one (`createSession` routes a host with no channel through `connectHost`),
so all three name problems it does not have. **The menu bar extra's Connect goes with them** — the
same rule arriving one surface late: that item is shown for a host with no browsable sessions that
is not active, which for the local host is the ordinary empty-server state above rather than
anything to connect. It sat directly beside a New Session that does strictly more, named after a
problem this host cannot have.

**Network *switches* never report `.unsatisfied`.** `NetworkStateMonitor` compares
`path.availableInterfaces` as well as the satisfied flag; watching only the flag misses Wi-Fi to a
different Wi-Fi, which is exactly when a host that was unreachable becomes reachable again.

## ssh, credentials, and host configuration

**ssh prompts on a pty nobody is looking at.** `SshPromptDetector` watches the pre-handshake stream
for a prompt ssh is *sitting* on — the signal is a trailing line with no newline after it, so a
banner merely mentioning a password is correctly ignored. The prompt is published on
`HostState.authenticationPrompt` (not folded into `ConnectionState`, which every UI switch would
then have to grow a meaningless case for) and either filled from the Keychain or shown in a sheet.
Fixtures are real captures from OpenSSH under a pty.

**Four kinds of prompt — and the last two exist because "not classified" meant "hangs for 45
seconds".** A password and a key passphrase are answered as before. A **host key** is a
first-contact question, and it is a *decision* rather than a text field: ssh's own lines are shown
verbatim — the fingerprint is on a different line from the question, hence `promptContext` — with
Cancel as the default button and no "always trust". That is not §2.3's forbidden auto-accept; §2.3
forbids the *application* accepting a key, and this puts ssh's question in front of the person who
has to answer it. A key that *changed* cannot arrive here at all: ssh refuses that outright instead
of asking. Everything else — a one-time code, a PAM challenge, something a `ProxyCommand` wants —
is a **question**: shown verbatim, answered, never stored, never filled from the Keychain.

Two details are load-bearing. The host-key line ends in **`? `, not a colon** — which is exactly
why the old colon rule returned nil and the channel then sat until the handshake watchdog killed
it. And an unclassified question is believed only after the stream has been quiet for 700 ms,
because a read can land mid-line and make an ordinary banner look like ssh waiting on a prompt. One
*secret* per channel still holds — a rejected password resubmitted is how accounts get locked out —
but a host-key answer is not a secret, so "yes" followed by a password now works; a hard ceiling of
three answers bounds the case where a question was classified wrongly.

**Keychain access lives in `tetmuxUI`, not `tetmuxCore`.** `Security.framework` is as macOS-only as
AppKit (§2.4). `SessionService` never reads a credential — it publishes the prompt and is handed an
answer — so the platform boundary stays put. Calls run on a detached task: `SecItemCopyMatching`
can put a dialog on screen (an unsigned dev build is asked every rebuild, because the ACL is tied
to the code signature), which would beachball the main thread or stall every host behind the actor.

**`ssh -G` is for showing, never for connecting (F4.2).** `resolveEffectiveConfig` answers what an
alias means — hostname, user, port, jump — and the host editor uses it for its placeholders, so a
blank User field says `deploy` rather than "optional" and the user can see what leaving it blank
will do. What it must not do is feed those values back to `ssh`: the connection is made with the
*name*, so ssh applies its own file and every `Match` block resolves against the real invocation.
Resolving here and passing the pieces explicitly would be re-deciding what ssh has already decided.
The map keeps a repeated key's **first** value — ssh's own precedence for scalar options — and some
keys are genuinely multi-valued and cannot be read out of it at all: `identityfile` lists every
default when none was set, so a last-wins map named whichever default came last as though it were a
choice. It runs debounced from `.task(id:)`, because a subprocess per keystroke is what the naive
version costs.

**The ssh escape hatch is split, not shell-quoted.** A host can carry extra `ssh` options typed as
they would be on a command line, plus `-X` behind a checkbox. `TmuxCommand.splitArguments` splits
them the way a shell would — quotes group, backslash escapes — and then they go straight to
`execve`: no expansion, no substitution, no shell, unlike `customCommand`, which really is handed
to `/bin/sh`. They are placed **before** tetmux's own `-o` options, and that ordering is the point:
ssh resolves each parameter to the *first* value it obtains, so options appended after ours would
be accepted and silently ignored.

**Tunnels are connection options, not a managed feature.** §1.2 rules out a port-forward management
UI, and there isn't one: forwards are `-L`/`-R`/`-D` arguments that live and die with the channel.
Incomplete rows are dropped rather than passed to ssh (a malformed `-L` makes ssh exit before tmux
starts), and `ExitOnForwardFailure` is deliberately left at ssh's default — a taken local port must
not kill the session. ssh's complaint lands in the pre-handshake transcript.

**OSC 52 clipboard writes are denied by default, and reads are never permitted (T5.6).**
`allowRemoteClipboardWrite` is a `HostConfig` field, not a `TerminalTheme` one, and that is the
point: trusting the machine on your desk to set your clipboard is a different decision from
trusting a shared box you ssh into, and an application-wide flag makes both at once. It is passed
down to the pane from the host rather than read from the theme, and a missing key in `hosts.json`
means denied — so a file written before the field existed gets the safe answer.

**A start directory and an initial command are properties of the host, not questions at creation
time.** `new-session` takes `-c` and a trailing `shell-command`, and both are fed from `HostConfig`
rather than from a dialog: New Session deliberately puts nothing between wanting a shell and having
one, which is why it has no name prompt either. tmux resolves both on its own side, so a directory
that only exists remotely and `srun --pty bash` both work — and that is also why there is no folder
picker, which could only ever browse this machine. Both values go through `TmuxCommand.singleLine`
as well as `quote`, like every other user value: the fields take pasted text, and a line break ends
the command before the closing quote and hands tmux the remainder to run. **The command goes
last**, after every option — tmux stops reading flags at the first word that is not one, so a `-c`
written after it is not an option at all and the directory silently does nothing. It is quoted
whole rather than split, because the far-side shell is what parses it. A command that exits takes
its window and then its session with it; that is `new-session <command>` for anybody, and
`remain-on-exit` is an option on the user's server rather than ours to set.

**Every command that opens something says where it opens, because tmux's defaults inherit and what
they inherit from is invisible.** With no `-c`, a session created over an attached channel takes
the *attached session's* directory, and a window or split takes its *own session's* — verified on
3.0 through 3.7b. Both defaults compound into the same failure: the first session on a host fixes
the directory for everything opened afterwards, and a `.app` launched from Finder has cwd `/`, so a
locally attached tetmux opened every shell it ever made in the root directory. Three rules, all in
`TmuxCommand`:

- A **session** starts at `sessionStartDirectory` — the host's start directory, else `#{HOME}` —
  on every path that can create one, `invocation`'s connect line included. That line used to be
  exempt, on the reasoning that a host reached for the first time is not being given a working
  directory — which made the *first* session the one that ignored the setting.
- A **tab or split** starts where an existing pane is, as a literal path that `paneCurrentPath`
  asked tmux for a round trip earlier — never as a format left for `-c` to expand, for the reason
  below. `splitPane` asks about the pane being split; `newWindow` about the pane it was opened from,
  or, when the caller has none to name, about the session, which answers for its current pane. That
  last case is the sidebar's `+`: it names a session the user is not looking at, whose panes are not
  the ones on screen.
- **`-c`'s format is expanded against the session's current pane, never against `-t`.** `spawn_pane`
  calls `format_single(item, sc->cwd, c, s, NULL, NULL)` and `format_defaults` fills those NULLs
  with `s->curw` and its active pane — so `split-window -t %0 -c '#{pane_current_path}'` lands
  wherever the session's *current* pane is, on 3.0, 3.2a, 3.3a, 3.4, 3.5 and 3.7b alike. The two
  panes agree while nothing has moved, which is why this held for so long. What broke it was a
  `new-window` immediately followed by a `split-window`: the tab is now current, its newborn shell
  has not yet claimed the pty's foreground process group, `pane_current_path` reads that through
  `tcgetpgrp` and expands to nothing, and tmux 3.0 and 3.2a answer an unusable `-c` by opening the
  pane in `$HOME` (3.3a and after join the empty string onto the client's cwd instead). It surfaced
  as a matrix failure on a loaded CI machine and passed on every idle one.
  `testANewTabAndASplitOpenWhereTheCurrentPaneIs` pins it without the race, by sending the tab to a
  second directory before splitting. `display-message -p -t` *does* scope to its target, which is
  what makes the round trip worth its RTT.
- **`~` is expanded here, not by tmux.** tmux does not expand a tilde in `-c`: it takes `~/work`
  literally, finds no such directory, and falls back to `$HOME` — a wrong answer that looks like a
  right one, which is how the SRD came to claim tildes worked. `#{HOME}` is a format, and an
  unrecognised format name is looked up in the *server's* environment — the only side that knows
  where home is on a remote host.

**The local host is persisted only as the difference from a baseline, and its editor is a different
editor.** `HostConfigStore.localBaseline` is what "localhost, unedited" means; `saveHosts` keeps
the `local` entry only when it differs — the same rule discovered `ssh-` hosts already had, and for
the same reason: its *existence* is not a stored fact. `loadHosts` takes only the fields that mean
something without a connection (start directory, clipboard policy) and never the whole record, so a
hand-edited `hosts.json` cannot flip `isLocal` or rename the host out of the places that look it
up. `HostEditorView` branches on `isLocal` rather than disabling fields: hostname, user, port,
password, tunnels and ssh options are all properties of a connection it does not make, and a form
four-fifths greyed out is a worse answer than a form with two rows in it.

**The copyable attach command is the one command line here that is not an invocation (F4.36).**
`TmuxCommand.attachCommandLine` answers what somebody would *type* to reach a session without
tetmux. Every other command string in that file is the opposite thing: they spawn `tmux -CC` and
speak to a parser, so a pasted one gives a screenful of `%output` and a terminal that cannot be
typed into. One rule sorts the arguments: what says how to **reach the host** is in — the
destination, a non-default port, `extraSshArguments` (which is where a `ProxyJump` lives) — and
what belongs to **this application's channel** is out: `ControlMaster` names tetmux's own socket,
the forwards are already bound by the connection being held open (a duplicate `-L` would fail), and
`-X` is about what the far side may draw. `-t` is not optional — ssh gives no tty when handed a
command, and tmux then refuses with `open terminal failed: not a terminal`. A host with a
`customCommand` is described by that wrapper, since an ssh line would describe a route nobody
takes.

Three further things. It is built from `HostConfig` and **not** from a live channel, which is most
of the point: a session found by discovery (F4.4) on a host nothing is attached to is exactly the
one somebody wants to reach from a shell. Quoting is `shellWord`, not `quote` —
`tmux attach -t 'work'` says "this name needed quoting" about a name that did not, and text that is
read before it is run has to look like something a person wrote; `~` and `=` are excluded from the
safe set although a shell takes them mid-word, because zsh expands both at the *start* of a word
and this word can be a session name. And `copyAttachCommand` takes its `NSPasteboard` as a
defaulted parameter for the same reason `AppModel` takes a directory: `.general` is the user's
clipboard, and a test asserting what was copied would take whatever they were carrying.

**⌥ held on either control asks the same question from a shell already on the host**
(`fromShellOnHost: true`), which is the common case for anybody keeping a terminal open there. It
takes off everything about *arriving* — the ssh line, and the `customCommand` wrapper too, since a
wrapper is a way of getting there rather than a way of attaching — leaving the local form. That
makes it a parameter on `attachCommandLine` rather than a trim applied above it: what counts as
reaching the host is that function's to know, and a wrapped host has no `ssh` in its line to
remove. Nothing offers the modifier on the local host, where the two lines are identical — a
modifier advertised where it does nothing is one nobody trusts anywhere.

**The flag is named for where the shell is, not for the route, so that its polarity is ⌥'s.** It
was `reachingHost` — true when ⌥ was *not* held — for five days, and every site reading the live
flag wrote `reachingHost: !OptionKey.isHeld`. That `!` was the whole correctness of the call, and
its absence reads perfectly plausibly: a later site writing `reachingHost: OptionKey.isHeld` to
"pass the modifier through" inverts the feature in silence. Nothing downstream could have caught
it — both strings are valid shell, and the UI call sites have no test, so an unmodified click would
simply have started copying the short line and the blame would have landed on the host config.
Renamed on 2026-08-11 with no behaviour change: the two live-flag sites now read
`fromShellOnHost: OptionKey.isHeld`, the menu's alternate items still name their own value as a
literal, and `attachCommandDependsOnReachingHost` became
`attachCommandDependsOnShellLocation`. **A Bool a modifier key supplies is named so the modifier
passes through unnegated** — the general rule this bought.

**⌥ and not ⌘, which is what this shipped as for a day.** ⌥ is macOS's variant modifier and ⌘ is its
*invoking* one — the key that turns a keystroke into a command, not the key that asks for another
reading of a click. Every alternate item a user has already met is keyed to ⌥ (Close All, Force
Quit, Copy as Pathname, ⌥-drag to copy), and ⌘ is spoken for twice on the exact surfaces this
control lives on: ⌘-click on a `List` row is discontiguous selection, and ⌘-click inside a pane
already activates a URL (`linkHighlightMode = .hoverWithModifier`, in the OSC 8 entry below). It
disagreed with this application's own vocabulary too, where ⌥ was already the entire answer to "the
other reading of this click" — ⌥ on a close button skips the confirmation, ⌥ on **New Session**
opens it in a window of its own — and the danger in those two lives in the control, not in the
modifier, so a benign clipboard variant does not dilute anything. Holding ⌘ over an open menu is a
live key-equivalent posture besides, where ⌥ held is inert. The switch was **net subtraction**:
`CommandKey` and both monitors' `isCommandHeld` went with it, `MenuModifierMonitor` is ⌥-only
again, and the app now reads exactly one modifier anywhere.

Both controls show the line the click would copy *before* the click, since a clipboard is not
somewhere a result can be checked — but **neither advertisement comes from a monitor**, because both monitor-driven versions
were checked against the running app on 2026-08-11 and both displayed wrongly, each for its own
AppKit reason. The menu's is a native **alternate item** (`.modifierKeyAlternate`, macOS 15+): a
`.contextMenu`'s `NSMenu` snapshots its items at open, so a title switched on the poll never
updated while the menu was up — and it was wrong *at* open too, since the poll only runs between
the tracking notifications and the content is built before tracking begins, so the modifier held
before the right-click still read as not held. AppKit swaps the two items itself while the menu tracks —
verified working against the running app the same day, and the swap carries the item's tooltip
with it, because the alternate is a different `NSMenuItem` with a `.help` of its own — and each
item's action names its own `fromShellOnHost` outright, so the words and the click cannot disagree
and nothing reads the live flags at click time; macOS 14, which has no alternate items
from SwiftUI, keeps flags-at-click behind a title that promises only the unmodified line. The
toolbar's tooltip names **both** lines in one modifier-independent sentence, because an AppKit
tooltip already on screen keeps the string it appeared with: the old text read the monitor
correctly and displayed its answer only at hover time, so following its own "hold ⌥" hint left the
ssh line showing while the click copied the short one. The live acknowledgement there is the
glyph, which fills while ⌥ is held (the accessibility label flips with it): the button redraws
mid-hover and its tooltip does not. **Checked twice, the second time because the first record never
said who had looked**: on 2026-08-11, against the ⌘ build at `d882fec`, tooltip up and the modifier
pressed under a stationary pointer — the words do not move. Anyone tempted to put a live string back
into a `.help` is re-opening a question that has been answered at the running app, which is the only
place it can be answered; that is why this sentence names the build it was answered on. That toolbar
click still takes `OptionKey.isHeld` at click time — the same division every other ⌥-modified control
makes.

## Sessions, tabs, and destructive actions

**Closing a tab unlinks; it must never kill (F4.9).** `AppModel.closeWindow` counts the sessions
the window is linked to and sends `unlink-window` when there is more than one, so the window leaves
this session and carries on in the others. tmux cannot do that for a window in its *only* session —
removing it there is destroying it, and `unlink-window` refuses outright with "window only linked
to one session" — so that case is the single path that reaches `kill-window`, behind a confirmation
that says why (F4.10, with no "don't ask again" escape). Both halves have a regression test,
including one asserting tmux still refuses; if that ever stops being true, the confirmation can go.
`%window-close` cannot distinguish the two, so it schedules a topology refresh rather than
guessing.

**A kill is not private, so the confirmation names who else is attached (F4.10).** `kill-session`
ends the session for every client attached to it, and a window killed because it was in one session
goes out from under all of them too. The dialog used to describe the panes and never the people, so
"close this stale-looking session" and "close the session a colleague is working in" read
identically. `HostState.clients` is `list-clients` kept in the model, and the *absence* of others
is stated just as plainly — that is what makes the section trustworthy when it says otherwise.
Three details:

- **The detach pass belongs to an attach and nothing else.** `Kind.listClients(reconcileStale:)`
  splits F4.17's orphan hunt from the plain re-read, or a refresh on every window rename would turn
  a known blast radius (two live tetmuxen detaching each other once) into a fight.
- **Our own channels are marked and excluded**, matched by tty against what each channel answered
  for `#{client_tty}` — the same "ours" F4.17 uses — or the dialog warns the user about themselves
  every time.
- **tmux does not know where a client connected from.** There is no `client_host`, `#{host}` is the
  *server's* hostname, and an ssh origin never enters tmux's model — so a client is named by unix
  user, tty and terminal type, and the sheet says so rather than letting `ada on /dev/ttys004` be
  read as a claim about which machine that is.

Freshness comes from `%client-detached` and `%client-session-changed` (verified on 3.7b;
`%client-detached` needs 3.2, so the topology refresh re-reads the list as well), plus one more
read on the way to raising the sheet — which the sheet picks up because it reads the model rather
than a snapshot. `client_user` is empty below 3.3 and the row keeps its tty.

**Moving a tab into a session that does not exist takes three commands, and the third is the
dangerous one.** tmux has no command for it: `move-window -t <unknown>:` is `can't find session` on
every version, and `new-session` cannot be handed an existing window. So
`SessionService.moveWindowToNewSession` sends `new-session -d -s <name> -n tetmux-new-session`,
then the `move-window`, then a `kill-window` of the placeholder **by that name** — never
`kill-window -a` (everything *except* the target), which is the tidier-looking command and destroys
the user's other tabs on the one occasion the move did not land. The three go out blind and in
order on the one channel, because control mode answers `new-session` with no id and waiting for a
topology refresh would leave the tab in limbo; a failed move leaves the placeholder as the
session's only window, so killing it takes the empty session with it and nothing is left behind.
The `new-session` deliberately has no `-A`: a name that is somehow taken must be a refusal rather
than an attach, or the kill lands in a session somebody is using. The kill alone is `.ignore` — §7
would otherwise put a second banner in front of somebody already reading why the move failed.
Unlike the moves beside it in the menu, this one *reveals* its destination, and the reveal names
the **window** as well as the session (`RevealRequest.windowId`): a session that exists but still
holds only the placeholder is a real snapshot, and selecting on it shows a stray shell and then a
window that has been killed.

**A linked window says so, because the link is what decides whether closing it is reversible.**
`AppModel.closeOutcome` is the single decision, and both the action and the tooltips ask it, so a
control cannot promise something the click will not do. That matters most with ⌥ held, which skips
the confirmation that would otherwise be the first time anyone is told this close is a kill. The
marker is a badge — a drawn chain link and a count — on the tab and the tree, and the words are in
`help` and the accessibility label, which names the other sessions rather than counting them
("also in beta" is checkable; "linked into 3 sessions" is a number to go and resolve). On a tab the
words are the *whole* answer: the strip shows one session's windows, so there is no second tab the
badge could point at. Nothing here is carried by hue, so `differentiateWithoutColor` needs no
branch.

**Hovering a linked row marks every row that window appears on — by accident of the key.** The
sidebar's `key(_:_:)` is host + *window*, not host + session + window, so the same linked window in
two sessions is one key — which is why both rows' close buttons have always appeared together. The
hover wash makes that explicable instead of mysterious, and it is drawn only for a linked window:
washing every hovered row would change how the whole tree behaves and would say nothing, since the
point is that one window is highlighted in two places. Selection is deliberately *not* the
channel — `isShowing` is session-qualified and means "this is what this macOS window is showing",
so marking the twins with it would assert something false.

**⌥ on a close or kill button skips the confirmation, and is read at click time.** The confirmation
exists because the user cannot be assumed to know that closing the last link of a window ends what
is running in it; holding ⌥ *is* saying so — what the modifier means on a destructive control
elsewhere in macOS — and it is what makes closing a run of them one click each rather than two. It
is not a "don't ask again": nothing is remembered, so the assertion is made again for the next
window. The flags come from `OptionKey.isHeld` inside the action, never from a monitor:
`ModifierKeyMonitor` and `MenuModifierMonitor` keep a *display* current and are allowed to be a
frame behind, and a button whose behaviour disagreed with its own icon for one frame is the least
explicable bug on this list. The two monitors are separate because their constraints are opposite —
a window's events reach a local `.flagsChanged` monitor, and a menu's do not (it tracks events in a
run loop of its own), which is why the menu bar polls instead. **Both report ⌥ and nothing else**,
which is the whole modifier vocabulary of this application: ⌥ means "the other reading of this
click" on every control that has one — skip the confirmation here, a window of its own on **New
Session**, the ssh half off F4.36's copy. Neither monitor samples ⌘, and there is no `CommandKey`:
the one thing that briefly read ⌘ was F4.36, and the same surfaces that made a ⌘ title impossible to
display also made it the wrong key to ask for (see the F4.36 entry above).

**A command the user asked for that fails has to say so (§7).** `%error` bodies used to reach only
the diagnostic logger, which only `--diagnose` installs — in the app, the command simply did not
happen and nothing said why. `PendingCommand.Kind.userCommand(_:)` labels the ones a person
initiated, and only those become `HostState.lastCommandFailure` and a banner. Internal commands
keep `.ignore`: a `resize-window` an old server refuses is ours to cope with, not a sentence to put
in front of somebody. An `%error` matching *no* pending command is still logged — the one case
where something has already gone wrong is the worst one to stay silent about.

## Copy mode and search

**Copy mode is a small documented vocabulary, not an emulation of tmux's key table.** Menu items
drive `send-keys -X <command>` — `-X` names the *action*, so it means the same thing whether the
user's `mode-keys` is emacs or vi, which a key name would not. The pane keeps working the way it
always did: a key typed into a pane in a mode still reaches tmux and is still looked up in the
user's own table (`Up` moves the copy cursor), so this adds a way in and a way out to the Mac's
pasteboard without taking anything away. Four things are load-bearing:

- **The mode has to be visible.** Control mode is never streamed a mode's overlay, so the pane is
  holding a `capture-pane` still frame that looks exactly like a dead process. Hence
  `TmuxPane.mode`, the status-bar label and the per-pane badge, all naming the mode rather than
  hinting at it — the name is what tells somebody to press `q`.
- **`%pane-mode-changed` says only that something changed** — not which mode, not whether it was
  entered or left — so it schedules a `list-panes`, where `#{pane_mode}` lives (identical on 3.0
  through 3.7b, so no version branch).
- **An action sent to a pane that is not in a mode is an `%error`**, and these are user commands,
  so §7 would put a banner in front of somebody whose pane merely left the mode before they
  clicked. Every action is guarded on the flag; Search is the deliberate exception — it *enters*
  copy mode itself, which is what makes searching tmux's history one action from a live shell, and
  also closes the race where the flag has not arrived yet.
- **Copy has to come back.** `copy-selection-and-cancel` fills a buffer on the *server*, which on a
  remote host is a machine the pasteboard has never heard of — so `show-buffer` reads it straight
  back and `tetmuxCore` returns the string for the UI to set (§2.4 again). A refusal returns `nil`
  and the pasteboard is left alone: replacing somebody's clipboard with an empty string over an
  empty selection is a silent loss.

**There are two searches, over two different bodies of text.** ⌘F is SwiftTerm's find bar and
searches what the *emulator* is holding — the local scrollback, capped by the theme and reset by
every repaint. ⌃⌘F is tmux's, and reaches the history the emulator never received, which is the
whole reason copy mode exists. The two controls look different deliberately: a sheet rather than a
bar, and one shot rather than incremental — each keystroke of an incremental field would be a
`search-backward` that moves the copy cursor, and the history would walk backwards while somebody
typed.

**⌘F is SwiftTerm's find bar, reached through `performTextFinderAction`.** It works only because
the Paste command replaces the `.pasteboard` menu group and *not* `.textEditing` — replacing the
latter wholesale is what unplugged Find in the first place, since AppKit puts Find in that group.

## Panes

**The pane's mouse behaviour is an `NSView` subclass, and its Paste is never SwiftTerm's.**
`PaneTerminalView` overrides `menu(for:)` and `otherMouseDown` because a SwiftUI gesture over a
`TerminalView` never sees an event — the same reason `PaneDivider` is an `NSView`. Three things are
load-bearing:

- The link under the click is captured when the menu is *built*, not when an item fires: the
  pointer has moved and the pane may have scrolled by then, so re-deriving it opens whatever is
  there now.
- The cell size for hit-testing comes from `getOptimalFrameSize() / grid`, which is SwiftTerm's own
  `cellDimension` read back. Mirroring the font arithmetic instead means resolving the backing
  scale factor exactly as SwiftTerm does — and getting that wrong moves the cell by a whole point
  and the hit column by several.
- Both the menu's Paste and middle-click go through `SessionService.paste`: SwiftTerm's `paste(_:)`
  inserts the clipboard as *keystrokes*, one `send-keys` per character — the path that wedges the
  channel and cannot carry a newline safely.

**Middle-click pastes the selection, not the clipboard** — this pane's if it has one, else the last
selection made in any pane (`PrimarySelection`), else the clipboard. It used to read the clipboard
first, on the reasoning that macOS has no primary selection: macOS does not, but the *terminal*
does, and every X11 terminal pastes it there. The old behaviour was not a missing feature but a
wrong paste into a shell — select a word, middle-click, and whatever was last ⌘C'd went in,
indistinguishably from the gesture working. `PaneTerminalView.selectionChanged` is the only seam
for recording the selection, since SwiftTerm's `selection` is internal while that method is `open`
and `getSelection()` is public; a *cleared* selection is deliberately not recorded, or the primary
would empty itself the moment you reached for the mouse. `allowsContextMenuPlugIns = false` keeps
AppKit from adding AutoFill and Look Up, which it offers because the view takes text input and
which mean nothing over a remote pane.

**A pane's accessibility value is the viewport, not the scrollback.** SwiftTerm's accessibility
service is an empty stub, so `PaneTerminalView` supplies the value itself, bounded by the grid — a
screen reader query must not cost more because a pane is holding a large history, and "read the
window" means the screen in any case. Not done: nothing posts `.valueChanged`, so output arriving
while VoiceOver is idle goes unannounced. Doing it right means diffing for new lines; re-reading
the whole screen on every chunk of a build log is worse than silence.

**Plain-text URLs are SwiftTerm's implicit matcher, not ours.** `linkReporting` defaults to
`.implicit` and `linkHighlightMode` to `.hoverWithModifier`, so ⌘-click already activates a URL
with no OSC 8 around it and arrives at `requestOpenLink` as a string. Nothing in tetmux would
notice if a SwiftTerm bump turned that off — hence `PaneLinkTests`. Both routes are held to one
scheme allowlist — `http`, `https`, `mailto`, `ftp` — because pane contents are remote text and
`NSWorkspace.open` launches whatever application claimed a scheme.

**Press-and-hold is a replacement, not a composition, and the base character has already been
sent.** Holding `n` for `ñ` looks like the dead-key path and is nothing like it: no text is ever
marked. Captured from a logging `NSTextInputClient`: macOS commits the base character at once
(`insertText 'n' replacementRange={NSNotFound, 0}`), emits *no* `insertText` for the repeat events
that open the popup, and delivers the accent as a second commit whose range covers the first
(`insertText 'ñ' replacementRange={0, 1}`). SwiftTerm discards that range, so both characters
reached the pane and the user typed `nñ`. `ComposingTerminalView` honours the replacement the only
way a terminal can: it sends `0x7f` — the byte SwiftTerm already sends for the Delete key, so the
pane sees the same erase it would if the character had been taken back by hand — for each character
being replaced, ahead of the new text. Three details:

- **There is no way to hold the base character back.** Nothing distinguishes the first
  `insertText` of a long press from an ordinary keystroke, so deferring would mean deferring every
  keystroke — the whole of P6.1's budget spent on this.
- Only the range's **length** is honoured; its location is ignored. The location indexes whatever
  the client called its selection, and SwiftTerm's is a terminal coordinate (`row × cols + col`)
  rather than an offset into anything we hold.
- It is a **base class** rather than a method on `PaneTerminalView`, because §4.6's passthrough
  surface is a `TerminalView` with the same input system in front of it and had the identical bug.

**A tab's terminal views are never rebuilt, so a bell has to reach the app, not the view.** Panes
beep through `NSSound.beep()`, and when the app is not frontmost `BellNotifier` also posts a
`UserNotifications` banner (F4.31), coalesced to one per 10 s with an "and N more" body —
`yes | ring` would otherwise bury Notification Center. Authorisation is asked for on the first bell
rather than at launch, and a refusal is not retried. `UNUserNotificationCenter.current()` **traps**
in a process with no bundle identifier — which is exactly `swift run tetmux` — hence the
availability guard.

**Activity notifications are opt-in per window; the bell is not, and the asymmetry is the point.**
A bell is a program deliberately asking for attention. Activity is only "output arrived in a window
nobody is reading" — for most windows that is a prompt redrawing, so reported for every window it
would be constant and worthless, while reported for the one running a long remote job that prints
and never rings, it is the whole feature. `AppModel.watchedWindows` is a set of host-qualified
window ids (tmux numbers windows per server, so `@1` exists on every host at once), toggled from
the one place the tab menu and the tree menu already share — `WindowSessionMenus`, which keeps the
two from drifting without needing a `RowSubject` case of its own. Watches are §4.3 view state, so
they persist in `workspace.json`, which grew an **envelope** (`{windows, watchedWindows}`) around
what used to be a bare array; `WorkspaceStore.decode` still reads the old shape, because discarding
somebody's window arrangement is a poor way to introduce a feature. `AppModel.newlyActive` is
static and pure because it is the half that is silently wrong: `hasActivity` stays true until the
window is read, so reporting the *value* rather than the *transition* would re-fire on every
topology snapshot for the rest of the afternoon — and a window seen for the first time has no
previous value, so attaching to a server whose watched window is already active is deliberately not
an event. `NotificationPolicy` is the on/off pair, in `UserDefaults` beside the theme; it is
mirrored onto `BellNotifier.shared` because a pane surface has no `AppModel` to ask.

**A colour scheme is pane *content* only, and System is the absence of one.** §7 keeps the chrome
compositing from `controlAccentColor` and hierarchical styles so it follows the system appearance;
a tab bar that changed colour with the terminal scheme would be an application pretending to be a
terminal. Four things are load-bearing:

- **The System scheme carries no palette.** It calls `configureNativeColors`, which reads
  `NSColor.textColor`/`.textBackgroundColor` and therefore follows light and dark *while the app
  runs*; copying today's values into fixed ones would look right until the user switched
  appearance.
- **`installColors` goes first**, because it resets the view's 256-entry colour cache, and setting
  the foreground and background before it would have them thrown away. It is guarded on an actual
  change (`Coordinator.appliedSchemeId`), since a repaint of every pane on every `%layout-change`
  is what an unguarded version costs.
- **The pane tree's background follows the scheme too.** An unfocused pane is dimmed with
  `opacity`, so whatever is behind it is what it fades toward — and a dark scheme fading toward
  the system's white is a grey wash nobody chose. (`ContrastPolicy`'s exemption still applies on
  top: at increased contrast the dimming stops entirely.)
- **§4.6's passthrough surface takes the scheme as well**, because it is one tmux client painting
  itself, and a fallback in different colours would look like somebody else's application.

The theme stores the scheme's *id*, not the scheme: an unknown id falls back to System, which is
what a downgrade or a hand-edited preference produces.

**The scrollback setting shows what it costs, because the cost is the whole of the choice.**
Scrollback is the dominant term in this application's memory by a distance — a cell is
`MemoryLayout<CharData>.stride` bytes (24, read from SwiftTerm rather than written down, so a
dependency bump moves with it), so 10 000 lines of an 80-column pane is ~18 MB, and the picker's
largest option is ten times that *per pane*. `TerminalTheme.estimatedScrollbackBytesPerPane` feeds
the figure beside the picker, and it is deliberately an estimate of cell data at a nominal width:
allocator rounding, the per-line object and the alternate buffer are real, unmodelled, and why the
measured figure is higher. Its job is to make 1 000 versus 100 000 legible at the moment somebody
chooses, not to predict a footprint. `PaneMemoryTests` pins the arithmetic *and* the cell size,
because P6.7's amended bound is derived from both and a struct layout in a dependency changes
without a compile error.

**The terminal's appearance is one `TerminalTheme` in `UserDefaults`, and changing it costs a round
trip per pane.** The `Settings` scene sets font family, size, ligatures (T5.8) and scrollback; the
theme lives on `AppModel` with a `didSet` that persists it, and reaches panes as a value passed
down the view tree. Font changes are not free: the cell size derives from the font and the grid
derives from the cell size, so every pane on screen re-measures and re-asks tmux. Scrollback is
applied to live panes with `changeScrollback` rather than only at creation — SwiftTerm's default is
500 lines, which is not a choice anyone made.

**Keystrokes coalesce on the trailing edge of the window and are written on the leading one — the
difference was two thirds of P6.1's budget.** Every `send-keys` under control mode is a
`%begin`/`%end` round trip, so a burst has to become one command (§3.2, P6.4). But the first
implementation started a task that slept `keyFlushInterval` (8 ms) and *then* wrote, which made a
keystroke with nothing to coalesce with pay the full interval for a batch of one — that is every
keystroke at typing speed. Measured p50 keypress → echo was 9.76 ms, of which 8 was the timer, and
P6.1's 12 ms was missed at 24.43 ms p95. Writing immediately when the window has already elapsed,
and coalescing whatever arrives during the one that follows, took the round trip's p95 from
19.72 ms to 1.72 and the whole figure to 11.54. Two things keep it honest: the scheduled flush
waits out the **remainder** of the window rather than a fresh interval, or a steady typist pushes
it further away with every key and starves it; and a flush that finds an empty queue must **not**
start a new window, since nothing was written and the next keystroke would wait for a send that
never happened. The command rate under sustained typing is unchanged — one per interval — and that
is asserted, not assumed: `testABurstOfKeystrokesStillLeavesAsOneCommand` reads the count *before*
waiting, because after the wait the two designs are indistinguishable.

## Windows, menus, and commands

**Anything that belongs to a window lives on `WindowState`, not `AppModel`.** Selection, focused
pane, and every sheet the user can raise are per macOS window. Sharing them on the model produced
two bugs with one cause: clicking a session in one window retargeted all of them, and one
`.sheet(item:)` bound to shared state opened the same dialog once per open window. `RootView` owns
one `WindowState` per window; the since-deleted detached window had a hand-rolled version of
exactly these fields first, and `WindowState` is that generalised, so the main window stopped being
the special case. A `WindowGroup` could always open several windows — shared state was the only
thing that made doing so useless.

**Menu commands act on `AppModel.activeScope`, not on any one window's selection.** Menus are
application-wide, so ⌘T with any window in front must open a tmux window in *that* window's
session. Every window publishes its scope via `focus(_:)` when it becomes key, main windows
included; there is no privileged window to fall back to now that there can be several.
`activeScope` is never cleared, because a menu can be used while no window is key, and the last one
to have focus beats nothing. `activeWindowState` is the companion for commands that open a *sheet*
rather than act — it says where to ask — and is weak, so a closed window is not kept alive by
having once been key.

**A sheet nobody asked for is presented by exactly one window.** ssh prompts arrive from the
channel and belong to a host, not a window, so `presentsHostLevelSheets` picks the head of
`windowOrder` and the others bind `.constant(nil)`. Registration order rather than focus, so the
choice does not move mid-typing; closing that window promotes the next, because nothing able to
show a prompt means a host stuck at "Connecting…" forever.

**A tmux window is a "Tab" in every user-facing string, and "Window" means the macOS window and
nothing else.** ⌘N is the macOS window and ⌘T the tab, which is what those chords mean in every
other Mac application. The vocabulary drifted twice before it was pinned, and both failures read as
correct in isolation: the qualifier was applied to some commands and not others — "New tmux Window"
and "Next tmux Window" beside a bare "Close Window…" and "Rename Window…" for the same object —
and, worse, **"New Window" meant the macOS window in the menu bar and the tmux window in the
sidebar's session context menu**: the same two words for opposite objects, two clicks apart. Naming
the thing the user is looking at removes the qualifier everywhere rather than making it consistent.
`testATmuxWindowIsCalledATabInEveryCommandTitle` pins it, because this is only visible with two
surfaces side by side and so survives any amount of care taken one file at a time. "New Tab" and
"Close Tab" **are** titles AppKit manages — but only under automatic window tabbing, which is off
here, and that was checked against the running app rather than assumed: File carries one "New Tab"
at ⌘T, Session one "Close Tab…" at ⇧⌘W, both enabled, and AppKit injects no tab items of its own.
That check is the thing to repeat if `allowsAutomaticWindowTabbing` ever changes; the earlier note
here recorded the hazard as a reason the name was unavailable, which measurement did not support.
`NewAppWindowButton` exists because `openWindow` is an `@Environment` action and `Commands` has no
environment to read one from.

**The ⌘W family follows Safari and Terminal rather than blast radius**: ⌘W closes the tab, ⇧⌘W the
macOS window, ⌃⌘W the pane. The old ordering put the least-destructive action on the easiest chord
— a real argument that lost to being alone in the inversion, and F4.10's confirmation already
stands between ⌘W and anything irreversible. Two AppKit facts make this work, and neither is
optional. `CommandGroup(replacing: .saveItem)` removes AppKit's own `Close`, because it owns ⌘W and
the File menu is searched before ours; mutating the `NSMenuItem` does not hold, since SwiftUI
rebuilds that menu and restores the chord, after which the duplicate costs it its key character and
the window has no close chord at all. And **⌥⌘W was never available**: it belongs to `Close All`,
the automatic alternate of `Close`, which is why the pane's binding sat there for so long with a
modifier mask and no key character — advertised in the Keys tab and the README, firing Close All.
Replacing the group takes `Close All` out too, which is what frees ⌥⌘W. Anything added to this
family is checked against the **running** menu bar; the AX attributes are what tell you a chord was
silently dropped. ⌥⌘[ / ⌥⌘] move between panes in the **rendered** tree, so zoom is respected.

**A dropped tab lands on the side the drag came from, and the marker has to agree.** The rule every
tab bar has: the dragged tab takes the target's position and everything between shifts by one — so
a rightward drag inserts *after* the target and a leftward one *before* it.
`AppModel.dropDestination` is that arithmetic, static and pure because it is the part that can be
wrong with nothing to say so: get it backwards and a drag by one position does nothing at all.
`isTargeted` reports only that *something* is over a tab, never what, so the strip shares a
`draggingWindowId` — otherwise the insertion marker would be drawn on the leading edge always, and
would lie for every rightward drag. The payload is plain text rather than a declared `UTType`,
because an exported type needs an `Info.plist` to be declared in and `swift run` has no bundle;
every drop is checked against the session's own window ids, so a stray text drag matches nothing.

**A window can be asked for but not opened — and not addressed either.** `AppModel.requestedWindow`
records the request and any open window performs it, via `claimWindowRequest()`: *every* window
observes it, and a plain nil check on the delivered value opens one window per window already on
screen. What the new window should show travels separately through `consumeSeed()`, taken once by
the next window to appear — `WindowGroup(id:for:)` would key windows on that value and bring the
existing one forward instead of making a second, which is right for "show me this session" and
wrong for ⌘N. And SwiftUI cannot bring a *particular* window forward at all, so `WindowAccessor`
captures each window's `NSWindow` — the only way `showSession` can raise the right one.

**The Dock menu is three items, and two of them are the point.** It is the app's only surface while
it has no window and is not frontmost, and it used to offer New Window alone — which reconciles to
the first host's *active* session and window, i.e. very often the window already on screen, so the
one thing the Dock could do was make a second view of what you were already looking at. **New
Window** seeds `sidebar: .shown`: someone reaching for the Dock has nothing in front of them and
needs a window to navigate *from*, and `.automatic` is AppKit deciding rather than an instruction.
**⌘N is a different rule, not an inconsistency**: `openNewAppWindowFromMenu` takes after the window
it was pressed in — collapsed from a collapsed one, showing from a showing one — because a second
window of what you are looking at should look like what you are looking at, while the Dock has no
window to take after. What neither may do is send no seed, which is what ⌘N used to do: the tree
then falls to `.automatic` and comes up collapsed whatever the asking window looked like. Both read
`sidebarVisibility != .detailOnly`, the rule `workspace.json` already stores `sidebarShown` by —
`.automatic` is a tree that is *showing*, and `== .all` would hide one the user can see. **New
Local Session** and **New Remote Session ▸ host** create a session and open a window onto it with
the tree collapsed. Neither can simply open a window — control mode's `new-session` answers with no
id, so the window can only be opened once the topology says what it should show, which is exactly
what `RevealRequest` exists for; they go through `createSessionWithDefaultName(preferNewWindow:)`
like the menu bar's ⌥. The menu is rebuilt on every click because AppKit asks each time and the
host list is live. An item with nothing to act on gets `action: nil` rather than
`isEnabled = false` — the menu auto-enables, so a cleared flag is overwritten at display time,
while an item with no action is greyed out for us.

**With every window closed there is nobody to claim a request, so the model performs it itself.**
`requestedWindow` is only ever observed from inside a window, and the app deliberately outlives its
last one (`applicationShouldTerminateAfterLastWindowClosed` is `false`, because the menu bar extra
is the point of staying resident) — so picking a session from the tray did nothing at all, ⌥ or no
⌥, and left the request set for the next ⌘N to inherit. `AppModel.openAppWindow` is an
`OpenWindowAction` handed over by a view, since only a view can read one; it stays valid after that
view is gone because it resolves against the scene graph. `openWindow(_:)` uses it only when
`openWindows` is empty — calling it while a window is watching would honour the request twice. The
menu bar re-adopts it on every use, being the one view still around when the last window closes,
and the Dock menu (AppKit's, built outside any scene) reaches it through the app delegate. **New
Session** with nothing open needs the same treatment one layer up: `createSession` queues a reveal
that *opens* a window rather than none at all, or tmux gets a session nobody is ever shown.

**Staying resident means ⌘Q is the ordinary way out, and it must undo what a disconnect undoes.**
`window-size manual` is set on the user's sessions; the delegate used to implement only
`applicationShouldTerminateAfterLastWindowClosed`, so quitting left every session no longer
following its terminal, for the next plain `tmux attach` to find.

**Showing a session prefers the window already showing it.** `showSession` tries, in order: the
window already displaying that session (brought forward), then a new window if asked for one, then
the offered fallback — the clicked window for a sidebar double-click, the last-used one for the
menu bar extra — then a new window because nothing was open. Retargeting some other window to a
session that is already on screen both surprises the user and discards what that window was
showing.

**There is one kind of window.** "Open in New Window" opens an ordinary window seeded to a session
with the sidebar collapsed — not the separate `DetachedScene` type it used to. That had its own
view, a reduced feature set, and a button to convert itself into a real window: three things to
maintain for a result that wanted to be a normal window all along.

**The keymap has exactly one event monitor, and it exists because the ordinary route cannot be
escaped.** Every binding is a SwiftUI `keyboardShortcut` on a menu item, which AppKit resolves in
`performKeyEquivalent` before any view is offered the event — so no view-level hook could ever let
⌘K through to a pane running fzf. `KeyEventMonitor` is a local `NSEvent` monitor, which runs
earlier still (`NSApplication.sendEvent` calls monitors before dispatching key equivalents), and
F4.21's armed chord is delivered to the pane's `keyDown` **directly** rather than passed on —
passing it on hands it straight back to the menu, which is the interception being escaped. It asks
`KeymapPolicy.shortcut(for:literalEscapeActive:)` rather than matching anything itself, so F4.22's
single policy module survives the new surface. New key handling belongs in the policy, not here.

**A rebind must have ⌘ in it, and a taken chord is refused rather than resolved.** The whole
default set lives in `Cmd` space so that everything else reaches the pane untouched — that is the
entire content of F4.20's promise about `Ctrl+K` — so `KeymapPolicy.isBindable` rejects anything
without ⌘, in the recorder and again when a hand-edited `settings.json` is applied. Two commands on
one chord is not resolvable either: `shortcut(for:)` breaks the tie by the enum case's spelling, so
one of them silently stops working. The chord recorder answers **`performKeyEquivalent`**, not
`keyDown`, or the menu takes every ⌘ chord before the field sees it. And `KeymapPolicy.overrides`
builds its map with `updateValue`: assigning `nil` through a `[String: String?]` subscript
*removes* the key, which would make a deliberately unbound shortcut indistinguishable from an
untouched one and bring its default back on the next launch.

**A key with no glyph is named, not uppercased.** `KeyBinding` holds a `Character`, and rendering
it by uppercasing gave the space key a chord ending in nothing and an arrow key a private-use
codepoint the font draws as a box — both recordable today, so both reachable. `namedKeys` maps them
to what macOS calls them: the word for space (System Settings shows Spotlight as `⌘Space`) and the
symbol for the rest, the way the menus do. The *storage* name is separate and is for
`settings.json`, which §2.3 chose so the file can be read by hand — `ctrl+cmd+space` says what it
means, and a literal trailing space would not survive anyone looking at it. Names and one-character
keys cannot collide, because every name is longer than one character. What the table cannot vouch
for is that the chord still *matches*, so that has its own test: `charactersIgnoringModifiers` for
⌃⌘Space really is `" "`, which is the character the binding holds.

**The menu bar extra says what ⌥ would do, by polling.** `MenuBarExtra` hands its content no event
and SwiftUI has no `isAlternate`, so the items' icons are swapped by hand while ⌥ is down —
otherwise the modifier is invisible until after the click that used it. It cannot be watched with
an event monitor: a menu tracks events in a run loop of its own where a local monitor sees nothing,
and a global monitor for a keyboard event needs Accessibility, which this app needs for nothing
else. `MenuModifierMonitor` therefore reads the hardware flags on a `Timer` added to the **common**
run-loop modes — the default mode never fires during menu tracking — and only between `NSMenu`'s
begin/end-tracking notifications, so nothing wakes up while no menu is open. The *action* still
reads `NSEvent.modifierFlags` at click time; a 20 Hz poll is for display and can be a frame behind.

**A window's label is its name only when the user chose it.** `#{automatic-rename}` is how tmux
says which: `1` while it is naming the window after the running command, `0` once someone has
renamed it. There is no `#{window_...}` variable for this — the option name itself is the format.
Otherwise the label is what is *running*, and for a split window that means every pane, because
tmux's automatic name follows whichever pane is current: a split window's label used to change as
the user moved between panes, and two split windows read identically whenever their active panes
matched. `displayLabel` lives on `TmuxWindow` so the sidebar and the tab cannot disagree about what
a window is called.

**Creating something shows it, and that takes a round trip.** Control mode's `new-session` and
`new-window` answer with no id, so the thing created is not selectable until the topology refresh
brings it back. `AppModel` records the intent and satisfies it on the next snapshot — a session by
*name*, since tmux allocates the `$id`, and a window by *not having been there before*, since
selecting whichever window tmux made active would hand the selection to a window opened elsewhere
in the meantime. Requests hold the asking window weakly and expire after 15 s: one kept
indefinitely would eventually match an unrelated session of the same name and move somebody's
window. ⌥ on the menu bar's **New Session** means what ⌥ means on a session row — a window of its
own — and has to travel the same way rather than opening one at the click: there is no id to seed a
window with until tmux answers. So the reveal request carries the intent, opens the window when the
session arrives, and is the one kind of reveal that does *not* need the asking window to still be
there.

**Topology refreshes and pane refreshes are different commands and need different task slots.**
Sharing one meant a `%window-add` arriving just after a `%window-renamed` ran only `list-panes`, so
a window created elsewhere kept its placeholder name and wrong session until something unrelated
refreshed. Automatic renames fire constantly, so this was hit often.

**tmux ids collide across hosts.** Sessions and windows are numbered per *server*, so `$0` and `@1`
exist on every host at once — and that is the common case, not the odd one, because the ordinary
way to reach a second host is to ssh into it, and its tmux starts numbering from zero exactly like
the first. Anything keyed on a tmux id alone therefore has to carry the host too:
`WindowState.isShowing` for row selection, and the sidebar's `key(_:_:)` for hover. Without it, a
window row lit up on every connected host simultaneously. The commands behind the row buttons were
always host-qualified and were never affected; only the display was.

## The launcher and the workspace

**Workspace restoration is `pendingRestore` on each window, not `@SceneStorage`.** What has to come
back is a relationship between a macOS window and a tmux session, and that session does not exist
until the host has connected and answered `list-sessions` — a round trip after the window is
already on screen, which is exactly what scene storage cannot express. So `workspace.json` is read
once at launch, each window holds its entry, and `reconcile` retries it on every snapshot. The
entry carries **both** an id and a name because they answer different questions: `$3` is exact and
is what a still-running server is still using (the common case — quitting tetmux does not stop
tmux), while the name is what survives a server restart, where matching a reissued id would land on
a stranger's session. There is no expiry — a window restored onto a remote host waits there until
someone connects it — and only an explicit `select` cancels one. An *unresolved* restore is written
back unchanged, or quitting before that host was ever reached would replace the session the user
wants with whatever the reconciler picked. Restoration is resolved in `AppModel.apply` and not only
in each window's `onChange`, because `syncDisplayedSessions` reads the selections in the same pass
and a SwiftUI `onChange` is not guaranteed to have run by then: a restored session otherwise got no
tmux client until something unrelated changed the topology — panes on screen and frozen.

**The launcher's list is ranked by use, and the key is what makes that safe.** F4.25's recency is
an *order* in `workspace.json` — most recent first, capped at 50 — rather than timestamps: ranking
needs to know which came first and nothing else, and a wall clock in a file that outlives sleep and
a timezone change buys nothing. A `RecentTarget` is host-qualified for the usual reason (tmux
numbers per server, so `@1` is on every host at once), and it keys a **session by name and a window
by id** — not an inconsistency: a session found by discovery has no id at all (the probe answers
names), while a window's *name* is whatever is running in it whenever `automatic-rename` is on.
Both go stale on a server restart, and that is accepted here where it would not be in
`WorkspaceWindow`: a stale entry costs one row its place in a list, not a window its session. Uses
are recorded in `select` — every deliberate navigation, not only the launcher's own rows, or the
thing you left thirty seconds ago by any other route sits at the bottom — and deliberately **not**
in `connect`, which the local host calls on itself at launch. Once a query is typed, the fuzzy
score decides and recency is only the tie-break — which has to be written out: `sorted(by:)` is not
stable, so equal scores are otherwise not merely unranked but unrepeatable.

**…and its window row on an unreachable host connects first, through `pendingRestore`.** That row
has always been subtitled "(will connect)" and always called a plain `select`, which connects
nothing — the one row whose words and click disagreed. The selection cannot be made at the click:
the window is a fact from the last time that host answered, and there is no channel to select it
on. So `showWhenAvailable` parks the target, `connect` runs, and the ordinary restore path lands
it. Two things are load-bearing. It is **not** a `RevealRequest`, which expires after 15 s — the
handshake watchdog allows 45, so a slow ssh would drop the pick silently; `pendingRestore` has no
expiry for exactly this reason, and resolves by id and then by name, which is the right rule for a
topology as old as the disconnection. And it connects **targetlessly** rather than attaching by the
remembered session name the way `attachDiscoveredSession` does: that name may be gone, and
`attach-session -t <gone>` is `%error`, `%exit` — which the exit handler reads as "this server has
nothing left", leaving the host disconnected saying nothing. The row's mark is
`LauncherItem.connectsFirst`, which used to be `isAvailable` and did not mean this: it was set on
window rows alone, so the recession excused a row that did not work rather than stating a fact
about the host, while a session row on the same host was drawn at full strength and did connect.

**…and picking one opens the tree onto it**, through `sessionsToExpand` — the same channel a
session created from the sidebar already used. A launcher result is reached without touching the
tree, so without this the row highlights inside a collapsed session: the selection invisible in the
one view whose job is to show it. It is deliberately *not* gated on the sidebar being open — the
flag is consumed whenever the tree next runs, so a collapsed one simply finds the session already
open when it is shown. When the pick had to connect first, the expansion has to wait with it,
because the session id the row was built from predates the disconnection and a restarted server has
reissued it — hence `expandWhenRestored`, which is keyed by *window* and lives on `AppModel` rather
than beside the target: `pendingRestore` is written to `workspace.json` verbatim, and the workspace
restore that shares that field must not expand anything, or every launch would open a node per
restored window.

## Accessibility and motion

**Reduce Motion is honoured at all three animation sites** — the launcher's scroll, the tab
strip's scroll-to-selection, and the sidebar's row-action reveal — each keeping the outcome and
dropping the movement. New animation belongs behind the same check.

**Increase Contrast is `ContrastPolicy`, and new sites ask it rather than deciding for
themselves.** Views read `@Environment(\.colorSchemeContrast)` and pass it in; the alternative is a
`contrast == .increased ? a : b` at a dozen sites with a dozen sets of numbers, drifting until a
selected row and a selected tab disagree about how selected they look. Every rule is the same kind
of rule — a signal carried by a faint wash becomes one carried by an obvious one — so nothing
changes shape, appears, or moves: the user asked to see the application, not for a different one.
The one that is not simple amplification is the pane: an unfocused pane stops being dimmed *at
all*, because dimming a pane is dimming terminal text, and the frame around the focused one takes
over the job at full accent saturation and double the width. The tests assert **direction**, not
numbers — the failure they exist to catch is a later site that takes the standard value in both
branches, which leaves the preference switched on and doing nothing.

**`differentiateWithoutColor` has no policy type, deliberately.** Unlike contrast there are no
shared numbers to keep in step — the replacement channel is necessarily different at every site, a
word here and a filled chip there — so each site reads
`@Environment(\.accessibilityDifferentiateWithoutColor)` and answers for itself. Three sites, and
the interesting part is which ones needed anything. The **RTT dot** did: the number beside it is
the measurement and the hue is the judgement, so with colour gone "120 ms" answers nothing unless
you know the thresholds; it gains `· good`/`· fair`/`· slow`, the same answer the sidebar already
gives in words one panel up. The **⌥-armed close buttons** did: red is the entire content of "this
click will not stop to ask". The sidebar's **connection rail** did *not* — `hostStatusLabel`
already puts every state but `.connected` into words on the row the rail belongs to, and
`.connected` is the one with no label, so the states are already distinct without hue. Checking
that rather than decorating it is the point. One measured trap: doubling the armed glyph's rule
takes an 11×11 mark from 45 inked pixels to 65 offscreen and **still does not read** on a row where
it is drawn in `.secondary` — so the signal is a filled chip behind the button, and the weight is
only its companion.
