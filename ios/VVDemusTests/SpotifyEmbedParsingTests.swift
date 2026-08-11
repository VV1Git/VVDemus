import XCTest
@testable import VVDemus

/// `SpotifyImportClient.parse(html:)`, the part of the Spotify import that Spotify itself
/// controls and can change without telling anyone.
///
/// Everything here runs against fixtures, never the live embed: the point of these tests is
/// that a reshaped page produces a named error and an honest message instead of a crash, an
/// empty playlist, or a playlist quietly missing half its songs — and a network that has to
/// be up to prove that is a network that will one day prove it by accident.
final class SpotifyEmbedParsingTests: XCTestCase {

    // MARK: - The page as Spotify really serves it

    func testARealisticPageYieldsTheNameAndEveryTrack() throws {
        let page = try SpotifyImportClient.parse(html: SpotifyEmbedFixture.page())

        XCTAssertEqual(page.name, "Today’s Top Hits",
                       "The captured page's name carries a curly apostrophe; a parser that mangles "
                       + "UTF-8 shows up here first and nowhere else")
        XCTAssertEqual(page.tracks.count, 6)
        XCTAssertEqual(page.tracks.first,
                       SpotifyTrack(title: "stupid song", artist: "Olivia Rodrigo", durationMs: 209_680),
                       "title -> title, subtitle -> artist, duration stays in milliseconds")
        XCTAssertEqual(page.tracks.last?.title, "Babydoll", "Tracks must come out in Spotify's order")
    }

    /// Spotify comma-joins multiple artists into one `subtitle` string, which happens to be
    /// exactly what `InnerTubeClient.parseSearchItem` produces on the YouTube side. Splitting
    /// it here would break that symmetry, so the string stays whole.
    ///
    /// It does *not* stay byte-for-byte, though, and that is the point of this test: the
    /// separator Spotify ships is a comma and a **non-breaking** space. Nothing on screen or
    /// in a failure message shows the difference, so an artist string that never equals
    /// YouTube's would have surfaced as "songs by two people just never match", months later
    /// and nowhere near this file.
    func testAMultiArtistSubtitleIsKeptWholeButLosesItsNonBreakingSpace() throws {
        let page = try SpotifyImportClient.parse(html: SpotifyEmbedFixture.page())

        XCTAssertEqual(page.tracks[3], SpotifyTrack(title: "Dai Dai",
                                                    artist: "Shakira, Burna Boy",
                                                    durationMs: 223_448))
        XCTAssertFalse(page.tracks[3].artist.unicodeScalars.contains("\u{00A0}"),
                       "U+00A0 has to be gone by the time the matcher and the search URL see it")
    }

    func testDurationsThatMeanNothingBecomeNilRatherThanZero() throws {
        let rows = [
            SpotifyEmbedFixture.Row("No duration key", "A", duration: nil),
            SpotifyEmbedFixture.Row("Zero duration", "B", duration: 0),
            SpotifyEmbedFixture.Row("Real duration", "C", duration: 1_000),
        ]
        let page = try SpotifyImportClient.parse(html: SpotifyEmbedFixture.page(rows: rows))

        XCTAssertNil(page.tracks[0].durationMs, "A missing key is not a zero-length song")
        XCTAssertNil(page.tracks[1].durationMs,
                     "Spotify sends 0 for a duration it doesn't know; passed on as 0 it would make "
                     + "the matcher reject every candidate for being the wrong length")
        XCTAssertEqual(page.tracks[2].durationMs, 1_000)
    }

    /// Seen on at least one embed variant, and a whole import is too much to lose over the
    /// difference between `223448` and `"223448"`.
    func testADurationServedAsAStringIsStillUnderstood() throws {
        let entity = #"{"type": "playlist", "name": "P", "trackList": ["#
            + #"{"title": "T", "subtitle": "A", "duration": "223448", "isPlayable": true}]}"#
        let html = SpotifyEmbedFixture.html(nextData: SpotifyEmbedFixture.nextDataJSON(entityJSON: entity))

        XCTAssertEqual(try SpotifyImportClient.parse(html: html).tracks.first?.durationMs, 223_448)
    }

    // MARK: - Truncation

    /// The embed stops at 100 no matter how long the playlist is (three 150-200 song
    /// playlists all came back with exactly 100), and Spotify has closed the anonymous token
    /// endpoint, so there is no way to learn the real total. 100 therefore means "possibly
    /// more" and the user has to be told.
    func testExactlyOneHundredTracksIsReportedAsPossiblyTruncated() throws {
        let page = try SpotifyImportClient.parse(
            html: SpotifyEmbedFixture.page(rows: SpotifyEmbedFixture.rows(count: 100)))

        XCTAssertEqual(page.tracks.count, 100)
        XCTAssertTrue(page.isPossiblyTruncated)
    }

    func testAFiftyTrackPlaylistIsNotReportedAsTruncated() throws {
        let page = try SpotifyImportClient.parse(
            html: SpotifyEmbedFixture.page(rows: SpotifyEmbedFixture.rows(count: 50)))

        XCTAssertEqual(page.tracks.count, 50)
        XCTAssertFalse(page.isPossiblyTruncated,
                       "Warning about truncation on a playlist that came back whole teaches the user "
                       + "to ignore the warning that matters")
    }

    func testNinetyNineTracksSitJustBelowTheLimit() throws {
        let page = try SpotifyImportClient.parse(
            html: SpotifyEmbedFixture.page(rows: SpotifyEmbedFixture.rows(count: 99)))

        XCTAssertFalse(page.isPossiblyTruncated, "The flag is >= 100, and 99 is the edge that proves it")
    }

    // MARK: - Pages that are not what we asked for

    /// `<script>` tag attributes are Spotify's to reorder, and a build change that emits
    /// `type` before `id`, or adds a CSP nonce, must not break the import.
    func testTheTagIsFoundWhateverOrderAndSpacingItsAttributesArriveIn() throws {
        let data = SpotifyEmbedFixture.nextDataJSON(entityJSON: SpotifyEmbedFixture.entityJSON())
        let variants = [
            #"type="application/json" id="__NEXT_DATA__""#,
            #"  id = "__NEXT_DATA__"   type="application/json"  nonce="abc123""#,
            #"id='__NEXT_DATA__' type='application/json'"#,
            #"crossorigin id="__NEXT_DATA__""#,
        ]

        for attributes in variants {
            let html = SpotifyEmbedFixture.html(nextData: data, attributes: attributes)
            let page = try SpotifyImportClient.parse(html: html)
            XCTAssertEqual(page.tracks.count, 6, "Attributes <\(attributes)> should still find the payload")
        }
    }

    /// The fixture puts a different `application/json` script tag *before* the payload, which
    /// is what the real page does. Matching on the type attribute alone would read the decoy.
    func testAnotherJsonScriptTagIsNotMistakenForThePayload() throws {
        let page = try SpotifyImportClient.parse(html: SpotifyEmbedFixture.page())

        XCTAssertEqual(page.name, "Today’s Top Hits")
    }

    /// Next.js escapes `<` as `\u003c` inside the payload precisely so a song called
    /// `</script>` cannot end the tag early — but the extractor still has to stop at the
    /// *first* `</script>` rather than the last one on the page.
    func testATitleContainingAScriptTagDoesNotTruncateThePayload() throws {
        let entity = #"{"type": "playlist", "name": "P", "trackList": ["#
            + #"{"title": "\u003c/script\u003e", "subtitle": "A", "duration": 1000, "isPlayable": true},"#
            + #"{"title": "Second", "subtitle": "B", "duration": 2000, "isPlayable": true}]}"#
        let html = SpotifyEmbedFixture.html(nextData: SpotifyEmbedFixture.nextDataJSON(entityJSON: entity))

        let page = try SpotifyImportClient.parse(html: html)
        XCTAssertEqual(page.tracks.map(\.title), ["</script>", "Second"],
                       "The payload must survive a song title that looks like markup")
    }

    func testAPageWithNoNextDataTagIsUnreadable() {
        let html = "<!DOCTYPE html><html><body><p>Something else entirely</p></body></html>"

        assertParseFails(html, with: .unreadable)
    }

    func testMalformedJsonInsideTheTagIsUnreadable() {
        let html = SpotifyEmbedFixture.html(nextData: #"{"props": {"pageProps": {"state": "#)

        assertParseFails(html, with: .unreadable,
                         "A half-written payload must be an error, not an empty playlist")
    }

    func testAPayloadShapedNothingLikeThePageIsUnreadable() {
        let html = SpotifyEmbedFixture.html(nextData: #"{"props": {"somethingNew": {}}}"#)

        assertParseFails(html, with: .unreadable)
    }

    /// An album embed carries a perfectly good `trackList`, so without the type check an
    /// album link would import silently and look like it worked — verified against
    /// `open.spotify.com/embed/album/…`, which returns `"type": "album"` and 18 tracks.
    func testAnAlbumPageIsRejectedRatherThanImportedAsAPlaylist() {
        let html = SpotifyEmbedFixture.page(type: "album")

        assertParseFails(html, with: .unreadable)
    }

    func testAnEntityWithNoTypeAtAllIsRejected() {
        assertParseFails(SpotifyEmbedFixture.page(type: nil), with: .unreadable)
    }

    /// A playlist that is private or deleted answers HTTP **200** with a complete page whose
    /// `data` object is simply `{}` — checked against
    /// `open.spotify.com/embed/playlist/0000000000000000000000`, which is a 200. So the
    /// status code alone can never produce `.notAvailable`; the missing entity has to.
    func testAPrivateOrDeletedPlaylistIsReportedAsUnavailableNotAsAShapeChange() {
        let html = SpotifyEmbedFixture.html(
            nextData: SpotifyEmbedFixture.nextDataJSON(entityJSON: nil))

        assertParseFails(html, with: .notAvailable,
                         "Telling the user Spotify changed their page, when really they pasted a "
                         + "private playlist, sends them to report a bug that isn't one")
    }

    // MARK: - Tracks

    /// `isPlayable: false` on the embed usually means the track is region-blocked *on
    /// Spotify*, which says nothing about YouTube Music. Dropping those rows would silently
    /// lose songs the user can actually have, and the run already reports anything that
    /// fails to match as a miss — so they are kept and allowed to fail honestly.
    func testUnplayableTracksAreKeptBecauseYouTubeMayStillHaveThem() throws {
        let rows = [
            SpotifyEmbedFixture.Row("Blocked here", "A", duration: 1_000, isPlayable: false),
            SpotifyEmbedFixture.Row("Fine", "B", duration: 2_000),
        ]
        let page = try SpotifyImportClient.parse(html: SpotifyEmbedFixture.page(rows: rows))

        XCTAssertEqual(page.tracks.map(\.title), ["Blocked here", "Fine"])
    }

    func testATrackWithNoTitleIsDroppedBecauseThereIsNothingToSearchFor() throws {
        let rows = [
            SpotifyEmbedFixture.Row(nil, "A", duration: 1_000),
            SpotifyEmbedFixture.Row("   ", "B", duration: 2_000),
            SpotifyEmbedFixture.Row("Real", "C", duration: 3_000),
        ]
        let page = try SpotifyImportClient.parse(html: SpotifyEmbedFixture.page(rows: rows))

        XCTAssertEqual(page.tracks.map(\.title), ["Real"],
                       "An empty query would return whatever YouTube feels like and add a stranger's "
                       + "song to the playlist")
    }

    func testAMissingSubtitleLeavesTheArtistEmptyRatherThanFailingTheWholeImport() throws {
        let rows = [SpotifyEmbedFixture.Row("Lonely", nil, duration: 1_000)]
        let page = try SpotifyImportClient.parse(html: SpotifyEmbedFixture.page(rows: rows))

        XCTAssertEqual(page.tracks, [SpotifyTrack(title: "Lonely", artist: "", durationMs: 1_000)])
    }

    /// A genuinely empty playlist is a real thing a user can paste; `trackList` disappearing
    /// is a shape change. They must not collapse into the same outcome, or a Spotify rename
    /// of that key would look like fifty empty playlists in a row.
    func testAnEmptyPlaylistIsNotConfusedWithAVanishedTrackList() throws {
        let empty = try SpotifyImportClient.parse(html: SpotifyEmbedFixture.page(rows: []))
        XCTAssertEqual(empty.tracks, [])
        XCTAssertEqual(empty.name, "Today’s Top Hits")
        XCTAssertFalse(empty.isPossiblyTruncated)

        assertParseFails(SpotifyEmbedFixture.page(rows: nil), with: .unreadable)
    }

    func testAPlaylistWithNoNameStillImports() throws {
        let page = try SpotifyImportClient.parse(html: SpotifyEmbedFixture.page(name: nil))

        XCTAssertFalse(page.name.isEmpty,
                       "A nameless playlist has to land somewhere the user can find it, and the "
                       + "sheet lets them rename it anyway")
        XCTAssertEqual(page.tracks.count, 6)
    }

    // MARK: - The request

    /// Built apart from being sent for the same reason `InnerTubeClient.makeRequest` is: the
    /// URL and the headers are assertable, and only the send needs a network.
    func testTheEmbedUrlIsBuiltFromTheIdAlone() throws {
        let request = try SpotifyImportClient.makeRequest(playlistId: " 37i9dQZF1DXcBWIGoYBM5M ")

        XCTAssertEqual(request.url?.absoluteString,
                       "https://open.spotify.com/embed/playlist/37i9dQZF1DXcBWIGoYBM5M")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"),
                        "A client that won't name itself is the first one an anti-bot rule turns away")
    }

    func testAnEmptyIdIsRefusedBeforeAnyRequestGoesOut() {
        XCTAssertThrowsError(try SpotifyImportClient.makeRequest(playlistId: "   ")) {
            XCTAssertEqual($0 as? SpotifyImportError, .notAPlaylistLink,
                           "Fetching open.spotify.com/embed/playlist/ would answer 200 with a page "
                           + "holding no entity, and the user would be told their playlist is private")
        }
    }

    // MARK: - Messages

    func testEveryFailureHasASentenceTheUserCanActOn() {
        for error in [SpotifyImportError.notAPlaylistLink, .notAvailable, .unreadable, .network] {
            let message = error.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty, "\(error) reaches the sheet verbatim; it cannot be blank")
            XCTAssertTrue(message.hasSuffix("."), "\(error) should read as a sentence, like APIError's")
        }
        XCTAssertEqual(SpotifyImportError.notAPlaylistLink.errorDescription,
                       "That doesn't look like a Spotify playlist link.")
    }

    // MARK: -

    private func assertParseFails(_ html: String,
                                  with expected: SpotifyImportError,
                                  _ message: String = "",
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        XCTAssertThrowsError(try SpotifyImportClient.parse(html: html), message, file: file, line: line) {
            XCTAssertEqual($0 as? SpotifyImportError, expected, message, file: file, line: line)
        }
    }
}
