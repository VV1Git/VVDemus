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

    /// Longer is no more acceptable than shorter for a full-length song: an extended mix is not
    /// the radio edit that was queued.
    func testALongerRecordingOfAFullLengthSongIsNotAReissue() {
        let candidates = [track("extended", "Fallen Star", "The Neighbourhood", 260)]
        XCTAssertNil(InnerTubeClient.reissue(of: original, among: candidates))
    }

    /// WizTheMc's "Show Me Love" first came out as a 62-second preview single, since taken down;
    /// a radio saved from it still holds that id. The full release is the song it previewed.
    func testAGonePreviewPlaysTheFullRelease() {
        let preview = track("m8lW4eGqIAs", "Show Me Love", "WizTheMc", 62)
        let candidates = [
            track("Wx7I4yWJnXI", "Show Me Love", "Robin S", 270),
            track("sped", "Show Me Love (Sped Up)", "WizTheMc", 140),
            track("1NqIvsmUR2I", "Show Me Love", "WizTheMc, bees & honey", 177),
        ]
        XCTAssertEqual(InnerTubeClient.reissue(of: preview, among: candidates)?.videoId, "1NqIvsmUR2I")
    }

    /// A short song that is simply re-delivered still gets its own master rather than something
    /// longer that happens to share the name.
    func testAShortSongPrefersItsSameLengthCopy() {
        let interlude = track("old", "Interlude", "The Weeknd", 75)
        let candidates = [track("long", "Interlude", "The Weeknd", 200), track("same", "Interlude", "The Weeknd", 76)]
        XCTAssertEqual(InnerTubeClient.reissue(of: interlude, among: candidates)?.videoId, "same")
    }

    func testWithoutALengthToCompareNothingIsSwappedIn() {
        let candidates = [track("hpqpUs70t8g", "Fallen Star", "The Neighbourhood", nil)]
        XCTAssertNil(InnerTubeClient.reissue(of: original, among: candidates))
    }

    // MARK: - Copyright removals

    /// A 2:32 upload of Drake's "Cold Shoulder", saved as a radio seed and since removed for
    /// Universal; the release is 3:55. What was gone never was the release, so the length is no
    /// evidence against it.
    func testACopyrightRemovalIsReplacedByTheReleaseWhateverItsLength() {
        let leak = track("fgW8b0_tYkU", "Cold Shoulder", "Drake", 152)
        let candidates = [
            track("other", "Cold Shoulder", "Adele", 191),
            track("bzO58iQM19g", "Cold Shoulder", "Drake, Don Toliver, Yebba", 235),
        ]
        XCTAssertNil(InnerTubeClient.reissue(of: leak, among: candidates),
                     "Without the removal reason the length rule still applies")
        XCTAssertEqual(InnerTubeClient.reissue(of: leak, among: candidates, anyLength: true)?.videoId, "bzO58iQM19g")
    }

    func testTheClosestLengthWinsWhenAnyLengthWill() {
        let leak = track("x", "Cold Shoulder", "Drake", 152)
        let candidates = [track("far", "Cold Shoulder", "Drake", 300), track("near", "Cold Shoulder", "Drake", 170)]
        XCTAssertEqual(InnerTubeClient.reissue(of: leak, among: candidates, anyLength: true)?.videoId, "near")
    }

    func testTheRemovalReasonIsRecognised() {
        let removed = InnerTubeClient.GoneVideo(
            reason: "It was removed following a copyright removal request by Universal Music Group", original: nil)
        XCTAssertTrue(removed.isCopyrightRemoval)
        XCTAssertFalse(InnerTubeClient.GoneVideo(reason: "This video is not available", original: nil).isCopyrightRemoval)
    }

    /// A copyright removal comes back with no description at all, so the library's own record
    /// is the only thing to search with; where YouTube does describe the video, the record still
    /// wins and YouTube's length only fills the gap.
    func testTheLibrarysRecordDescribesAGoneVideo() throws {
        let bare = InnerTubeClient.GoneVideo(reason: "removed", original: nil)
        let saved = Track(videoId: "fgW8b0_tYkU", title: "Cold Shoulder", artist: "Drake", album: nil,
                          thumbnailUrl: nil, durationSeconds: nil)
        XCTAssertEqual(InnerTubeClient.describe(bare, known: saved)?.title, "Cold Shoulder")
        XCTAssertNil(InnerTubeClient.describe(bare, known: nil))

        let described = InnerTubeClient.GoneVideo(reason: "gone", original: track("fgW8b0_tYkU",
            "Drake - Cold Shoulder (Unreleased)", "dontolivervault", 152))
        let merged = try XCTUnwrap(InnerTubeClient.describe(described, known: saved))
        XCTAssertEqual(merged.artist, "Drake")
        XCTAssertEqual(merged.durationSeconds, 152)
    }

    // MARK: - Stub files

    /// "we fell in love in october"'s itag 18, as served: an 86 KB header over 184 seconds.
    func testAHeaderWithNothingBehindItIsAStub() {
        let stub = JSON(["contentLength": "86238", "approxDurationMs": "184203", "bitrate": 3747] as [String: Any])
        let real = JSON(["contentLength": "3680642", "approxDurationMs": "245016", "bitrate": 120203] as [String: Any])
        XCTAssertTrue(InnerTubeClient.isStubFormat(stub))
        XCTAssertFalse(InnerTubeClient.isStubFormat(real))
        XCTAssertTrue(InnerTubeClient.isStubFormat(JSON(["bitrate": 3747])), "The declared bitrate when that is all there is")
        XCTAssertFalse(InnerTubeClient.isStubFormat(JSON([String: Any]())), "No evidence is not a stub")
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
