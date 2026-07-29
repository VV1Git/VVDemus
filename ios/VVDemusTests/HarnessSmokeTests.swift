import XCTest
@testable import VVDemus

/// Proves the test target is wired to the app target and can reach its internals.
final class HarnessSmokeTests: XCTestCase {
    func testCanConstructAppModelTypes() {
        let track = Track(
            videoId: "abc123",
            title: "Smoke",
            artist: "Harness",
            album: nil,
            thumbnailUrl: nil,
            durationSeconds: 120
        )
        XCTAssertEqual(track.id, "abc123")
    }
}
