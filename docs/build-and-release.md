# Build, CI, and release

Part of the project guidance; `CLAUDE.md` holds the orientation and the index. Why the CI jobs are
shaped the way they are, and the packaging decisions (.dmg, SDK, signing) that are deliberate
rather than gaps.

**Four CI jobs, and the skips are policed.** `.github/workflows/ci.yml` runs **three** jobs on
every push, and a fourth — the tmux version matrix (`docs/testing.md`) — weekly, on demand, and on
a `v*` tag. The per-push three: `swift test` on macOS *with tmux installed* — otherwise the
integration suite silently skips itself and a green check means nothing, so the run fails if the
skip fires. On Ubuntu, `swift build --target tetmuxCore` **and**
`swift test --filter tetmuxCoreTests`, which is what exercises the §2.4 portability hedge; every
job used to be macOS, and a core-only regression on glibc went uncaught. Then the packaging script,
whose result is mounted and launched before it is uploaded. A `v*` tag also publishes the image as
a release — and that is the one path where the matrix **gates** rather than reports, since a .dmg
is what somebody installs. `package` therefore needs `matrix` under an explicit
`success || skipped` condition: a skipped dependency skips its dependents by default, so a bare
`needs:` would stop producing a .dmg on every ordinary push and say nothing about why.

**The manifest declares the AppKit half of the package only on macOS**, and that is what makes the
Linux test job possible at all. `--filter` chooses which tests *run*, never which targets are
built: `swift test` builds one product out of every test target, so a Linux job asking only for
`tetmuxCoreTests` still has to compile `tetmuxTests`, which imports `tetmuxUI`, which is AppKit and
SwiftTerm by design. `Package.swift` is ordinary Swift evaluated on the host, so `tetmuxUI`, the
executable and `tetmuxTests` are appended inside `#if os(macOS)`.

**The .dmg is arm64-only by decision (§2.5), and says so in its filename.** A universal binary
needs SwiftPM's `--arch arm64 --arch x86_64`, which routes through xcbuild, which compiles
SwiftTerm's Metal shaders and so needs a Metal toolchain component that is a separate
multi-gigabyte download. The native path copies the `.metal` source into the resource bundle and
never invokes the compiler. Do not revisit universal as part of other packaging work.

**The SDK the release links against is what the window looks like, so `package` runs on `macos-26`
while everything else stays on `macos-15`.** macOS 26 grants an application the Liquid Glass
appearance — rounded window corners, the translucent sidebar material — only to a binary linked
against the macOS 26 SDK; one linked against 15.x gets the compatibility look, square-cornered with
an opaque grey sidebar. Nothing in the source selects this and nothing in the build reports it.
0.3.2 was built on `macos-15`, shipped `LC_BUILD_VERSION sdk 15.5`, and arrived looking like a
different application than the one the same commit builds locally — through a green run of a suite
that mounts the image, verifies the signature and opens a control-mode channel, none of which can
see a design language. So the packaging job asserts the SDK out of the Mach-O rather than trusting
the runner label, which an older Xcode on the image would satisfy while being wrong.
`Package.swift` pins `.macOS(.v14)`, so this is the SDK and not the deployment target: `minos`
stays 14.0 and `LSMinimumSystemVersion` stays honest. The test jobs stay a version behind
deliberately — they assert behaviour, which is the half that does not vary with the SDK.

**That version behind is a *compiler* version behind too, and it compiles this package more
strictly than the machine it is written on.** `macos-15` carries Swift 6.1.2; a current dev machine
is on 6.3. Actor-isolation diagnostics moved between them in the permissive direction, so the skew
is one-way: **a green `swift test` locally does not mean the tree compiles on CI, while the reverse
holds.** `91f0329` made a test delegate read `isAnsweringQuery` — main-actor state, because the
property belongs to an `NSView` subclass — from a witness of `TerminalViewDelegate`, which is a
plain protocol and so gives its witnesses no isolation. 6.3 accepts that and 6.1.2 rejects it, and
the tree stayed red for four commits while every local run passed. The fix is a `@preconcurrency`
conformance (SE-0423), which both toolchains accept: the witness may be `@MainActor` and the
requirement stays nonisolated, with a runtime main-thread check that traps loudly instead of
racing. **When a build failure is a concurrency-isolation error, check the two Swift versions before
anything else** — and read a red CI job against a green local suite as a toolchain question, not a
flake. Nothing here is worth pinning the runners to fix: the older compiler catching more is the
useful direction for the skew to run in.

**Signing is ad-hoc (`codesign --sign -`): no Developer ID, no notarisation, no updater.** That is
a **decision** (§2.5), not a gap awaiting funds — notarisation needs a paid Apple Developer
account, this is a tool for one person's daily use, and a first open is right-click → Open, which
the release notes and the README both say at the download. Do not add signing work to unrelated
packaging changes; the entry in `TODO.md` says what to do if an account ever arrives.
