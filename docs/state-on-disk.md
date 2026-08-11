# State on disk

Split out of `CLAUDE.md`. What is persisted where, and what each file's failure handling is.

- `~/Library/Application Support/tetmux/hosts.json` — host list. A decode failure renames the file to
  `hosts.json.corrupt-<timestamp>` and surfaces `loadFailure` rather than returning an empty list:
  both halves used to be `try?`, so a mangled file silently became "no hosts" and the first edit wrote
  one host over the rest. An empty file is explicitly not corruption.
- Hosts discovered from `~/.ssh/config` keep their `ssh-` ids and are re-derived each launch, so an
  unedited one is deliberately **not** persisted — a stale entry would outlive the stanza. An *edited*
  one is persisted as the difference from what discovery produces, and only while its `Host` block
  still exists. Before that, a forward or ssh option added to a discovered host worked all session and
  vanished on relaunch, while the Keychain flag it wrote survived and the two then disagreed.
- `~/Library/Application Support/tetmux/workspace.json` — `windows`, one entry per macOS window: host,
  session (id *and* name), tmux window, whether the tree was showing, and the frame; plus
  `watchedWindows`, F4.31's watches, and `recents`, F4.25's ranking — both of which belong to no
  window and so had nowhere else to go. §4.3's
  view state and nothing else — tmux is the persistence layer for everything in a pane. Written
  debounced, on window close, and synchronously from `applicationShouldTerminate`, which is the usual
  way this app is closed. An empty window list is never written: the app outlives its last window, so
  closing them all and quitting from the menu bar would otherwise erase a workspace nobody meant to
  discard. The file used to be the bare array of windows and is still read in that shape.
- `~/Library/Application Support/tetmux/settings.json` — the keymap, as the difference from the
  defaults. A `null` is a shortcut deliberately unbound. The terminal's *appearance* deliberately
  stays in `UserDefaults` below: font and scrollback are ordinary application preferences the system
  already has a place for, while a keymap is a document somebody may want to read, diff, or copy to
  another Mac — which is §2.3's whole argument for JSON.
- `~/Library/Preferences` (`UserDefaults`) — `terminal.fontName`, `fontSize`, `ligatures`,
  `scrollbackLines`, `colorScheme`, and F4.31's `notifications.bells` / `notifications.activity`. Preferences the
  system already has a place for; the *watches* those last two govern are view state and live in
  `workspace.json`.
- `~/Library/Caches/tetmux/cm-%C` — ssh `ControlMaster` socket. Kept short on purpose: unix socket
  paths cap at 104 bytes and Application Support plus ssh's 40-char hash runs close to it.
- Login Keychain — per-host passwords, opt-in, as `kSecClassInternetPassword` with protocol ssh keyed
  by server/account/port. `hosts.json` records only *that* a password is expected, never the password;
  `HostConfigStoreTests` asserts no new secret-shaped field appears in it. Removing a host, or turning
  storage off in the editor, deletes the item — an orphaned credential the user believes they deleted
  is worse than none.

ssh remains responsible for authentication: keys are tried first and the Keychain only answers a prompt
that ssh actually raised. Key passphrases are never stored per host — they belong to the key, and
ssh-agent already handles them.
