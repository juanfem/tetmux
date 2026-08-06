import XCTest
@testable import tetmuxCore

/// P6.6 — the rule that decides whether a change redraws the application.
///
/// F4.29's round-trip reading changes every ten seconds per host by construction, and until it was
/// taken out of the diff it made every one of those a state broadcast: measured on 12 panes, a mean
/// of 0.45% of one core with spikes to 5.4%, against 0.04% and 0.8% once the reading travelled on
/// its own channel. What is asserted here is the half of that a test can see — that the comparison
/// ignores the reading and nothing else. The cost itself is a SwiftUI tree rebuild, which no unit
/// test can observe; `docs/measurements.md` carries that number and how it was taken.
final class RoundTripBroadcastTests: XCTestCase {

    private func host(
        rtt: Double? = nil,
        version: String? = "3.7b",
        sessions: [TmuxSession] = []
    ) -> HostState {
        HostState(
            config: HostConfig(id: "h", name: "h", isLocal: true),
            connectionState: .connected,
            sessions: sessions,
            tmuxVersion: version,
            rttMilliseconds: rtt
        )
    }

    func testARoundTripReadingIsNotAStateChange() {
        XCTAssertFalse(SessionService.differsBeyondRoundTrip(host(rtt: 12), host(rtt: 4813)))
        // Including its arrival and its disappearance: a host that has not answered yet and one that
        // just did differ in nothing anybody needs redrawing for.
        XCTAssertFalse(SessionService.differsBeyondRoundTrip(host(rtt: nil), host(rtt: 12)))
        XCTAssertFalse(SessionService.differsBeyondRoundTrip(host(rtt: 12), host(rtt: nil)))
        XCTAssertFalse(SessionService.differsBeyondRoundTrip(host(rtt: 12), host(rtt: 12)))
    }

    func testAnythingElseIsAStateChange() {
        // A field beside the reading, changed while the reading also moves — the case the normalising
        // comparison exists to get right, and the one an over-eager version would swallow.
        XCTAssertTrue(SessionService.differsBeyondRoundTrip(
            host(rtt: 12, version: "3.7b"), host(rtt: 99, version: "3.5a")
        ))
        XCTAssertTrue(SessionService.differsBeyondRoundTrip(
            host(rtt: 12), host(rtt: 12, sessions: [TmuxSession(id: "$1", name: "one")])
        ))
    }

    func testAHostAppearingOrGoingIsAStateChange() {
        XCTAssertTrue(SessionService.differsBeyondRoundTrip(nil, host()))
        XCTAssertTrue(SessionService.differsBeyondRoundTrip(host(), nil))
        XCTAssertFalse(SessionService.differsBeyondRoundTrip(nil, nil))
    }
}
