import Foundation
import Hummingbird
import HummingbirdWebSocket
import tetmuxCore

// tetmux-relay — the web client's server: every configured host, over a WebSocket to xterm.js.
//
//   tetmux-relay [--host <id|name>]... [--session <name>] [--bind 127.0.0.1] [--port 8080]
//                [--token <secret>] [--web <dir>] [--config <dir>]
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
    /// Where `hosts.json` is read and written. The platform's Application Support by default — the
    /// Mac app's own file on a Mac, which a relay under test must not be adding hosts to.
    var config: String?

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
            case "--config": options.config = iterator.next()
            case "-h", "--help":
                print("usage: tetmux-relay [--host <id|name>]... [--session <name>] [--bind <addr>] "
                    + "[--port <n>] [--token <secret>] [--web <dir>] [--config <dir>]")
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

/// This machine's name, short form: `jymtp`, not `jymtp.example.org`.
///
/// The core calls the local host "localhost", which is right in the Mac app — the machine in front of
/// you — and wrong here, where the local host is a server and the person reading the picker is on a
/// phone somewhere else.
func machineName() -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    guard gethostname(&buffer, buffer.count) == 0 else { return "localhost" }
    let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let short = name.split(separator: ".").first.map(String.init) ?? ""
    return short.isEmpty ? "localhost" : short
}

let store = HostConfigStore(directory: options.config.map { URL(fileURLWithPath: $0, isDirectory: true) })
var stored = await store.loadHosts()
if !stored.contains(where: \.isLocal) {
    stored.insert(HostConfigStore.localBaseline, at: 0)
}
for index in stored.indices where stored[index].isLocal {
    stored[index].name = machineName()
}
var configs = stored.map(\.asConfig)

// Said at startup, because "only one host in the picker" otherwise has no visible cause: on a server
// neither file usually exists until someone creates it.
for (label, url) in [("hosts.json", store.storeURL), ("ssh config", store.sshConfigURL)] {
    let found = FileManager.default.fileExists(atPath: url.path)
    say("  \(label): \(url.path)\(found ? "" : " (not found)")")
}
if let failure = await store.loadFailure {
    say("✘ \(failure)")
}
var startup: [HostConfig] = []
for requested in options.hosts {
    if let match = configs.first(where: {
        $0.id == requested || $0.name == requested || ($0.isLocal && requested == "localhost")
    }) {
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
let hostBook = HostBook(store: store, service: service)

for config in startup {
    say("→ connecting to \(config.name) [\(config.id)]…")
    do {
        // With no session named, whatever the server already has — the mode `openHost` uses. Left to
        // `connectHost`'s default, every start created a fresh `tetmux_N` beside the user's sessions,
        // and a relay restarted by a service manager would leave one behind each time.
        try await service.connectHost(
            hostId: config.id, targetSession: options.session,
            mode: options.session == nil ? .attachAny : nil, createIfEmpty: true
        )
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
    let bridge = PaneBridge(service: service, registry: registry, hostBook: hostBook, outbound: outbound)
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
