// swift-tools-version: 6.0

import PackageDescription

// The relay: one server process that holds tetmux's control-mode channels — local, or over ssh to
// any host in its `hosts.json` — and serves them to a browser over a WebSocket. Built for a phone
// as the client: iOS kills a backgrounded app's sockets within seconds, so the channels have to live
// somewhere that is not the phone, and the phone only ever holds a link it can drop and re-open.
//
// A package of its own rather than a target of the root one, so that the macOS app's dependency
// graph never grows SwiftNIO: SwiftPM resolves every dependency a package declares, whether or not
// the target being built uses it.
let package = Package(
    name: "tetmux-relay",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(name: "tetmux", path: ".."),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "tetmux-relay",
            dependencies: [
                .product(name: "tetmuxCore", package: "tetmux"),
                .product(name: "tetmuxPolicy", package: "tetmux"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ],
            path: "Sources/tetmux-relay"
        ),
    ]
)
