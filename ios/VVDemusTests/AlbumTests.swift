import XCTest
@testable import VVDemus

/// Albums, end to end but offline: the two InnerTube shapes they arrive in, the rule that
/// puts them into the search list, the rule that removes one across two devices, and the
/// arithmetic behind Home's grid.
///
/// Every fixture below is trimmed from a real response captured against music.youtube.com,
/// with the tracking blobs and the thumbnail ladders cut down. They are fixtures rather than
/// live calls on purpose: what these tests are for is that a *reshaped* response produces a
/// nil or a named error instead of a half-parsed album — and a network that has to be up to
/// prove that is a network that will one day prove it by accident.
final class AlbumTests: XCTestCase {

    // MARK: - The Albums search shelf

    func testAnAlbumSearchRowYieldsEveryFieldTheBylineNeeds() throws {
        let album = try XCTUnwrap(
            InnerTubeClient.parseAlbumSearchItem(try JSON.parse(Data(Self.searchRow.utf8)))
        )

        XCTAssertEqual(album.browseId, "MPREb_7ltM34kr0mH")
        XCTAssertEqual(album.title, "Discovery")
        XCTAssertEqual(album.artist, "Daft Punk")
        XCTAssertEqual(album.kind, "Album")
        XCTAssertEqual(album.year, "2001")
        XCTAssertEqual(album.audioPlaylistId, "OLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw")
        XCTAssertEqual(album.subtitle, "Album · Daft Punk · 2001")
        XCTAssertEqual(album.thumbnailUrl?.hasSuffix("=w544-h544-l90-rj"), true,
                       "the largest thumbnail in the ladder, not the 60px one at the front")
    }

    /// The Albums filter is not a guarantee. The same shelf shape carries artist rows
    /// (`UC…`) and playlist rows (`VL…`), and browsing either as an album returns something
    /// that is not one — an artist page has no track shelf at all, so it would come back as
    /// "this album came back empty" from a row that looked perfectly ordinary.
    func testARowThatIsNotAReleaseIsRejected() throws {
        let artistRow = Self.searchRow.replacingOccurrences(
            of: "MPREb_7ltM34kr0mH",
            with: "UCRr1xG_2WIDs18a6cIiCxeA"
        )
        XCTAssertNil(InnerTubeClient.parseAlbumSearchItem(try JSON.parse(Data(artistRow.utf8))))
    }

    /// A release with no year still has to produce a usable byline rather than a trailing
    /// separator — unreleased singles and a good deal of the long tail come back this way.
    func testAReleaseWithNoYearDropsThatPartOfTheByline() throws {
        let album = try XCTUnwrap(
            InnerTubeClient.parseAlbumSearchItem(try JSON.parse(Data(Self.searchRowWithoutYear.utf8)))
        )

        XCTAssertNil(album.year)
        XCTAssertEqual(album.subtitle, "Album · Daft Punk")
    }

    /// The label run and the year run are both plain text with no navigation endpoint, so
    /// only their *shape* separates them. A four-digit-looking label would be read as a year;
    /// nothing else should be.
    func testOnlyAFourDigitNumberCountsAsAYear() {
        XCTAssertTrue(InnerTubeClient.isYear("2001"))
        XCTAssertFalse(InnerTubeClient.isYear("Album"))
        XCTAssertFalse(InnerTubeClient.isYear("EP"))
        XCTAssertFalse(InnerTubeClient.isYear("201"))
        XCTAssertFalse(InnerTubeClient.isYear("20014"))
        XCTAssertFalse(InnerTubeClient.isYear("200s"))
    }

    // MARK: - The album page

    func testAnAlbumPageYieldsItsHeaderAndEveryTrack() throws {
        let page = try InnerTubeClient.parseAlbumPage(
            try JSON.parse(Data(Self.albumPage.utf8)),
            browseId: "MPREb_7ltM34kr0mH"
        )

        XCTAssertEqual(page.album.title, "Discovery")
        XCTAssertEqual(page.album.artist, "Daft Punk")
        XCTAssertEqual(page.album.kind, "Album")
        XCTAssertEqual(page.album.year, "2001")
        XCTAssertEqual(page.album.audioPlaylistId, "OLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw")

        XCTAssertEqual(page.tracks.map(\.title), ["One More Time", "Aerodynamic", "Face to Face"])
        XCTAssertEqual(page.tracks.map(\.videoId), ["FGBhQbmPwH8", "L93-7vRfxNs", "iBqNsFvL9BE"])
    }

    /// The track rows carry no artwork and, on a single-artist album, no artist either — the
    /// page states both once at the top. Left unfilled the queue, the play history and the
    /// listening stats all end up holding rows by "Unknown Artist" with no cover.
    func testTracksInheritTheAlbumsArtworkAndArtist() throws {
        let page = try InnerTubeClient.parseAlbumPage(
            try JSON.parse(Data(Self.albumPage.utf8)),
            browseId: "MPREb_7ltM34kr0mH"
        )

        XCTAssertEqual(page.tracks[0].artist, "Daft Punk")
        XCTAssertEqual(page.tracks[0].album, "Discovery")
        XCTAssertEqual(Set(page.tracks.compactMap(\.thumbnailUrl)).count, 1,
                       "one cover, shared by every row")
        XCTAssertEqual(page.tracks[0].thumbnailUrl, page.album.thumbnailUrl)
    }

    /// A guest credit *is* present on the row, and has to win over the album's artist — this
    /// is the compilation case, where inheriting would relabel every track with one name.
    func testAGuestCreditOnTheRowBeatsTheAlbumArtist() throws {
        let page = try InnerTubeClient.parseAlbumPage(
            try JSON.parse(Data(Self.albumPage.utf8)),
            browseId: "MPREb_7ltM34kr0mH"
        )
        XCTAssertEqual(page.tracks[2].artist, "Daft Punk, Todd Edwards")
    }

    /// The duration lives in a `fixedColumns` entry, not in the byline runs, so the parser
    /// that reads a search row's "3:45" cannot be reused here. Getting this wrong leaves
    /// every seek bar and every listening-stats figure on the album at zero.
    func testDurationsComeFromTheFixedColumn() throws {
        let page = try InnerTubeClient.parseAlbumPage(
            try JSON.parse(Data(Self.albumPage.utf8)),
            browseId: "MPREb_7ltM34kr0mH"
        )
        XCTAssertEqual(page.tracks.map(\.durationSeconds), [321, 213, 240])
    }

    /// An album page that parsed to nothing is a reshaped response, not a record with no
    /// songs on it. It has to throw so the screen offers a retry — returning an empty page
    /// would be cached and served as an empty album forever.
    func testAPageWithNoTrackShelfThrows() throws {
        let empty = #"{"contents":{"twoColumnBrowseResultsRenderer":{"tabs":[],"secondaryContents":{}}}}"#
        XCTAssertThrowsError(
            try InnerTubeClient.parseAlbumPage(try JSON.parse(Data(empty.utf8)), browseId: "MPREb_x")
        )
    }

    // MARK: - Interleaving albums into search results

    /// The top song stays first. A query that names a song must not be answered by an album,
    /// and YouTube's album filter returns *something* for any query at all — so the first row
    /// is the one place an album can never go.
    func testTheTopSongStaysFirstAndTheFirstAlbumFollowsIt() {
        let results = SearchResult.interleave(
            tracks: (0..<10).map { Self.track("t\($0)") },
            albums: [Self.album("a0"), Self.album("a1")]
        )

        XCTAssertEqual(Self.shape(results), ["t0", "a0", "t1", "t2", "t3", "t4", "a1", "t5", "t6", "t7", "t8", "t9"])
    }

    /// Releases that outlast the song list are appended rather than dropped: a query matching
    /// four albums and one song should still show all four.
    func testAlbumsOutLastingTheSongsAreAppended() {
        let results = SearchResult.interleave(
            tracks: [Self.track("t0")],
            albums: [Self.album("a0"), Self.album("a1"), Self.album("a2")]
        )
        XCTAssertEqual(Self.shape(results), ["t0", "a0", "a1", "a2"])
    }

    func testNoAlbumsLeavesTheSongListExactlyAsItWas() {
        let results = SearchResult.interleave(tracks: [Self.track("t0"), Self.track("t1")], albums: [])
        XCTAssertEqual(Self.shape(results), ["t0", "t1"])
    }

    func testNoSongsStillShowsTheAlbums() {
        let results = SearchResult.interleave(tracks: [], albums: [Self.album("a0")])
        XCTAssertEqual(Self.shape(results), ["a0"])
    }

    /// A song and a release cannot share an id today — `videoId` and `browseId` are different
    /// namespaces — but nothing enforces that, and two equal ids inside a `ForEach` silently
    /// drop a row rather than failing.
    func testSongAndAlbumIdsCannotCollide() {
        let track = Track(videoId: "same", title: "t", artist: "a", album: nil, thumbnailUrl: nil, durationSeconds: 1)
        let album = Self.album("same")
        XCTAssertNotEqual(SearchResult.track(track).id, SearchResult.album(album).id)
    }

    // MARK: - Removing an album across two devices

    /// The headline sync case, and the reason these are tombstones: a removal on one device
    /// has to survive meeting a device that still has the album, or the next round hands it
    /// straight back and "Remove Album" looks broken rather than slow.
    func testARemovalBeatsAnOlderCopyThatStillHasTheAlbum() {
        let kept = Self.record("MPREb_1", openedAt: -500, stamp: ("phone", -500))
        let removed = AlbumRecord(
            album: Self.album("MPREb_1"),
            lastOpenedAt: Date().addingTimeInterval(-500),
            removedAt: Date().addingTimeInterval(-10),
            stamp: Self.stamp("mac", -10)
        )

        let merged = AlbumRecord.merging([kept], [removed])

        XCTAssertEqual(merged.changed, 1)
        XCTAssertEqual(AlbumRecord.present(merged.records, limit: 20), [])
    }

    /// And the other direction: re-opening an album after removing it on the other device
    /// brings it back, because that edit is the later one.
    func testReopeningAfterARemovalElsewhereBringsItBack() {
        let removed = AlbumRecord(
            album: Self.album("MPREb_1"),
            lastOpenedAt: Date().addingTimeInterval(-500),
            removedAt: Date().addingTimeInterval(-100),
            stamp: Self.stamp("mac", -100)
        )
        let reopened = Self.record("MPREb_1", openedAt: -5, stamp: ("phone", -5))

        let merged = AlbumRecord.merging([removed], [reopened])

        XCTAssertEqual(AlbumRecord.present(merged.records, limit: 20).map(\.browseId), ["MPREb_1"])
    }

    /// Merging has to be idempotent — a sync round replays records the peer already sent, and
    /// a merge that reported those as changes would announce a library edit back at the peer
    /// that sent it, which is how two devices ping-pong forever.
    func testReceivingTheSameRecordTwiceChangesNothing() {
        let record = Self.record("MPREb_1", openedAt: -100, stamp: ("phone", -100))
        let once = AlbumRecord.merging([], [record])
        let twice = AlbumRecord.merging(once.records, [record])

        XCTAssertEqual(once.changed, 1)
        XCTAssertEqual(twice.changed, 0)
        XCTAssertEqual(twice.records, once.records)
    }

    /// Two devices merging the same pair of records in opposite orders must land on the same
    /// list, without talking to each other.
    func testBothDevicesConvergeOnTheSameOrder() {
        let onPhone = Self.record("MPREb_1", openedAt: -50, stamp: ("phone", -50))
        let onMac = Self.record("MPREb_2", openedAt: -50, stamp: ("mac", -50))

        let phoneView = AlbumRecord.present(AlbumRecord.merging([onPhone], [onMac]).records, limit: 20)
        let macView = AlbumRecord.present(AlbumRecord.merging([onMac], [onPhone]).records, limit: 20)

        XCTAssertEqual(phoneView.map(\.browseId), macView.map(\.browseId),
                       "identical timestamps must tiebreak deterministically, not by insertion order")
    }

    /// The cap belongs to the projection, not to storage. Trimming the records would make
    /// falling off the end indistinguishable from a deletion.
    func testTheCapHidesRecordsWithoutDeletingThem() {
        let records = (0..<25).map { Self.record("MPREb_\($0)", openedAt: -Double($0), stamp: ("phone", -Double($0))) }

        XCTAssertEqual(AlbumRecord.present(records, limit: 20).count, 20)
        XCTAssertEqual(records.count, 25, "storage keeps every one")
        XCTAssertEqual(AlbumRecord.present(records, limit: 20).first?.browseId, "MPREb_0",
                       "newest first")
    }

    // MARK: - Home's shortcut grid

    /// The point of the ordering change: one list across all four kinds. Grouped by kind, an
    /// album opened a minute ago sat behind every radio however stale, and the cap then hid
    /// it entirely.
    func testAJustOpenedAlbumOutranksAStaleRadio() {
        let ranked = HomeShortcuts.ranked(
            hasLikedSongs: false,
            radios: [Self.station("old", playedAt: -100_000)],
            playlists: [],
            albums: [Self.album("MPREb_new")],
            albumOpenedAt: { _ in Date().addingTimeInterval(-60) },
            openedAt: { _ in nil }
        )

        XCTAssertEqual(ranked.map(\.id), ["album-MPREb_new", "radio-old"])
    }

    /// A playlist's only timestamp of its own is `createdAt`, which says nothing about when
    /// you last looked at it. This is the whole reason `RecentOpensStore` exists.
    func testAnOldPlaylistOpenedRecentlySortsAsRecent() {
        let ancient = Playlist(name: "Chill", tracks: [], createdAt: Date().addingTimeInterval(-1_000_000))
        let openKey = RecentOpensStore.playlistKey(ancient.id)

        let ranked = HomeShortcuts.ranked(
            hasLikedSongs: false,
            radios: [Self.station("yesterday", playedAt: -86_400)],
            playlists: [ancient],
            albums: [],
            albumOpenedAt: { _ in nil },
            openedAt: { $0 == openKey ? Date().addingTimeInterval(-30) : nil }
        )

        XCTAssertEqual(ranked.first?.id, "playlist-\(ancient.id)")
    }

    /// Liked Songs is a place, not a thing you open. It is pinned so it doesn't move about
    /// the grid as everything else reshuffles — and it is absent entirely when empty.
    func testLikedSongsIsPinnedFirstAndOnlyWhenItHasSongs() {
        let radios = [Self.station("r", playedAt: -1)]

        let withLikes = HomeShortcuts.ranked(
            hasLikedSongs: true, radios: radios, playlists: [], albums: [],
            albumOpenedAt: { _ in nil }, openedAt: { _ in nil }
        )
        let without = HomeShortcuts.ranked(
            hasLikedSongs: false, radios: radios, playlists: [], albums: [],
            albumOpenedAt: { _ in nil }, openedAt: { _ in nil }
        )

        XCTAssertEqual(withLikes.first?.id, "liked")
        XCTAssertFalse(without.contains { $0.id == "liked" })
    }

    /// A radio read but never played only moves its open log, not its `lastPlayedAt`.
    func testOpeningARadioWithoutPlayingItStillCounts() {
        let station = Self.station("r", playedAt: -100_000)
        let ranked = HomeShortcuts.ranked(
            hasLikedSongs: false,
            radios: [station],
            playlists: [Playlist(name: "New", tracks: [], createdAt: Date().addingTimeInterval(-500))],
            albums: [],
            albumOpenedAt: { _ in nil },
            openedAt: { $0 == RecentOpensStore.radioKey("r") ? Date().addingTimeInterval(-10) : nil }
        )

        XCTAssertEqual(ranked.first?.id, "radio-r")
    }

    // MARK: - Grid geometry

    /// The formula has to agree with what `LazyVGrid(.adaptive(minimum:))` does privately,
    /// because the tile count is chosen from it and the layout is not.
    func testColumnCountMatchesWhatFitsAtEachWidth() {
        // 160pt minimum, 12pt gaps: n columns need n * 160 + (n - 1) * 12.
        XCTAssertEqual(ShortcutGridMetrics.columns(fitting: 343, spacing: 12), 2, "narrowest phone")
        XCTAssertEqual(ShortcutGridMetrics.columns(fitting: 331, spacing: 12), 1)
        XCTAssertEqual(ShortcutGridMetrics.columns(fitting: 332, spacing: 12), 2)
        XCTAssertEqual(ShortcutGridMetrics.columns(fitting: 503, spacing: 12), 2)
        XCTAssertEqual(ShortcutGridMetrics.columns(fitting: 504, spacing: 12), 3)
        XCTAssertEqual(ShortcutGridMetrics.columns(fitting: 1191, spacing: 12), 6)
        XCTAssertEqual(ShortcutGridMetrics.columns(fitting: 1192, spacing: 12), 7, "7 * 160 + 6 * 12")
    }

    /// Width zero is the first frame, before the grid has been measured. It must not resolve
    /// to zero tiles — Home would flash its empty state at someone with a full library.
    func testAnUnmeasuredGridStillOffersThePhonesSix() {
        XCTAssertEqual(ShortcutGridMetrics.columns(fitting: 0, spacing: 12), 1)
        XCTAssertEqual(ShortcutGridMetrics.visibleCount(available: 20, columns: 1), 6)
    }

    /// The desktop change: fill the window rather than stopping at six with a third of the
    /// row empty — and stop at two rows, so Home still leads to the shelves underneath.
    func testAWideGridFillsTwoRowsAndStops() {
        XCTAssertEqual(ShortcutGridMetrics.visibleCount(available: 20, columns: 6), 12)
        XCTAssertEqual(ShortcutGridMetrics.visibleCount(available: 20, columns: 4), 8)
        XCTAssertEqual(ShortcutGridMetrics.visibleCount(available: 20, columns: 3), 6)
    }

    /// The phone keeps six — three rows of two — which is more rows than the desktop cap
    /// allows, deliberately: two rows of two is four tiles.
    func testThePhoneShowsSix() {
        XCTAssertEqual(ShortcutGridMetrics.visibleCount(available: 20, columns: 2), 6)
    }

    /// Two columns and an odd count leaves a half-width hole at the end of the last row. A
    /// lone shortcut is exempt, or it would vanish from Home entirely.
    func testATwoColumnGridTrimsToAnEvenCountButNeverToNothing() {
        XCTAssertEqual(ShortcutGridMetrics.visibleCount(available: 5, columns: 2), 4)
        XCTAssertEqual(ShortcutGridMetrics.visibleCount(available: 3, columns: 2), 2)
        XCTAssertEqual(ShortcutGridMetrics.visibleCount(available: 1, columns: 2), 1)
        XCTAssertEqual(ShortcutGridMetrics.visibleCount(available: 0, columns: 2), 0)
    }

    /// A wide window is left ragged on purpose. Trimming seven items to five to square off a
    /// five-column grid would hide two of them to fix a gap nobody reads as broken.
    func testAWideGridIsLeftRaggedRatherThanTrimmed() {
        XCTAssertEqual(ShortcutGridMetrics.visibleCount(available: 7, columns: 5), 7)
    }

    // MARK: - Wire compatibility

    /// The two devices update independently, so a build that knows about albums has to decode
    /// a payload from one that does not. A synthesised `Decodable` throws on a missing key
    /// even when the property has a default, which is why `albums` is an optional.
    func testAPayloadFromABuildWithoutAlbumsStillDecodes() throws {
        let legacy = """
        {"peerId":"old-phone","likes":[],"playlists":[],"radios":[],"generated":[],
         "recentSearches":[],"events":[]}
        """
        let payload = try JSONDecoder().decode(SyncPayload.self, from: Data(legacy.utf8))

        XCTAssertEqual(payload.openedAlbums, [])
    }

    // MARK: - Fixtures

    private static func track(_ id: String) -> Track {
        Track(videoId: id, title: id, artist: "Artist", album: nil, thumbnailUrl: nil, durationSeconds: 100)
    }

    private static func album(_ browseId: String) -> Album {
        Album(browseId: browseId, title: browseId, artist: "Artist", kind: "Album",
              year: nil, thumbnailUrl: nil, audioPlaylistId: nil)
    }

    private static func station(_ videoId: String, playedAt: TimeInterval) -> RadioStation {
        RadioStation(seedTrack: track(videoId), lastPlayedAt: Date().addingTimeInterval(playedAt))
    }

    private static func stamp(_ peer: String, _ offset: TimeInterval) -> EditStamp {
        EditStamp(editedAt: Date().addingTimeInterval(offset), editedBy: peer)
    }

    private static func record(
        _ browseId: String,
        openedAt: TimeInterval,
        stamp: (String, TimeInterval)
    ) -> AlbumRecord {
        AlbumRecord(
            album: album(browseId),
            lastOpenedAt: Date().addingTimeInterval(openedAt),
            removedAt: nil,
            stamp: Self.stamp(stamp.0, stamp.1)
        )
    }

    /// Results as a flat list of ids, so an assertion reads as the row order on screen.
    private static func shape(_ results: [SearchResult]) -> [String] {
        results.map {
            switch $0 {
            case .track(let track): return track.videoId
            case .album(let album): return album.browseId
            }
        }
    }

    /// One `musicResponsiveListItemRenderer` from the Albums search shelf.
    private static let searchRow = """
    {
      "thumbnail": {"musicThumbnailRenderer": {"thumbnail": {"thumbnails": [
        {"url": "https://yt3.googleusercontent.com/qrY7=w60-h60-l90-rj", "width": 60, "height": 60},
        {"url": "https://yt3.googleusercontent.com/qrY7=w544-h544-l90-rj", "width": 544, "height": 544}
      ]}}},
      "overlay": {"musicItemThumbnailOverlayRenderer": {"content": {"musicPlayButtonRenderer": {
        "playNavigationEndpoint": {"watchPlaylistEndpoint": {
          "playlistId": "OLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw"
        }}
      }}}},
      "flexColumns": [
        {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "Discovery"}]}}},
        {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [
          {"text": "Album"},
          {"text": " • "},
          {"text": "Daft Punk", "navigationEndpoint": {"browseEndpoint": {
            "browseId": "UCRr1xG_2WIDs18a6cIiCxeA"
          }}},
          {"text": " • "},{"text": "2001"}
        ]}}}
      ],
      "navigationEndpoint": {"browseEndpoint": {"browseId": "MPREb_7ltM34kr0mH"}}
    }
    """

    /// The same row as a single with no release year, which is how a good deal of the long
    /// tail comes back: three runs instead of five, and the label is "Single".
    private static let searchRowWithoutYear = """
    {
      "flexColumns": [
        {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "Discovery"}]}}},
        {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [
          {"text": "Album"},
          {"text": " • "},
          {"text": "Daft Punk", "navigationEndpoint": {"browseEndpoint": {
            "browseId": "UCRr1xG_2WIDs18a6cIiCxeA"
          }}}
        ]}}}
      ],
      "navigationEndpoint": {"browseEndpoint": {"browseId": "MPREb_7ltM34kr0mH"}}
    }
    """

    /// An album `browse` response, cut to three tracks. The second section is the
    /// "Releases for you" carousel that really does follow the track shelf — it is here
    /// because the shelf is *found* rather than indexed, and a fixture with only one section
    /// would not prove that.
    private static let albumPage = """
    {"contents": {"twoColumnBrowseResultsRenderer": {
      "tabs": [{"tabRenderer": {"content": {"sectionListRenderer": {"contents": [
        {"musicResponsiveHeaderRenderer": {
          "thumbnail": {"musicThumbnailRenderer": {"thumbnail": {"thumbnails": [
            {"url": "https://yt3.googleusercontent.com/qrY7=w544-h544-l90-rj"}
          ]}}},
          "title": {"runs": [{"text": "Discovery"}]},
          "straplineTextOne": {"runs": [{"text": "Daft Punk", "navigationEndpoint": {
            "browseEndpoint": {"browseId": "UCRr1xG_2WIDs18a6cIiCxeA"}
          }}]},
          "subtitle": {"runs": [{"text": "Album"}, {"text": " • "}, {"text": "2001"}]},
          "secondSubtitle": {"runs": [{"text": "14 songs"}, {"text": " • "}, {"text": "1 hour, 1 minute"}]}
        }}
      ]}}}}],
      "secondaryContents": {"sectionListRenderer": {"contents": [
        {"musicShelfRenderer": {"contents": [
          {"musicResponsiveListItemRenderer": {
            "overlay": {"musicItemThumbnailOverlayRenderer": {"content": {"musicPlayButtonRenderer": {
              "playNavigationEndpoint": {"watchEndpoint": {
                "videoId": "FGBhQbmPwH8",
                "playlistId": "OLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw"
              }}
            }}}},
            "flexColumns": [
              {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "One More Time"}]}}},
              {"musicResponsiveListItemFlexColumnRenderer": {"text": {}}},
              {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "840M plays"}]}}}
            ],
            "fixedColumns": [
              {"musicResponsiveListItemFixedColumnRenderer": {"text": {"runs": [{"text": "5:21"}]}}}
            ],
            "playlistItemData": {"videoId": "FGBhQbmPwH8"}
          }},
          {"musicResponsiveListItemRenderer": {
            "flexColumns": [
              {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "Aerodynamic"}]}}},
              {"musicResponsiveListItemFlexColumnRenderer": {"text": {}}}
            ],
            "fixedColumns": [
              {"musicResponsiveListItemFixedColumnRenderer": {"text": {"runs": [{"text": "3:33"}]}}}
            ],
            "playlistItemData": {"videoId": "L93-7vRfxNs"}
          }},
          {"musicResponsiveListItemRenderer": {
            "flexColumns": [
              {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "Face to Face"}]}}},
              {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [
                {"text": "Daft Punk"}, {"text": " • "}, {"text": "Todd Edwards"}
              ]}}}
            ],
            "fixedColumns": [
              {"musicResponsiveListItemFixedColumnRenderer": {"text": {"runs": [{"text": "4:00"}]}}}
            ],
            "playlistItemData": {"videoId": "iBqNsFvL9BE"}
          }}
        ]}},
        {"musicCarouselShelfRenderer": {"contents": []}}
      ]}}
    }}}
    """
}
