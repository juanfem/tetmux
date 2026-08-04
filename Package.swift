// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "tetmux",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "tetmux",
            targets: ["tetmux"]
        ),
        // The portability hedge from §2.4: the protocol, transport, and session layers build
        // with no AppKit and no terminal-surface dependency, so they stay headlessly testable
        // and a non-macOS shell remains possible later without a rewrite.
        .library(
            name: "tetmuxCore",
            targets: ["tetmuxCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.0.7")
    ],
    targets: [
        .target(
            name: "tetmuxCore",
            path: "Sources/tetmuxCore"
        ),
        .target(
            name: "tetmuxUI",
            dependencies: [
                "tetmuxCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/tetmuxUI",
            // The app icon. Lives here so that one committed .icns serves both consumers: SwiftPM
            // bundles it for `swift run`, which has no .app around it to carry a CFBundleIconFile,
            // and Scripts/package-dmg.sh copies the same file into the bundle it assembles.
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "tetmux",
            dependencies: [
                "tetmuxCore",
                "tetmuxUI",
            ],
            path: "Sources/tetmux"
        ),
        .testTarget(
            name: "tetmuxTests",
            // `tetmuxUI` as well as the core: `AppModel` holds real logic — the close decision
            // (F4.9), prompt handling, keymap resolution — that needed no AppKit to exercise and was
            // simply unreachable from a test bundle that did not link it.
            dependencies: ["tetmuxCore", "tetmuxUI"],
            path: "Tests/tetmuxTests"
        ),
    ]
)
