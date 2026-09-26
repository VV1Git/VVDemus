import XCTest
@testable import VVDemus

/// Unreleased music through search: fan uploads ranked among the catalogue's songs, and their
/// titles cleaned up into something a song row can show. Fixtures are real rows, as YouTube
/// Music returned them for these queries.
final class SearchBlendTests: XCTestCase {
    private func song(_ id: String, _ title: String, _ artist: String, album: String? = nil) -> Track {
        Track(videoId: id, title: title, artist: artist, album: album, thumbnailUrl: nil, durationSeconds: 200)
    }

    private func upload(_ id: String, _ title: String, channel: String, seconds: Int = 200) -> SearchBlend.Upload {
        SearchBlend.Upload(videoId: id, rawTitle: title, channel: channel, thumbnailUrl: nil, durationSeconds: seconds)
    }

    private func ids(_ tracks: [Track]) -> [String] { tracks.map(\.videoId) }

    // MARK: - Ranking

    /// The case this exists for. The catalogue only has Ella Langley's "Choosin' Texas"; Drake's
    /// is unreleased and exists only as uploads. "drake" is in the query and only the upload
    /// has it, so the upload leads.
    func testAnUploadThatAnswersTheQueryBetterLeads() {
        let songs = [
            song("ella", "Choosin' Texas", "Ella Langley", album: "Dandelion"),
            song("classic", "Classic", "Drake", album: "HABIBTI"),
        ]
        let uploads = [upload("drake", "Drake - Choosin’ Texas (Feat. Don Toliver)", channel: "dontolivervault")]

        let blended = SearchBlend.blend(songs: songs, uploads: uploads, query: "choosin texas drake")

        XCTAssertEqual(ids(blended), ["drake", "ella", "classic"])
        XCTAssertEqual(blended.first?.title, "Choosin’ Texas (Feat. Don Toliver)")
        XCTAssertEqual(blended.first?.artist, "Drake")
    }

    /// Without the artist in the query the upload answers it no better than the released songs,
    /// so it waits behind them — but ahead of songs that match less of the query.
    func testAnUploadThatMatchesOnlyAsWellWaitsBehindTheSongsThatDo() {
        let songs = [
            song("ella", "Choosin' Texas", "Ella Langley"),
            song("remix", "Choosin' Texas (House Remix)", "SorraB & Music Total"),
            song("classic", "Classic", "Drake"),
        ]
        let uploads = [upload("drake", "Drake - Choosin’ Texas (Feat. Don Toliver)", channel: "dontolivervault")]

        let blended = SearchBlend.blend(songs: songs, uploads: uploads, query: "choosin texas")

        XCTAssertEqual(ids(blended), ["ella", "remix", "drake", "classic"])
    }

    /// A search for a released song keeps its songs on top: every one of them already matches
    /// the whole query, and an upload has to match *more* to pass one.
    func testReleasedSongsStayAboveUploadsThatMatchNoBetter() {
        let songs = [song("snooze", "Snooze", "SZA", album: "SOS"), song("acoustic", "Snooze (Acoustic)", "SZA")]
        let uploads = [upload("rylo", "Rylo Rodriguez - Snooze (Kai Cenat) Official Audio", channel: "Rylo Rodriguez CBFW")]

        let blended = SearchBlend.blend(songs: songs, uploads: uploads, query: "sza snooze")

        XCTAssertEqual(Array(ids(blended).prefix(2)), ["snooze", "acoustic"])
    }

    /// An upload of a song that is already in the results is a worse copy of it — the video's
    /// edit and length, from a stranger's channel — so it isn't shown twice.
    func testAnUploadOfASongAlreadyListedIsDropped() {
        let songs = [song("snooze", "Snooze", "SZA", album: "SOS")]
        let uploads = [upload("copy", "SZA - Snooze (Official Audio)", channel: "some fan")]

        XCTAssertEqual(ids(SearchBlend.blend(songs: songs, uploads: uploads, query: "sza snooze")), ["snooze"])
    }

    /// Asking for the tag is asking for the uploads: "the weeknd unreleased" matches released
    /// songs only on "the weeknd".
    func testSearchingForUnreleasedPutsUnreleasedFirst() {
        let songs = [song("same", "Same Old Song (feat. Juicy J)", "The Weeknd", album: "Echoes of Silence")]
        let uploads = [upload("come", "The Weeknd - Come Through (Unreleased)", channel: "E33du")]

        let blended = SearchBlend.blend(songs: songs, uploads: uploads, query: "the weeknd unreleased")

        XCTAssertEqual(ids(blended), ["come", "same"])
        XCTAssertEqual(blended.first?.title, "Come Through (Unreleased)")
    }

    func testMixesTypeBeatsAndPlaylistsAreNotSongs() {
        let songs = [song("marvin", "Marvins Room", "Drake")]
        let uploads = [
            upload("beat", "(FREE) DRAKE TYPE BEAT - \"ALRIGHT\" | TRAP TYPE BEAT", channel: "SWAY WASSUP"),
            upload("mix", "Drake - Unreleased Mix", channel: "someone", seconds: 1_559),
            upload("list", "Vibes & Late Nights: The Best Drake Playlist", channel: "Cadence Cove"),
            upload("como", "Drake - Lake Como (HQ Unreleased Studio Verson) [FOMO]", channel: "Melttttdownnnnnn"),
        ]

        XCTAssertEqual(ids(SearchBlend.blend(songs: songs, uploads: uploads, query: "drake")), ["marvin", "como"])
    }

    func testAnUploadAboutSomethingElseIsNotShown() {
        let songs = [song("snooze", "Snooze", "SZA")]
        let uploads = [upload("other", "Kanye West - Runaway (Unreleased Verse)", channel: "yeezy vault")]

        XCTAssertEqual(ids(SearchBlend.blend(songs: songs, uploads: uploads, query: "sza snooze")), ["snooze"])
    }

    func testUploadsNeverOutnumberTheCap() {
        let songs = [song("a", "Some Song", "Someone")]
        let uploads = (0..<20).map { upload("u\($0)", "Drake - Leak \($0) (Unreleased)", channel: "vault") }

        let blended = SearchBlend.blend(songs: songs, uploads: uploads, query: "drake unreleased")

        XCTAssertEqual(blended.count, 1 + SearchBlend.maximumUploads)
    }

    /// The Videos filter for "sza snooze", as it came back: every one of these is the released
    /// song in other clothes, and all of them used to rank straight after it.
    func testLyricVideosKaraokeAndTheLikeAreNotShown() {
        let songs = [song("snooze", "Snooze", "SZA", album: "SOS")]
        let uploads = [
            upload("lyrics", "SZA - Snooze (Lyrics) \"i can't lose when i'm with you\"", channel: "BangersOnly"),
            upload("dance", "SZA - Snooze / goyu Choreography", channel: "MOVE Dance Studio"),
            upload("inst", "SZA - Snooze (Instrumental with Hook)", channel: "SoundVillage Atlanta"),
            upload("karaoke", "SZA - SNOOZE (Karaoke)", channel: "Mi Balmz Karaoke Tracks"),
            upload("remix", "SZA - Snooze (crwn Remix)", channel: "Pool Records"),
        ]

        XCTAssertEqual(ids(SearchBlend.blend(songs: songs, uploads: uploads, query: "sza snooze")), ["snooze", "remix"])
    }

    /// Unless the title says it is unreleased — then its lyric video is the only way to hear it.
    func testAnUnreleasedLyricVideoIsStillShown() {
        let uploads = [upload("wait", "PARTYNEXTDOOR - Wait For U (Unreleased) (Lyrics)", channel: "2K FRESH NETWORK")]
        XCTAssertEqual(ids(SearchBlend.blend(songs: [], uploads: uploads, query: "partynextdoor unreleased")), ["wait"])
    }

    func testAnUploadOfNothingButHashtagsIsNotShown() {
        let uploads = [upload("short", "#druski #drake #fyp", channel: "LemmeHearSomething")]
        XCTAssertEqual(SearchBlend.blend(songs: [], uploads: uploads, query: "drake"), [])
    }

    func testAMisspeltWordStillMatchesByPrefix() {
        let wanted = Set(TrackMatcher.words("choosing texas drake"))
        XCTAssertEqual(SearchBlend.coverage(of: wanted, in: ["Drake - Choosin’ Texas"]), 1)
    }

    // MARK: - Titles

    private func cleaned(_ title: String, channel: String = "a channel", known: [String] = [],
                         titles: [String] = []) -> Track {
        UploadTitle.track(from: upload("x", title, channel: channel), knownArtists: known, knownTitles: titles)
    }

    func testTheUsualArtistDashTitleIsSplit() {
        let track = cleaned("PARTYNEXTDOOR - Poppa / Wet My Whistle (Unreleased/Leak)", channel: "The Volume")
        XCTAssertEqual(track.artist, "PARTYNEXTDOOR")
        XCTAssertEqual(track.title, "Poppa / Wet My Whistle (Unreleased)")
    }

    func testATitleWrittenTheOtherWayRoundIsTurnedAround() {
        let track = cleaned("You Made It - PARTYNEXTDOOR [UNRELEASED]", channel: "WRLDTOBEHEARD",
                            known: ["PARTYNEXTDOOR", "Drake"])
        XCTAssertEqual(track.artist, "PARTYNEXTDOOR")
        XCTAssertEqual(track.title, "You Made It (Unreleased)")
    }

    /// Containing an artist is not the same as being one. Read loosely, the right side here
    /// "agreed" with Ella Langley and the song came out as "Drake" by "Choosin' Texas (REMIX)".
    func testASideThatOnlyMentionsAnArtistIsNotTurnedAround() {
        let track = cleaned("Drake - Choosin’ Texas (REMIX) ft. Ella Langley & Don Toliver", channel: "Milo",
                            known: ["Ella Langley", "LE MATai"])
        XCTAssertEqual(track.artist, "Drake")
        XCTAssertEqual(track.title, "Choosin’ Texas (REMIX) ft. Ella Langley & Don Toliver")
    }

    /// The left side is a song this search found, so it is not the artist; the credit after the
    /// bar is.
    func testASongTitleOnTheLeftIsNotTakenForTheArtist() {
        let track = cleaned("Choosin' Texas - 2AM Remix | Ella Langley ft BigXthaPlug", channel: "DJ Chad Wildman",
                            known: ["Ella Langley"], titles: ["Choosin' Texas"])
        XCTAssertEqual(track.artist, "Ella Langley")
        XCTAssertEqual(track.title, "Choosin' Texas - 2AM Remix (feat. BigXthaPlug)")
    }

    func testAFeatureWithNoSpaceAfterTheMarkerIsStillSplitOff() {
        let track = cleaned("Routine Rouge - PartyNextDoor ft.TyDolla$ign (unreleased)", channel: "triki",
                            known: ["PARTYNEXTDOOR"])
        XCTAssertEqual(track.artist, "PARTYNEXTDOOR")
        XCTAssertEqual(track.title, "Routine Rouge (feat. TyDolla$ign) (Unreleased)")
    }

    /// Without evidence the order stays as written — the far more common way round.
    func testNoEvidenceKeepsTheWrittenOrder() {
        let track = cleaned("Tongue - The Weeknd (unreleased)", channel: "Ishan Desai")
        XCTAssertEqual(track.artist, "Tongue")
    }

    func testAFeatureInTheCreditMovesIntoTheTitle() {
        let track = cleaned("Drake ft. Don Toliver - Choosin’ Texas Remix (Music Video) #drake #dontoliver")
        XCTAssertEqual(track.artist, "Drake")
        XCTAssertEqual(track.title, "Choosin’ Texas Remix (feat. Don Toliver)")
    }

    func testPackagingIsDroppedAndVariantsKept() {
        XCTAssertEqual(cleaned("Playboi Carti -  pissy pamper (kid cudi) HQ").title, "pissy pamper (kid cudi)")
        XCTAssertEqual(cleaned("Drake - Song (prod. Metro Boomin) [Official Audio]").title, "Song")
        XCTAssertEqual(cleaned("Drake & Don Toliver - CHOOSIN’ TEXAS (remix)").title, "CHOOSIN’ TEXAS (remix)")
        XCTAssertEqual(cleaned("The Weeknd - Fading Light ( Unreleased )").title, "Fading Light (Unreleased)")
    }

    func testTailsAfterABarAreDroppedUnlessTheyNameTheArtist() {
        let credited = cleaned("CHOOSIN’ TEXAS (REMIX) | Drake x Don Toliver x Ella Langley",
                               channel: "faint music", known: ["Drake"])
        XCTAssertEqual(credited.title, "CHOOSIN’ TEXAS (REMIX)")
        XCTAssertEqual(credited.artist, "Drake x Don Toliver x Ella Langley")

        let noise = cleaned("partynextdoor - fuk with me // PG (unreleased)", known: ["PARTYNEXTDOOR"])
        XCTAssertEqual(noise.title, "fuk with me (Unreleased)")
        XCTAssertEqual(noise.artist, "PARTYNEXTDOOR", "Written the way the catalogue spells it")
    }

    func testATitleWithNoArtistInItFallsBackToTheChannel() {
        let track = cleaned("kid cudi / pissy pamper ft liluzi, young nudy", channel: "amz")
        XCTAssertEqual(track.artist, "amz")
        XCTAssertEqual(track.title, "kid cudi / pissy pamper ft liluzi, young nudy")
    }
}
