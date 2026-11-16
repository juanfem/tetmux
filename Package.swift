// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "tetmux",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // The portability hedge from §2.4: the protocol, transport, and session layers build
        // with no AppKit and no terminal-surface dependency, so they stay headlessly testable
        // and a non-macOS shell remains possible later without a rewrite.
        .library(
            name: "tetmuxCore",
            targets: ["tetmuxCore"]
        ),
        // The decisions that need no channel and no AppKit — F4.9's close outcome, F4.31's activity
        // edge, the tab-drop arithmetic. A library product so that a second front end (the relay in
        // `Relay/`, which serves a browser) asks them exactly as the macOS app does.
        .library(
            name: "tetmuxPolicy",
            targets: ["tetmuxPolicy"]
        ),
    ],
    targets: [
        // `forkpty` is in libutil on glibc and is not exposed by the Glibc module. Linux-only: the
        // Darwin module already provides it, and `pty.h` does not exist on macOS.
        .systemLibrary(name: "CUtil", path: "Sources/CUtil"),
        .target(
            name: "tetmuxCore",
            dependencies: [
                .target(name: "CUtil", condition: .when(platforms: [.linux])),
            ],
            path: "Sources/tetmuxCore"
        ),
        // Linux-buildable like the core, and for the same reason: the logic that decides what a
        // gesture *does* stays headlessly testable, and stays shared by every front end.
        .target(
            name: "tetmuxPolicy",
            dependencies: ["tetmuxCore"],
            path: "Sources/tetmuxPolicy"
        ),
        // The half of the suite that needs nothing but `tetmuxCore` — and so the half that can run
        // on Linux, which is what turns §2.4's hedge from a claim into a fact. §8 asks for the
        // fixture replay on both platforms; the Ubuntu job built the library and ran no test at all,
        // because one test target linking `tetmuxUI` cannot be *built* there. Everything here
        // replays fixtures or exercises pure value types; anything that touches AppKit, SwiftTerm or
        // a live tmux server stays in `tetmuxTests`.
        .testTarget(
            name: "tetmuxCoreTests",
            dependencies: ["tetmuxCore"],
            path: "Tests/tetmuxCoreTests",
            // R3.6's recorded byte streams, one per tmux version per scenario, written by
            // Scripts/capture-fixtures.py. `.copy` rather than `.process`: these are raw protocol
            // captures containing arbitrary bytes, and processing would be free to transform them.
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "tetmuxPolicyTests",
            dependencies: ["tetmuxCore", "tetmuxPolicy"],
            path: "Tests/tetmuxPolicyTests"
        ),
    ]
)

// Everything with AppKit under it, declared only on the platform that has AppKit.
//
// `--filter` selects which tests *run*, never which targets are built: `swift test` builds one test
// product out of every test target in the package, so a Linux job asking only for `tetmuxCoreTests`
// still has to compile `tetmuxTests`, which imports `tetmuxUI`, which is AppKit and SwiftTerm by
// design. The manifest is ordinary Swift evaluated on the host, so the honest way to say "this half
// of the package does not exist off macOS" is to not declare it there.
#if os(macOS)
// The dependency as well as the targets that use it. SwiftPM fetches every dependency a package
// declares, whether or not anything being built uses it — so declared unconditionally, a Linux build
// of the relay (`Relay/`, which depends on this package for `tetmuxCore` alone) cloned SwiftTerm for
// nothing, and a corrupted clone in the SwiftPM cache failed a build that never compiles it.
//
// Held on 1.15: 1.16 started snapping the cell width to the *nearest* pixel instead of up, which
// squeezes the default 12pt Menlo (7.22pt advance) into 7.0pt cells — visibly tighter text. And
// `from:` would also admit 1.99, SwiftTerm's API-breaking preview of 2.0. See the SwiftTerm entry in
// TODO.md before lifting this.
package.dependencies.append(
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.15.0"))
)
package.products.append(
    .executable(
        name: "tetmux",
        targets: ["tetmux"]
    )
)
package.targets.append(contentsOf: [
    .target(
        name: "tetmuxUI",
        dependencies: [
            "tetmuxCore",
            "tetmuxPolicy",
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
        dependencies: ["tetmuxCore", "tetmuxPolicy", "tetmuxUI"],
        path: "Tests/tetmuxTests",
        // T5.7's rendering corpus: real bytes, one file per case. `.copy` for the same reason the
        // protocol fixtures use it — the point is the exact bytes, and processing is free to
        // transform them. It lives here rather than beside `Fixtures/` in `tetmuxCoreTests`
        // because it needs `TerminalView`, which is AppKit.
        resources: [.copy("Corpus")]
    ),
])
#endif
