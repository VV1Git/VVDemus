import XCTest
@testable import VVDemus

/// Album rows that YouTube Music hands over as music videos, and the audio swapped in for them.
///
/// The fixtures are Drake's "Honestly, Nevermind" as music.youtube.com served it on 28 Oct 2026,
/// trimmed: every row of its album page is `MUSIC_VIDEO_TYPE_OMV`, and the two below are the ones
/// reported as playing "a crowd recording" — "Falling Back" is DrakeVEVO's "(Extended Version)"
/// video and "Sticky" its "(Official Music Video)". The candidates are the Songs search for the
/// album as it came back, `- Topic` uploads with the album's lengths.
final class AlbumAudioTests: XCTestCase {

    // MARK: - Reading the page

    func testRowsTypedAsMusicVideosAreReportedAsVideoCuts() throws {
        let page = try InnerTubeClient.parseAlbumPage(try JSON.parse(Data(Self.albumPage.utf8)),
                                                      browseId: "MPREb_5B7Ey9PNjYa")

        XCTAssertEqual(page.tracks.map(\.videoId), ["sOreUnGoIMg", "AnZcWgXZOKM", "ATVrow00001", "untyped0001"])
        XCTAssertEqual(page.videoCuts, ["sOreUnGoIMg", "AnZcWgXZOKM"],
                       "an ATV row is already the album, and a row with no type is not evidence of a video")
        // The page's lengths are the album's, which is why the row looked right and played wrong.
        XCTAssertEqual(page.tracks[0].durationSeconds, 267)
    }

    // MARK: - The two reported songs

    func testFallingBackPlaysTheAlbumCutNotTheExtendedVideo() {
        let swapped = AlbumAudio.swappingInAudio([Self.fallingBackRow], videoCuts: ["sOreUnGoIMg"],
                                                 candidates: Self.albumSearch)
        XCTAssertEqual(swapped.map(\.videoId), ["D-bKgUMyB44"])
    }

    func testStickyPlaysTheAlbumCutNotTheMusicVideo() {
        let swapped = AlbumAudio.swappingInAudio([Self.stickyRow], videoCuts: ["AnZcWgXZOKM"],
                                                 candidates: Self.albumSearch)
        // Two `- Topic` copies of "Sticky" on the album, same length: the earlier one, search's pick.
        XCTAssertEqual(swapped.map(\.videoId), ["UFR-9IVgMBA"])
    }

    func testTheSwappedRowKeepsWhatThePageSaidAboutIt() {
        let row = Track(videoId: "AnZcWgXZOKM", title: "Sticky", artist: "Drake", album: "Honestly, Nevermind",
                        thumbnailUrl: "https://album/cover", durationSeconds: 250)
        let swapped = AlbumAudio.swappingInAudio([row], videoCuts: ["AnZcWgXZOKM"], candidates: Self.albumSearch)[0]

        XCTAssertEqual(swapped.title, "Sticky")
        XCTAssertEqual(swapped.album, "Honestly, Nevermind")
        XCTAssertEqual(swapped.thumbnailUrl, "https://album/cover")
        XCTAssertEqual(swapped.durationSeconds, 244, "the length of what will actually play")
    }

    // MARK: - What is never swapped

    func testAnAudioRowIsLeftAloneEvenWithACandidateForIt() {
        let row = Track(videoId: "someATVcopy", title: "Sticky", artist: "Drake", album: "Honestly, Nevermind",
                        thumbnailUrl: nil, durationSeconds: 244)
        let swapped = AlbumAudio.swappingInAudio([row], videoCuts: ["AnZcWgXZOKM"], candidates: Self.albumSearch)
        XCTAssertEqual(swapped, [row])
    }

    /// A live album's rows are the live takes because that is the album that was opened. Its
    /// video row must not become the studio cut just because the studio cut is easy to find.
    func testALiveRowIsNeverReplacedByTheStudioCut() {
        let live = Track(videoId: "liveVideo01", title: "Sticky (Live)", artist: "Drake", album: "Live at Wembley",
                         thumbnailUrl: nil, durationSeconds: 244)
        XCTAssertNil(AlbumAudio.counterpart(of: live, among: Self.albumSearch))
    }

    func testTheStudioRowIsNeverReplacedByALiveTake() {
        let liveTake = Track(videoId: "liveAudio01", title: "Falling Back (Live)", artist: "Drake",
                             album: "Honestly, Nevermind", thumbnailUrl: nil, durationSeconds: 267)
        XCTAssertNil(AlbumAudio.counterpart(of: Self.fallingBackRow, among: [liveTake]))
    }

    func testAnotherArtistsSongOfTheSameNameIsRefused() {
        // Straight out of the Songs search for "falling back".
        let other = Track(videoId: "7manBpbYZ4E", title: "Falling Back", artist: "Maiorca", album: "Falling Back",
                          thumbnailUrl: nil, durationSeconds: 230)
        XCTAssertNil(AlbumAudio.counterpart(of: Self.fallingBackRow, among: [other]))
    }

    func testNoCandidateLeavesTheVideoPlaying() {
        let swapped = AlbumAudio.swappingInAudio([Self.fallingBackRow], videoCuts: ["sOreUnGoIMg"], candidates: [])
        XCTAssertEqual(swapped, [Self.fallingBackRow])
    }

    // MARK: - Other releases

    func testTheSameRecordingOnASingleIsAcceptedAtTheSameLength() {
        let single = Track(videoId: "singleCut01", title: "Falling Back", artist: "Drake", album: "Falling Back",
                           thumbnailUrl: nil, durationSeconds: 266)
        XCTAssertEqual(AlbumAudio.counterpart(of: Self.fallingBackRow, among: [single])?.videoId, "singleCut01")
    }

    /// Off the album, a title and an artist are all an edit shares with the album cut, so the
    /// length has to agree as well.
    func testAnotherReleaseOfADifferentLengthIsRefused() {
        let edit = Track(videoId: "radioEdit01", title: "Falling Back", artist: "Drake", album: "Falling Back",
                         thumbnailUrl: nil, durationSeconds: 210)
        XCTAssertNil(AlbumAudio.counterpart(of: Self.fallingBackRow, among: [edit]))
    }

    func testTheAlbumsOwnCopyBeatsAnotherReleaseThatIsCloserInLength() {
        let row = Track(videoId: "sOreUnGoIMg", title: "Falling Back", artist: "Drake", album: "Honestly, Nevermind",
                        thumbnailUrl: nil, durationSeconds: 266)
        let single = Track(videoId: "singleCut01", title: "Falling Back", artist: "Drake", album: "Falling Back",
                           thumbnailUrl: nil, durationSeconds: 266)
        XCTAssertEqual(AlbumAudio.counterpart(of: row, among: [single] + Self.albumSearch)?.videoId, "D-bKgUMyB44")
    }

    // MARK: - Fixtures

    private static let fallingBackRow = Track(videoId: "sOreUnGoIMg", title: "Falling Back", artist: "Drake",
                                              album: "Honestly, Nevermind", thumbnailUrl: nil, durationSeconds: 267)
    private static let stickyRow = Track(videoId: "AnZcWgXZOKM", title: "Sticky", artist: "Drake",
                                         album: "Honestly, Nevermind", thumbnailUrl: nil, durationSeconds: 244)

    /// The Songs search for "Honestly, Nevermind Drake", plus the second `- Topic` "Sticky" that
    /// the search for "sticky drake" returns, and the unrelated songs either brings along.
    private static let albumSearch: [Track] = [
        song("hzS5TP-Qh5c", "Massive", 337),
        song("D-bKgUMyB44", "Falling Back", 267),
        song("s_BylnOIj5M", "Texts Go Green", 309),
        song("UFR-9IVgMBA", "Sticky", 244),
        song("vczUPcdNXBc", "Sticky", 244),
        Track(videoId: "spjUd9KtIbo", title: "Dust", artist: "Drake", album: "ICEMAN",
              thumbnailUrl: nil, durationSeconds: 190),
        Track(videoId: "16KSivdIGjQ", title: "Sticky (feat. GloRilla, Sexyy Red & Lil Wayne)",
              artist: "Tyler, The Creator", album: "CHROMAKOPIA", thumbnailUrl: nil, durationSeconds: 256),
    ]

    private static func song(_ videoId: String, _ title: String, _ seconds: Int) -> Track {
        Track(videoId: videoId, title: title, artist: "Drake", album: "Honestly, Nevermind",
              thumbnailUrl: nil, durationSeconds: seconds)
    }

    private static func row(_ videoId: String, _ title: String, _ length: String, type: String?) -> String {
        let config = type.map {
            #", "watchEndpointMusicSupportedConfigs": {"watchEndpointMusicConfig": {"musicVideoType": "\#($0)"}}"#
        } ?? ""
        return """
        {"musicResponsiveListItemRenderer": {
          "overlay": {"musicItemThumbnailOverlayRenderer": {"content": {"musicPlayButtonRenderer": {
            "playNavigationEndpoint": {"watchEndpoint": {
              "videoId": "\(videoId)", "playlistId": "OLAK5uy_na_qnYnNCbsE864dnFpM8S78rZxBM9ksA"\(config)
            }}
          }}}},
          "flexColumns": [
            {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "\(title)"}]}}},
            {"musicResponsiveListItemFlexColumnRenderer": {"text": {}}}
          ],
          "fixedColumns": [
            {"musicResponsiveListItemFixedColumnRenderer": {"text": {"runs": [{"text": "\(length)"}]}}}
          ],
          "playlistItemData": {"videoId": "\(videoId)"}
        }}
        """
    }

    /// The real page's two reported rows, plus an ATV row and an untyped one to pin down what
    /// counts as a video.
    private static let albumPage = """
    {"contents": {"twoColumnBrowseResultsRenderer": {
      "tabs": [{"tabRenderer": {"content": {"sectionListRenderer": {"contents": [
        {"musicResponsiveHeaderRenderer": {
          "title": {"runs": [{"text": "Honestly, Nevermind"}]},
          "straplineTextOne": {"runs": [{"text": "Drake"}]},
          "subtitle": {"runs": [{"text": "Album"}, {"text": " • "}, {"text": "2022"}]}
        }}
      ]}}}}],
      "secondaryContents": {"sectionListRenderer": {"contents": [
        {"musicShelfRenderer": {"contents": [
          \(row("sOreUnGoIMg", "Falling Back", "4:27", type: "MUSIC_VIDEO_TYPE_OMV")),
          \(row("AnZcWgXZOKM", "Sticky", "4:04", type: "MUSIC_VIDEO_TYPE_OMV")),
          \(row("ATVrow00001", "Massive", "5:37", type: "MUSIC_VIDEO_TYPE_ATV")),
          \(row("untyped0001", "Overdrive", "3:23", type: nil))
        ]}}
      ]}}
    }}}
    """
}
