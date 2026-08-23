import XCTest
@testable import VVDemus

/// `LyricsClient` without a network.
///
/// The fetching is three lines of `URLSession` and is not what goes wrong. What goes wrong is
/// believing the wrong row: LRCLIB will happily hand back a live cut, a karaoke take and a
/// duplicate upload with an empty `syncedLyrics` field for the same query, and picking any of
/// them scrolls someone else's words over the song. So the decoding, the ranking and the
/// verdict-to-body step are separated from the request and asserted here against fixture JSON
/// — captured shapes, never the live host, because a test that needs lrclib.net to be up is a
/// test that will one day fail for a reason that has nothing to do with this app.
final class LyricsClientTests: XCTestCase {

    // MARK: - Fixtures

    private func track(
        title: String = "Bohemian Rhapsody",
        artist: String = "Queen",
        album: String? = "A Night at the Opera",
        duration: Int? = 354
    ) -> Track {
        Track(videoId: "fJ9rUzIMcZQ", title: title, artist: artist, album: album,
              thumbnailUrl: nil, durationSeconds: duration)
    }

    /// One row in the shape `/api/get` really answers with.
    private func row(
        title: String = "Bohemian Rhapsody",
        artist: String = "Queen",
        album: String? = "A Night at the Opera",
        duration: Double? = 354,
        instrumental: Bool = false,
        plain: String? = "Is this the real life?\nIs this just fantasy?",
        synced: String? = "[00:00.00]Is this the real life?\n[00:04.50]Is this just fantasy?"
    ) -> String {
        var fields = [
            "\"trackName\":\(quoted(title))",
            "\"artistName\":\(quoted(artist))",
            "\"albumName\":\(album.map(quoted) ?? "null")",
            "\"duration\":\(duration.map { String($0) } ?? "null")",
            "\"instrumental\":\(instrumental)",
        ]
        fields.append("\"plainLyrics\":\(plain.map(quoted) ?? "null")")
        fields.append("\"syncedLyrics\":\(synced.map(quoted) ?? "null")")
        return "{\(fields.joined(separator: ","))}"
    }

    private func quoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            // A raw carriage return is not legal inside a JSON string, so a CRLF fixture cannot
            // be written without this — which is most of why nothing covered CRLF before.
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - Decoding

    func testARealisticRowDecodesEveryFieldWeUse() throws {
        let record = try XCTUnwrap(LyricsClient.decodeRecord(data(row())))

        XCTAssertEqual(record.trackName, "Bohemian Rhapsody")
        XCTAssertEqual(record.artistName, "Queen")
        XCTAssertEqual(record.albumName, "A Night at the Opera")
        XCTAssertEqual(record.durationSeconds, 354)
        XCTAssertEqual(record.instrumental, false)
        XCTAssertTrue(record.syncedLyrics?.hasPrefix("[00:00.00]") == true)
    }

    /// LRCLIB sends seconds as a JSON number that is sometimes fractional. Truncating instead of
    /// rounding would put a 233.6s track a second away from itself and cost it the timed verdict
    /// at the two-second boundary.
    func testAFractionalDurationRounds() throws {
        let record = try XCTUnwrap(LyricsClient.decodeRecord(data(row(duration: 233.6))))
        XCTAssertEqual(record.durationSeconds, 234)
    }

    /// Every field is optional, so the body LRCLIB sends *with* its 404 decodes perfectly well
    /// into a record of nothing. It has to be rejected here rather than left to be accidentally
    /// rejected later by a scorer that sees an empty title.
    func testThe404BodyIsNotARecord() {
        let body = #"{"code":404,"name":"TrackNotFound","message":"Failed to find specified track"}"#
        XCTAssertNil(LyricsClient.decodeRecord(data(body)))
    }

    /// A shape change must cost the lyrics, not raise an error over a song that is playing fine.
    func testAMalformedBodyIsNoLyricsRatherThanAFailure() {
        XCTAssertNil(LyricsClient.decodeRecord(data("not json at all")))
        XCTAssertEqual(LyricsClient.decodeSearch(data("not json at all")).count, 0)
        XCTAssertEqual(LyricsClient.decodeSearch(data("[]")).count, 0)
    }

    func testSearchDecodesEveryRow() {
        let body = "[\(row()),\(row(title: "Bohemian Rhapsody - Live Aid", duration: 400))]"
        XCTAssertEqual(LyricsClient.decodeSearch(data(body)).count, 2)
    }

    // MARK: - Which row is believed

    func testAnExactMatchGivesTimedLinesAndCreditsLRCLIB() throws {
        let records = LyricsClient.decodeSearch(data("[\(row())]"))
        let lyrics = try XCTUnwrap(LyricsClient.choose(track: track(), among: records))

        guard case .synced(let lines) = lyrics.body else {
            return XCTFail("an exact match with timestamps must render timed")
        }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.first?.at, 0)
        XCTAssertEqual(lines.last?.at, 4.5)
        XCTAssertEqual(lyrics.attribution, LyricsClient.timedAttribution,
                       "attribution is shown, never hidden")
        XCTAssertEqual(lyrics.matchedDuration, 354,
                       "matchedDuration records what was matched against, so a scroll that runs "
                       + "ahead of the song can be diagnosed from the cache afterwards")
    }

    /// The case the whole file exists for. A live take agrees on every text field and differs
    /// only in length; scrolling its timings over the studio version is worse than showing
    /// nothing.
    func testALiveCutRunningFortySecondsLongIsRefusedEntirely() {
        let records = LyricsClient.decodeSearch(data("[\(row(duration: 394))]"))
        XCTAssertNil(LyricsClient.choose(track: track(), among: records))
    }

    /// A remaster three seconds longer is the same words and not the same take, so the words are
    /// shown and the timing is not — and the attribution says so, because `.plain` on its own
    /// cannot distinguish "we didn't trust the timing" from "there was none".
    func testAThreeSecondDifferenceKeepsTheWordsAndDropsTheTiming() throws {
        let records = LyricsClient.decodeSearch(data("[\(row(duration: 357))]"))
        let lyrics = try XCTUnwrap(LyricsClient.choose(track: track(), among: records))

        guard case .plain(let lines) = lyrics.body else {
            return XCTFail("an untimed-only verdict must not render as a scroll")
        }
        XCTAssertEqual(lines, ["Is this the real life?", "Is this just fantasy?"])
        XCTAssertEqual(lyrics.attribution, LyricsClient.untrustedTimingAttribution)
    }

    /// A contributor pasting plain text into the synced field parses to zero timed lines.
    /// Returning `.synced([])` there is an empty screen for a song whose words were sitting in
    /// the next field along.
    func testTimedTextWithNoTimestampsDegradesToPlainRatherThanToAnEmptyScroll() throws {
        let records = LyricsClient.decodeSearch(
            data("[\(row(synced: "Is this the real life?\nIs this just fantasy?"))]"))
        let lyrics = try XCTUnwrap(LyricsClient.choose(track: track(), among: records))

        guard case .plain(let lines) = lyrics.body else { return XCTFail("expected plain") }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lyrics.attribution, LyricsClient.plainAttribution,
                       "no timings is a different thing to say than timings we declined to use")
    }

    /// An instrumental is "no lyrics", which the cache should record as a miss. An empty body
    /// would render as a blank screen that looks like a bug instead.
    func testAnInstrumentalIsNothingFound() {
        let records = LyricsClient.decodeSearch(
            data("[\(row(instrumental: true, plain: nil, synced: nil))]"))
        XCTAssertNil(LyricsClient.choose(track: track(), among: records))
    }

    func testNoRowsIsNothingFound() {
        XCTAssertNil(LyricsClient.choose(track: track(), among: []))
    }

    /// The duplicate upload with every lyric field empty is a real and common first result.
    /// Stopping at it would mean no lyrics for exactly the popular songs most likely to be
    /// looked up.
    func testAnEmptyDuplicateFallsThroughToTheNextBelievableRow() throws {
        let empty = row(plain: nil, synced: nil)
        let records = LyricsClient.decodeSearch(data("[\(empty),\(row())]"))
        let lyrics = try XCTUnwrap(LyricsClient.choose(track: track(), among: records))

        guard case .synced = lyrics.body else { return XCTFail("the second row has timings") }
    }

    func testATimedRowWinsOverAnUntimedOneWhicheverOrderTheyArriveIn() throws {
        let untimed = row(duration: 360, synced: nil)
        let timed = row()

        for body in ["[\(untimed),\(timed)]", "[\(timed),\(untimed)]"] {
            let records = LyricsClient.decodeSearch(data(body))
            let lyrics = try XCTUnwrap(LyricsClient.choose(track: track(), among: records))
            guard case .synced = lyrics.body else {
                return XCTFail("the exact-length row must win regardless of response order")
            }
        }
    }

    /// Both accepted, so the tie-break is length: the row that is the same recording, not merely
    /// a believable one.
    func testAmongEquallyBelievedRowsTheClosestLengthWins() throws {
        let near = row(album: "Greatest Hits", duration: 355,
                       synced: "[00:01.00]nearer\n[00:05.00]still nearer")
        let far = row(duration: 356)
        let records = LyricsClient.decodeSearch(data("[\(far),\(near)]"))
        let lyrics = try XCTUnwrap(LyricsClient.choose(track: track(), among: records))

        guard case .synced(let lines) = lyrics.body else { return XCTFail("expected timed") }
        XCTAssertEqual(lines.first?.text, "nearer")
        XCTAssertEqual(lyrics.matchedDuration, 355)
    }

    /// A cover runs to the second and agrees on the title. Duration cannot tell it apart from
    /// the original, which is what `LyricsMatch`'s text gate is for — asserted here so that a
    /// future change to `choose` cannot quietly stop consulting it.
    func testACoverByAnotherArtistAtTheSameLengthIsRefused() {
        let records = LyricsClient.decodeSearch(data("[\(row(artist: "The Muppets"))]"))
        XCTAssertNil(LyricsClient.choose(track: track(), among: records))
    }

    // MARK: - Plain text

    /// A blank line between verses is how the words are meant to be read; collapsing them turns
    /// a song into a paragraph. The blanks at the ends are whitespace in the file, not silence.
    func testBlankLinesBetweenVersesSurviveButTheOnesAtTheEndsDoNot() throws {
        let records = LyricsClient.decodeSearch(
            data("[\(row(duration: 360, plain: "\nfirst verse\n\nsecond verse\n\n", synced: nil))]"))
        let lyrics = try XCTUnwrap(LyricsClient.choose(track: track(), among: records))

        guard case .plain(let lines) = lyrics.body else { return XCTFail("expected plain") }
        XCTAssertEqual(lines, ["first verse", "", "second verse"])
    }

    /// The half of the CRLF defence the synced path had and this one did not. `"\r\n"` is a
    /// single extended grapheme cluster in Swift, so splitting on the `Character` `"\n"` matched
    /// nothing at all in a file pasted out of a Windows editor: the whole song came back as one
    /// "line", stanza breaks gone, the end trims never firing, and every consumer that counts
    /// lines — the cache's emptiness check, `/api/lyrics` — answering 1.
    func testPlainWordsWithWindowsLineEndingsAreStillSeparateLines() throws {
        let windows = "\r\nfirst verse\r\n\r\nsecond verse\r\n"
        let records = LyricsClient.decodeSearch(
            data("[\(row(duration: 360, plain: windows, synced: nil))]"))
        let lyrics = try XCTUnwrap(LyricsClient.choose(track: track(), among: records))

        guard case .plain(let lines) = lyrics.body else { return XCTFail("expected plain") }
        XCTAssertEqual(lines, ["first verse", "", "second verse"])
        XCTAssertFalse(lines.contains { $0.contains("\r") }, "no carriage return may survive into a line")
    }

    /// The warning triangle is about a judgement this app made, so it is a lie on a row that
    /// never carried timings — the ordinary shape for a contributor who only typed the words.
    /// "This version isn't the same length" reads as a bug report about the match; the honest
    /// answer for a track with no LRC anywhere is that there were no timings.
    func testARowThatNeverHadTimingsIsNotReportedAsTimingsWeDeclined() throws {
        let records = LyricsClient.decodeSearch(data("[\(row(duration: 357, synced: nil))]"))
        let lyrics = try XCTUnwrap(LyricsClient.choose(track: track(), among: records))

        XCTAssertEqual(lyrics.attribution, LyricsClient.plainAttribution)
    }

    /// A plain-only duplicate at exactly the track's length outranks a timed row a second off,
    /// because the ranking's second key is duration and its `hasSynced` tie-break only decides
    /// exact ties. Returning the first believable row therefore handed back static text for a
    /// song that had scrolling lyrics one row down — the outcome ranking rather than filtering
    /// exists to prevent.
    func testAPlainOnlyRowAtTheExactLengthDoesNotBeatATimedRowASecondOff() throws {
        let plainOnly = row(album: "Greatest Hits", duration: 354,
                            plain: "words only\nno timings here", synced: nil)
        let timed = row(duration: 355)
        let records = LyricsClient.decodeSearch(data("[\(plainOnly),\(timed)]"))
        let lyrics = try XCTUnwrap(LyricsClient.choose(track: track(), among: records))

        guard case .synced = lyrics.body else {
            return XCTFail("timed words are worth more than a second of length agreement")
        }
    }

    /// `duration` is a number a contributor submitted, and `Int(1e30)` is a trap rather than a
    /// large number — one hostile row anywhere in a search result would have taken the process
    /// down for everyone who opened that song. A row we cannot make sense of is a row with no
    /// length, which the scorer already knows what to do with.
    func testARowWithAnAbsurdDurationIsScoredWithoutLengthRatherThanCrashing() throws {
        let records = LyricsClient.decodeSearch(data("[\(row(duration: 1e30))]"))
        XCTAssertNil(records.first?.durationSeconds)

        let lyrics = try XCTUnwrap(LyricsClient.choose(track: track(), among: records))
        XCTAssertNil(lyrics.matchedDuration)
    }

    /// A row that only ever had the timed field filled in still has words in it. Reading them
    /// out of the LRC costs one parse and is the difference between the words and nothing.
    func testWordsAreRecoveredFromTheTimedTextWhenThePlainFieldIsEmpty() throws {
        let records = LyricsClient.decodeSearch(data("[\(row(duration: 360, plain: nil))]"))
        let lyrics = try XCTUnwrap(LyricsClient.choose(track: track(), among: records))

        guard case .plain(let lines) = lyrics.body else { return XCTFail("expected plain") }
        XCTAssertEqual(lines, ["Is this the real life?", "Is this just fantasy?"])
    }

    // MARK: - The requests

    func testTheExactLookupCarriesEveryFieldLRCLIBMatchesOn() throws {
        let request = try XCTUnwrap(LyricsClient.makeGetRequest(for: track()))
        let query = try XCTUnwrap(request.url?.query)

        XCTAssertEqual(request.url?.host, "lrclib.net")
        XCTAssertEqual(request.url?.path, "/api/get")
        XCTAssertTrue(query.contains("artist_name=Queen"), query)
        XCTAssertTrue(query.contains("album_name=A%20Night%20at%20the%20Opera"), query)
        XCTAssertTrue(query.contains("duration=354"), query)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"),
                        "LRCLIB asks clients to name themselves")
        XCTAssertLessThanOrEqual(request.timeoutInterval, 15,
                                 "lyrics must not hold a spinner as long as a search may")
    }

    /// A track whose length we do not know must not be looked up as zero seconds, which matches
    /// nothing, forever.
    func testAMissingDurationIsOmittedRatherThanSentAsZero() throws {
        let request = try XCTUnwrap(LyricsClient.makeGetRequest(for: track(album: nil, duration: nil)))
        let query = try XCTUnwrap(request.url?.query)

        XCTAssertFalse(query.contains("duration"), query)
        XCTAssertFalse(query.contains("album_name"), query)
    }

    /// The fallback drops the two fields most likely to have been the reason the exact lookup
    /// missed. Repeating them would reproduce the miss.
    func testTheSearchFallbackAsksOnlyForTitleAndArtist() throws {
        let request = try XCTUnwrap(LyricsClient.makeSearchRequest(for: track()))
        let query = try XCTUnwrap(request.url?.query)

        XCTAssertEqual(request.url?.path, "/api/search")
        XCTAssertFalse(query.contains("duration"), query)
        XCTAssertFalse(query.contains("album_name"), query)
    }

    /// `URLComponents` escapes `&` in a value but leaves `+` alone, and a bare `+` in a query is
    /// a space to most servers — so without the fix-up "Me + You" is looked up as "Me   You" and
    /// misses, silently and only for songs with a plus in the title.
    func testPunctuationInATitleIsEscapedIncludingThePlusFoundationLeavesAlone() throws {
        let request = try XCTUnwrap(
            LyricsClient.makeGetRequest(for: track(title: "Me + You & Everyone", album: nil)))
        let query = try XCTUnwrap(request.url?.query)

        XCTAssertTrue(query.contains("Me%20%2B%20You%20%26%20Everyone"), query)
    }

    // MARK: - The YouTube Music fallback

    private func watchNext(lyricsTab: String) -> String {
        """
        {"contents":{"singleColumnMusicWatchNextResultsRenderer":{"tabbedRenderer":
        {"watchNextTabbedResultsRenderer":{"tabs":[
        {"tabRenderer":{"title":"Up next","endpoint":{"browseEndpoint":{"browseId":"FEmusic_up_next"}}}},
        \(lyricsTab),
        {"tabRenderer":{"title":"Related","endpoint":{"browseEndpoint":{"browseId":"MPTRt_related"}}}}
        ]}}}}}
        """
    }

    func testTheLyricsTabIsFoundByItsBrowseIdRatherThanItsPosition() throws {
        let tab = #"{"tabRenderer":{"title":"Lyrics","endpoint":{"browseEndpoint":{"browseId":"MPLYt_abc123"}}}}"#
        let json = try JSON.parse(data(watchNext(lyricsTab: tab)))

        XCTAssertEqual(LyricsClient.lyricsBrowseId(in: json), "MPLYt_abc123",
                       "indexing the tab list would browse the related-tracks shelf for words the "
                       + "first time YouTube reorders it")
    }

    /// The prefix is the primary signal, but a non-English UI localises the title, and a future
    /// prefix change would take the feature with it. Both are consulted.
    func testATabTitledLyricsIsFoundEvenWithAnUnfamiliarBrowseId() throws {
        let tab = #"{"tabRenderer":{"title":"Lyrics","endpoint":{"browseEndpoint":{"browseId":"XYZt_abc123"}}}}"#
        let json = try JSON.parse(data(watchNext(lyricsTab: tab)))

        XCTAssertEqual(LyricsClient.lyricsBrowseId(in: json), "XYZt_abc123")
    }

    /// A track with no lyrics still gets a tab — greyed out, with no endpoint at all. The missing
    /// browseId is the signal, not a missing tab.
    func testAGreyedOutLyricsTabIsNoLyrics() throws {
        let tab = #"{"tabRenderer":{"title":"Lyrics","unselectable":true}}"#
        let json = try JSON.parse(data(watchNext(lyricsTab: tab)))

        XCTAssertNil(LyricsClient.lyricsBrowseId(in: json))
    }

    func testTheBrowseResponseYieldsPlainWordsAndTheFooterYouTubeRequiresBeShown() throws {
        let body = """
        {"contents":{"sectionListRenderer":{"contents":[{"musicDescriptionShelfRenderer":{
        "description":{"runs":[{"text":"first line\\nsecond line"}]},
        "footer":{"runs":[{"text":"Source: Musixmatch"}]}}}]}}}
        """
        let lyrics = try XCTUnwrap(
            LyricsClient.youTubeLyrics(in: try JSON.parse(data(body)), matchedDuration: 354))

        guard case .plain(let lines) = lyrics.body else {
            return XCTFail("YouTube Music lyrics carry no timestamps and must always be plain")
        }
        XCTAssertEqual(lines, ["first line", "second line"])
        XCTAssertEqual(lyrics.attribution, "YouTube Music — Source: Musixmatch",
                       "the footer is the licence the text is displayed under, not decoration")
        XCTAssertEqual(lyrics.matchedDuration, 354)
    }

    /// The shelf arrives with an empty description for a track whose lyrics were withdrawn.
    /// Rendering that is a blank screen with a credit under it.
    func testAnEmptyBrowseResponseIsNothingFound() throws {
        let body = #"{"contents":{"sectionListRenderer":{"contents":[]}}}"#
        XCTAssertNil(LyricsClient.youTubeLyrics(in: try JSON.parse(data(body)), matchedDuration: nil))
    }
}
