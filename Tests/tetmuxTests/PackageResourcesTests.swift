import XCTest
@testable import tetmuxUI

/// The guard for the 0.3.1 launch crash.
///
/// `Bundle.module` resolves on the machine that compiled the binary and calls `fatalError` on every
/// other one — see `PackageResources` for why. That makes it invisible to everything this project
/// already does: `swift test`, `swift run`, and CI's packaged-app check all run the binary where it
/// was built, so the only place the bug appears is a user's machine. There is no runtime assertion
/// that can catch it, so the assertion is on the source.
final class PackageResourcesTests: XCTestCase {
    /// `Tests/tetmuxTests/<this file>` → the repository root.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testNoSourceFileReachesForBundleModule() throws {
        let sources = repositoryRoot.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil),
            "no Sources directory at \(sources.path)"
        )

        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("Bundle.module") {
                // The prohibition is on *using* it; naming it in the prose that explains why not is
                // the whole point of that prose. Taken as a prefix rather than with `split`, whose
                // default drops empty subsequences — so a line that is *entirely* a comment loses
                // its empty code half and the doc text is read as code.
                let code = line.range(of: "//").map { line[..<$0.lowerBound] } ?? line[...]
                if code.contains("Bundle.module") {
                    offenders.append("\(url.lastPathComponent):\(number + 1)")
                }
            }
        }

        // A scan that silently found nothing to read would pass for the wrong reason.
        XCTAssertGreaterThan(scanned, 0, "scanned no Swift sources under \(sources.path)")
        XCTAssertEqual(
            offenders, [],
            """
            Bundle.module aborts the process when it cannot find its bundle, and it cannot find it \
            anywhere but the machine that built the binary. Use PackageResources instead.
            """
        )
    }

    /// The lookup order is the fix: `Contents/Resources` is where `Scripts/package-dmg.sh` puts the
    /// bundle, and it is the location `Bundle.module` never considers.
    func testTheResourceLookupPrefersTheLocationPackagingUses() {
        // `Bundle.main` under XCTest is the test runner, so the resolved bundle is not assertable
        // here; what is assertable is that a miss is a nil rather than a trap.
        XCTAssertNil(PackageResources.url(forResource: "no-such-resource", withExtension: "icns"))
    }
}
