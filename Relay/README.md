# tetmux-relay

A server that holds tetmux's control-mode channels and serves them to a browser, with a phone as the
intended client. The phone never holds a tmux connection itself, only a WebSocket it can drop and
re-open, because iOS kills a backgrounded page's sockets. The channels live here, so nothing upstream
notices when that happens.

It is `tetmuxCore` and `tetmuxPolicy` (the same channel, correlation, geometry and close logic as
the macOS app) with Hummingbird in front. It is a separate package so the app never pulls in
SwiftNIO. Status and the remaining steps are in the web-client entry in `../TODO.md`.

## Run

```bash
cd Relay
swift build -c release
.build/release/tetmux-relay                         # local tmux, 127.0.0.1:8080
.build/release/tetmux-relay --host build-box        # connect this one at startup instead
.build/release/tetmux-relay --host a --host b       # or several
.build/release/tetmux-relay --bind 100.x.y.z --port 8080 --session work
```

Every host from `hosts.json` and `~/.ssh/config` is offered in the page's picker. `--host` only
decides which are connected at startup (the local host when none is given). The others connect the
first time someone picks them.

The page shows one pane at a time. The top row of tabs lists the session's windows, with `+` for a
new one. A split window gets a second row listing its panes, and the pane on screen is zoomed in
tmux so it fills the phone. The relay unzooms the window when the view moves away, but only if it
did the zooming.

- **The host button** (top left) opens the list of hosts and their sessions. From there you can
  start a session, connect a host, answer what ssh is asking (a password, a host key), or add a
  host as `user@host` plus an optional port. Added hosts are saved to the server's `hosts.json`.
- **`⋯`** acts on what is on screen: split right or down, a new window, rename, close the pane,
  close the window, and the text size. Closing a window asks first when it would end what is
  running in it, with the same sentence the Mac app uses. A window that is also in another session
  is only removed from this one, without asking.

`--config <dir>` reads and writes `hosts.json` there instead of the default location. Use it when
testing on a Mac, where the default is the app's own file.

It prints the URL to open, with an access token in it. Pass `--token`, or set
`TETMUX_RELAY_TOKEN`, to keep the same token across restarts, so a home-screen bookmark keeps
working. `TETMUX_RELAY_DEBUG=1` prints the control-mode traffic to stderr, the same way
`tetmux --diagnose` does.

Requirements:

- **Swift 6.2 or newer**, for Hummingbird. The relay builds and runs on Linux (checked in
  `swift:6.2`).
- **Hosts** come from `hosts.json` plus `~/.ssh/config`. On Linux, `hosts.json` lives in
  `~/.local/share/tetmux/`. ssh runs as the relay's user, with that user's keys and `known_hosts`.
  A password or host-key prompt is answered from the hosts sheet. Nothing is stored: there is no
  Keychain on Linux, so a password host asks again on every connect, and key auth is the easier path.
- **Exposure.** The relay speaks plain HTTP and hands out shells on every host it can reach. Bind
  it to loopback, or to a Tailscale/WireGuard address, and nothing wider. The token is a second
  lock, not the first.
- **On the phone:** open the URL in Safari, then use Share → Add to Home Screen to get a
  full-screen app. The bar above the keyboard has the keys iOS lacks: Esc, a sticky Ctrl, Tab and
  the arrows.

`--web <dir>` serves the page from somewhere other than `Relay/Web`. Pass it when the binary has
been moved away from the source tree.
