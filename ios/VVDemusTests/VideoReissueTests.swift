import XCTest
@testable import VVDemus

/// A video taken down because its release was re-delivered under a new id, and the decision
/// of which search result — if any — is that same recording. Fixtures are what YouTube returned
/// for "Fallen Star", whose old art track went "This video is not available" after The
/// Neighbourhood's single was re-released.
final class VideoReissueTests: XCTestCase {
    private func track(_ id: String, _ title: String, _ artist: String, _ seconds: Int?) -> Track {
        Track(videoId: id, title: title, artist: artist, album: nil, thumbnailUrl: nil, durationSeconds: seconds)
    }

    private let original = Track(videoId: "54kTO17-j_0", title: "Fallen Star", artist: "The Neighbourhood",
                                 album: nil, thumbnailUrl: nil, durationSeconds: 225)

    func testTheReissueIsFoundAmongCoversAndEdits() {
        let candidates = [
            track("54kTO17-j_0", "Fallen Star", "The Neighbourhood", 225),       // the dead one itself
            track("uRfa1ZkXluE", "fallen star (sped up)", "The Neighbourhood", 173),
            track("yq6ta_FtAJg", "Falling Star", "The Neighborly", 204),
            track("hpqpUs70t8g", "Fallen Star", "The Neighbourhood", 225),
        ]
        XCTAssertEqual(InnerTubeClient.reissue(of: original, among: candidates)?.videoId, "hpqpUs70t8g")
    }

    /// Same title, same length, someone else's recording.
    func testAnotherArtistsSongOfTheSameNameIsNotAReissue() {
        let candidates = [track("cover", "Fallen Star", "Some Cover Band", 225)]
        XCTAssertNil(InnerTubeClient.reissue(of: original, among: candidates))
    }

    /// A different length is a different recording — a radio edit, an extended mix — even
    /// with the title and artist identical.
    func testADifferentLengthIsNotAReissue() {
        let candidates = [track("edit", "Fallen Star", "The Neighbourhood", 201)]
        XCTAssertNil(InnerTubeClient.reissue(of: original, among: candidates))
        let close = [track("remaster", "Fallen Star", "The Neighbourhood", 227)]
        XCTAssertEqual(InnerTubeClient.reissue(of: original, among: close)?.videoId, "remaster")
    }

    func testWithoutALengthToCompareNothingIsSwappedIn() {
        let candidates = [track("hpqpUs70t8g", "Fallen Star", "The Neighbourhood", nil)]
        XCTAssertNil(InnerTubeClient.reissue(of: original, among: candidates))
    }

    // MARK: - Telling "gone" from "refused"

    private func response(_ status: String, reason: String? = nil, details: [String: Any]? = nil) -> JSON {
        var body: [String: Any] = ["playabilityStatus": ["status": status, "reason": reason as Any]]
        if let details { body["videoDetails"] = details }
        return JSON(body)
    }

    func testAnUnplayableVideoIsGoneAndStillDescribesItself() throws {
        let json = response("UNPLAYABLE", reason: "This video is not available", details: [
            "title": "Fallen Star", "author": "The Neighbourhood - Topic", "lengthSeconds": "225",
        ])
        let gone = try XCTUnwrap(InnerTubeClient.gone(json, videoId: "54kTO17-j_0"))
        XCTAssertEqual(gone.reason, "This video is not available")
        XCTAssertEqual(gone.original, original)
    }

    /// A missing token is the case `resolveWithTokenRetry` handles, and it must not be mistaken
    /// for a dead video and sent off to search for a replacement.
    func testATokenRefusalIsNotGone() {
        XCTAssertNil(InnerTubeClient.gone(response("LOGIN_REQUIRED", reason: "Sign in to confirm you’re not a bot"),
                                          videoId: "x"))
        XCTAssertNil(InnerTubeClient.gone(response("OK"), videoId: "x"))
    }
}
