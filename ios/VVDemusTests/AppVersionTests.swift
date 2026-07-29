import XCTest
@testable import VVDemus

/// The version readout exists to answer "am I running the build I just made?", so the part
/// that matters is that the build date is real and current — not that a constant is set.
final class AppVersionTests: XCTestCase {
    func testSummaryIsWellFormed() {
        let summary = AppVersion.summary
        print("\n[version] \(summary)\n")
        XCTAssertTrue(summary.hasPrefix("Version "))
        XCTAssertFalse(summary.contains("?"), "Version or build number missing from Info.plist")
        XCTAssertTrue(summary.contains("built "), "The build date is the part that answers the question")
    }

    /// Derived from the executable rather than a baked-in constant, so it must move on its
    /// own. A date in the future, or older than the app itself could plausibly be, means the
    /// derivation is wrong.
    func testBuildDateIsRecentAndNotInTheFuture() throws {
        let builtAt = try XCTUnwrap(AppVersion.builtAt)
        XCTAssertLessThanOrEqual(builtAt, Date().addingTimeInterval(60))
        XCTAssertGreaterThan(builtAt, Date().addingTimeInterval(-90 * 24 * 3600))
    }
}
