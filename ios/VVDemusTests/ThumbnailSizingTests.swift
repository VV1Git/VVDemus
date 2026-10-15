import XCTest
@testable import VVDemus

/// `RemoteImage.resizedThumbnailUrl`, which every piece of artwork in the app is fetched
/// through.
final class ThumbnailSizingTests: XCTestCase {

    private let base = "https://yt3.googleusercontent.com/abc123"

    /// Search hands back 120px URLs, and a radio's seed is usually a search result. Clamping
    /// to that left every such radio with a 120px hero image stretched over its header.
    func testSmallSourceIsAskedForTheFullTarget() {
        let url = RemoteImage.resizedThumbnailUrl("\(base)=w120-h120-l90-rj", targetPixels: 544)
        XCTAssertEqual(url, "\(base)=w544-h544-l90-rj")
    }

    func testLargeSourceIsShrunkToTheTarget() {
        let url = RemoteImage.resizedThumbnailUrl("\(base)=w544-h544-l90-rj", targetPixels: 96)
        XCTAssertEqual(url, "\(base)=w96-h96-l90-rj")
    }

    func testUnrecognisedUrlIsLeftAlone() {
        let url = "https://example.com/cover.jpg"
        XCTAssertEqual(RemoteImage.resizedThumbnailUrl(url, targetPixels: 300), url)
    }

    /// Nearby sizes share a request, and nothing is rounded down.
    func testPixelSizesAreRoundedUpToABucket() {
        XCTAssertEqual(RemoteImage.bucketed(700), 768)
        XCTAssertEqual(RemoteImage.bucketed(768), 768)
        XCTAssertEqual(RemoteImage.bucketed(769), 1024)
        XCTAssertEqual(RemoteImage.bucketed(1), 32)
        XCTAssertEqual(RemoteImage.bucketed(5000), 5000)
    }
}
