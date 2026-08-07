import Foundation

/// This target's SwiftPM resource bundle, looked up rather than asserted.
///
/// **Deliberately not `Bundle.module`.** SwiftPM's generated accessor ends in `fatalError` — it
/// aborts the process rather than returning nil — and the two places it looks are both wrong for a
/// shipped `.app`:
///
/// * `Bundle.main.bundleURL` + the bundle name. For `swift run` that is the directory holding the
///   executable, which is where SwiftPM put the bundle, so it resolves. For an `.app` it is the
///   bundle *root* — `/Applications/tetmux.app/tetmux_tetmuxUI.bundle` — and a resource bundle
///   cannot live there: everything in an app bundle belongs under `Contents`, and `codesign` seals
///   `Contents/Resources`.
/// * The absolute `.build/…` path of the machine that compiled the binary, baked in at compile time.
///
/// The second candidate is what made this a shipping crash rather than a caught one, and it is worth
/// stating plainly: **the packaged app launching on the machine that built it is not evidence.** On
/// the build machine — a laptop after `Scripts/package-dmg.sh`, or a CI runner — that absolute path
/// exists, so the accessor resolves and the app comes up. On anybody else's machine the same
/// binary calls `fatalError` inside `applicationDidFinishLaunching` and the app dies before it draws
/// a window. That is exactly how 0.3.1 shipped: `EXC_BREAKPOINT` in
/// `variable initialization expression of static NSBundle.module`, with a `.dmg` that had been
/// mounted, signature-checked and run in CI.
///
/// SwiftTerm carries the same workaround for its Metal shaders (`MetalTerminalRenderer`), for the
/// same reason and against the same accessor.
///
/// So: probe `Contents/Resources` first, where `Scripts/package-dmg.sh` puts the bundles and where
/// this app therefore finds them; then the accessor's own main-bundle-relative location, which is
/// what `swift run` needs. A miss returns nil — the caller has a fallback, and no resource here is
/// worth a crash.
enum PackageResources {
    /// The bundle name SwiftPM emits for this target: `<package>_<target>.bundle`.
    private static let bundleName = "tetmux_tetmuxUI.bundle"

    static let bundle: Bundle? = {
        let candidates = [
            // A packaged .app.
            Bundle.main.resourceURL,
            // `swift run`, where the executable's own directory holds the bundle.
            Bundle.main.bundleURL,
        ]
        // `Bundle(url:)` is nil for a path that does not exist, which is what makes the probe safe.
        return candidates.lazy
            .compactMap { $0?.appendingPathComponent(bundleName) }
            .compactMap(Bundle.init(url:))
            .first
    }()

    static func url(forResource name: String, withExtension ext: String) -> URL? {
        bundle?.url(forResource: name, withExtension: ext)
    }
}
