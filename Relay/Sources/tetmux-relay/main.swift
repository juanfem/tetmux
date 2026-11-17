import Foundation
import Hummingbird
import HummingbirdWebSocket
import tetmuxCore

// tetmux-relay — the web client's server: every configured host, over a WebSocket to xterm.js.
//
//   tetmux-relay [--host <id|name>]... [--session <name>] [--bind 127.0.0.1] [--port 8080]
//                [--token <secret>] [--web <dir>]
//
// Hosts come from `hosts.json` and `~/.ssh/config` exactly as the app and `--diagnose` read them, so
// the relay reaches a remote machine over the same ssh invocation the app would use. On Linux,
// `hosts.json` lives in `$XDG_DATA_HOME/tetmux` (`~/.local/share/tetmux`) — where Foundation puts
// Application Support there.
//
// Every host is offered to the browser; only the `--host` ones (the local host when none is given)
// are connected at startup. The rest connect when a browser first picks them, so a long ssh config
// does not mean a dozen ssh handshakes — and password prompts nobody can answer yet — at launch.

struct Options {
    var hosts: [String] = []
    var session: String?
    var bind = "127.0.0.1"
    var port = 8080
    var token: String?
    var web: String?

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--host": if let host = iterator.next() { options.hosts.append(host) }
            case "--session": options.session = iterator.next()
            case "--bind": options.bind = iterator.next() ?? options.bind
            case "--port": options.port = iterator.next().flatMap(Int.init) ?? options.port
            case "--token": options.token = iterator.next()
            case "--web": options.web = iterator.next()
            case "-h", "--help":
                print("usage: tetmux-relay [--host <id|name>]... [--session <name>] [--bind <addr>] "
                    + "[--port <n>] [--token <secret>] [--web <dir>]")
                exit(0)
            default:
                FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
                exit(2)
            }
        }
        return options
    }
}

/// 32 random bytes as hex. The relay hands out shells on every host it can reach, so even on a
/// loopback bind it does not accept a socket without this.
func randomToken() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
        .joined()
}

/// Compares in time that does not depend on where the first difference is.
func tokensMatch(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}

/// Unbuffered, so the URL is visible at once under systemd, `nohup`, or a pipe. Not `setvbuf`:
/// glibc's `stdout` is a mutable global, which Swift 6 refuses to touch from top-level code.
func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

let options = Options.parse(CommandLine.arguments)
let token = options.token ?? ProcessInfo.processInfo.environment["TETMUX_RELAY_TOKEN"] ?? randomToken()

// The page, from `Relay/Web` beside this source file unless told otherwise. A prototype's choice:
// a deployed relay passes `--web`, and step 4 is where the page stops being one file.
let webRoot = URL(fileURLWithPath: options.web
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Web").standardizedFileURL.path)

// MARK: - The hosts

var configs = await HostConfigStore().loadHosts().map(\.asConfig)
if !configs.contains(where: \.isLocal) {
    configs.insert(HostConfig(id: "local", name: "localhost", isLocal: true), at: 0)
}
var startup: [HostConfig] = []
for requested in options.hosts {
    if let match = configs.first(where: { $0.id == requested || $0.name == requested }) {
        startup.append(match)
    } else {
        // Not configured anywhere: taken as an ssh destination, as `ssh <it>` would.
        let adHoc = HostConfig(id: requested, name: requested, isLocal: false)
        configs.append(adHoc)
        startup.append(adHoc)
    }
}
if startup.isEmpty, let local = configs.first(where: \.isLocal) {
    startup = [local]
}

let service = SessionService()
if ProcessInfo.processInfo.environment["TETMUX_RELAY_DEBUG"] != nil {
    await service.setDiagnosticLogger { message in
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
for config in configs {
    await service.addHost(config)
}
let registry = ViewRegistry(service: service)

for config in startup {
    say("→ connecting to \(config.name) [\(config.id)]…")
    do {
        try await service.connectHost(hostId: config.id, targetSession: options.session, createIfEmpty: true)
    } catch {
        // One host down is not the relay down: the browser shows the failure on that host and
        // can try it again from there.
        say("✘ \(config.name): \(error)")
    }
}
say("  \(configs.count) host\(configs.count == 1 ? "" : "s") offered: "
    + configs.map(\.name).joined(separator: ", "))

// MARK: - The server

let router = Router(context: BasicWebSocketRequestContext.self)

router.get("/") { _, _ -> Response in
    try page("index.html", type: "text/html; charset=utf-8")
}
router.get("/manifest.webmanifest") { _, _ -> Response in
    try page("manifest.webmanifest", type: "application/manifest+json")
}

router.ws("/ws") { request, _ in
    guard let offered = request.uri.queryParameters["token"].map(String.init),
          tokensMatch(offered, token) else { return .dontUpgrade }
    return .upgrade([:])
} onUpgrade: { inbound, outbound, _ in
    let bridge = PaneBridge(service: service, registry: registry, outbound: outbound)
    await bridge.run(inbound: inbound)
}

func page(_ name: String, type: String) throws -> Response {
    let data = try Data(contentsOf: webRoot.appendingPathComponent(name))
    return Response(
        status: .ok,
        headers: [.contentType: type, .cacheControl: "no-store"],
        body: .init(byteBuffer: ByteBuffer(bytes: data))
    )
}

let app = Application(
    router: router,
    server: .http1WebSocketUpgrade(webSocketRouter: router),
    configuration: .init(address: .hostname(options.bind, port: options.port))
)

let shownHost = options.bind == "0.0.0.0" ? (ProcessInfo.processInfo.hostName) : options.bind
say("→ serving http://\(shownHost):\(options.port)/?token=\(token)")
if options.bind != "127.0.0.1" && options.bind != "localhost" {
    say("  plain HTTP: only bind beyond loopback on a network that encrypts for you (Tailscale, WireGuard)")
}
// MARK: - Leaving

// The relay takes SIGTERM and SIGINT itself rather than handing them to Hummingbird's graceful
// shutdown, for two reasons. The channels have to be given back properly: `shutdown` waits for tmux
// to acknowledge `set-option -u window-size`, without which the user's session is left on `manual`
// for the next plain `tmux attach` (see `restoreWindowSizePolicy`). And a graceful shutdown waits on
// every open connection, which a phone that vanished mid-handshake can hold open indefinitely — seen
// once, against a browser tab, and never reproduced against a scripted client. A service manager
// sending SIGTERM expects the process to go, so this bounds the wait and then goes.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let stopSignals = [SIGTERM, SIGINT].map { number in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        say("→ stopping")
        // The deadline is independent of the work: a task group would wait for a wedged child
        // before returning, which is the hang this exists to rule out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            say("→ tmux did not answer in time; leaving anyway")
            exit(0)
        }
        Task {
            await service.shutdown()
            exit(0)
        }
    }
    source.resume()
    return source
}

try await app.runService(gracefulShutdownSignals: [])
withExtendedLifetime(stopSignals) {}
