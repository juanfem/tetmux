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
.build/release/tetmux-relay --host build-box        # a host from hosts.json, by id or name
.build/release/tetmux-relay --bind 100.x.y.z --port 8080 --session work
```

It prints the URL to open, with an access token in it. Pass `--token`, or set
`TETMUX_RELAY_TOKEN`, to keep the same token across restarts, so a home-screen bookmark keeps
working. `TETMUX_RELAY_DEBUG=1` prints the control-mode traffic to stderr, the same way
`tetmux --diagnose` does.

Requirements:

- **Swift 6.2 or newer**, for Hummingbird. The relay builds and runs on Linux (checked in
  `swift:6.2`).
- **Hosts** come from `hosts.json` plus `~/.ssh/config`. On Linux, `hosts.json` lives in
  `~/.local/share/tetmux/`. ssh runs as the relay's user, with that user's keys and `known_hosts`.
  The relay cannot answer a password prompt. It shows the prompt in the page's status line and
  waits.
- **Exposure.** The relay speaks plain HTTP and hands out shells on every host it can reach. Bind
  it to loopback, or to a Tailscale/WireGuard address, and nothing wider. The token is a second
  lock, not the first.
- **On the phone:** open the URL in Safari, then use Share → Add to Home Screen to get a
  full-screen app. The bar above the keyboard has the keys iOS lacks: Esc, a sticky Ctrl, Tab and
  the arrows.

`--web <dir>` serves the page from somewhere other than `Relay/Web`. Pass it when the binary has
been moved away from the source tree.
