import XCTest
@testable import VVDemus

/// The one function standing between a playing song and the highlighted line.
///
/// It runs on every progress tick, it is the only thing `LyricsView` asks "which line now?", and
/// it has no memory — so every case below is a value in and a value out. The awkward ones are not
/// hypothetical: the scrubber hands it negative times mid-drag, a seek jumps it backwards with no
/// warning, and LRC files in the wild carry two lines stamped at the same instant.
final class LyricsCursorTests: XCTestCase {

    private func line(_ at: TimeInterval, _ text: String) -> LyricsLine {
        LyricsLine(at: at, text: text)
    }

    // MARK: - Nothing to point at

    func testEmptyLinesHasNoActiveIndex() {
        XCTAssertNil(LyricsCursor.activeIndex(in: [], at: 10))
    }

    /// A one-line file is the degenerate case the binary search gets wrong first: an empty search
    /// window is the same shape as "before the only line", and confusing the two either crashes
    /// on an out-of-range index or highlights line zero over the intro.
    func testSingleLineBeforeItsTimestampIsNil() {
        let lines = [line(5, "here we go")]
        XCTAssertNil(LyricsCursor.activeIndex(in: lines, at: 4.9))
    }

    func testSingleLineAtAndAfterItsTimestampIsIndexZero() {
        let lines = [line(5, "here we go")]
        XCTAssertEqual(LyricsCursor.activeIndex(in: lines, at: 5), 0)
        XCTAssertEqual(LyricsCursor.activeIndex(in: lines, at: 400), 0)
    }

    // MARK: - Boundaries

    /// The boundary is inclusive, and it has to be: an LRC timestamp is the moment the line is
    /// sung, so at exactly that moment it is the current line. Exclusive would leave the previous
    /// line lit for one tick past its own end, which reads as lyrics running late for the whole song.
    func testTimeExactlyOnATimestampSelectsThatLine() {
        let lines = [line(0, "one"), line(10, "two"), line(20, "three")]
        XCTAssertEqual(LyricsCursor.activeIndex(in: lines, at: 0), 0)
        XCTAssertEqual(LyricsCursor.activeIndex(in: lines, at: 10), 1)
        XCTAssertEqual(LyricsCursor.activeIndex(in: lines, at: 20), 2)
    }

    /// Instrumental intros are long enough to notice. Nothing is being sung yet, so nothing is
    /// highlighted — the alternative is line one glowing through a thirty-second intro.
    func testTimeBeforeTheFirstLineIsNil() {
        let lines = [line(12, "one"), line(18, "two")]
        XCTAssertNil(LyricsCursor.activeIndex(in: lines, at: 0))
        XCTAssertNil(LyricsCursor.activeIndex(in: lines, at: 11.99))
    }

    /// Past the last line the song is still playing — an outro, applause, a long fade. The last
    /// line stays lit rather than the view emptying itself while the track is clearly still going.
    func testTimePastTheLastLineStaysOnTheLastIndex() {
        let lines = [line(0, "one"), line(10, "two"), line(20, "three")]
        XCTAssertEqual(LyricsCursor.activeIndex(in: lines, at: 21), 2)
        XCTAssertEqual(LyricsCursor.activeIndex(in: lines, at: 9_999), 2)
    }

    // MARK: - Ties

    /// Two lines at one timestamp: the later index wins. Both are "at or before" the playhead, and
    /// the one further down the file is the one that has not been sung past yet — picking the
    /// earlier one would leave the highlight stuck a line behind for the rest of the run of ties.
    func testDuplicateTimestampsSelectTheLastOfTheRun() {
        let lines = [line(0, "one"), line(10, "a"), line(10, "b"), line(10, "c"), line(20, "four")]
        XCTAssertEqual(LyricsCursor.activeIndex(in: lines, at: 10), 3)
        XCTAssertEqual(LyricsCursor.activeIndex(in: lines, at: 10.5), 3)
        XCTAssertEqual(LyricsCursor.activeIndex(in: lines, at: 9.5), 0)
    }

    /// Same question asked twice must answer the same way; a highlight that flickers between two
    /// lines held at one timestamp is the visible symptom of a search that is only sometimes right.
    func testDuplicateTimestampsAreDeterministicAcrossRepeatedCalls() {
        let lines = [line(4, "a"), line(4, "b"), line(4, "c")]
        let answers = (0..<20).map { _ in LyricsCursor.activeIndex(in: lines, at: 4) }
        XCTAssertEqual(Set(answers), [2])
    }

    // MARK: - Seeking

    /// The cursor holds no state, so a backward seek is not a special case — but that is exactly
    /// the claim worth pinning down, because the obvious "remember the last index and walk forward"
    /// implementation passes every other test here and fails this one.
    func testBackwardSeekReturnsTheEarlierIndex() {
        let lines = (0..<50).map { line(TimeInterval($0) * 3, "line \($0)") }

        XCTAssertEqual(LyricsCursor.activeIndex(in: lines, at: 100), 33)
        XCTAssertEqual(LyricsCursor.activeIndex(in: lines, at: 7), 2)
        XCTAssertEqual(LyricsCursor.activeIndex(in: lines, at: 100), 33)
        XCTAssertEqual(LyricsCursor.activeIndex(in: lines, at: 0), 0)
    }

    /// Every position in a small file, checked against the obvious linear answer. Binary searches
    /// go wrong in one place at a time, and off-by-one at some interior boundary is invisible in a
    /// handful of hand-picked cases.
    func testAgreesWithALinearScanEverywhere() {
        let lines = [line(0, "a"), line(1.5, "b"), line(1.5, "c"), line(4, "d"), line(9, "e")]

        for tenths in 0...120 {
            let t = TimeInterval(tenths) / 10
            let expected = lines.lastIndex { $0.at <= t }
            XCTAssertEqual(LyricsCursor.activeIndex(in: lines, at: t), expected,
                           "disagreed with a linear scan at t=\(t)")
        }
    }

    // MARK: - Negative time

    /// `NowPlayingView`'s scrubber emits negative times while a drag runs past the left edge, and
    /// `PlayerService.progress` passes them straight through. A negative playhead is not a position
    /// in the song, so nothing is current — and this must hold even for a file whose first
    /// timestamp is itself negative, which an `[offset:]` tag can produce.
    func testNegativeTimeHasNoActiveIndex() {
        let lines = [line(0, "one"), line(10, "two")]
        XCTAssertNil(LyricsCursor.activeIndex(in: lines, at: -0.001))
        XCTAssertNil(LyricsCursor.activeIndex(in: lines, at: -30))

        let shiftedEarly = [line(-2, "one"), line(10, "two")]
        XCTAssertNil(LyricsCursor.activeIndex(in: shiftedEarly, at: -1))
    }

    // MARK: - The synced invariant

    /// `.synced` promises sorted lines, and the cursor is written against that promise rather than
    /// re-checking it on every tick. The promise is kept by `Lyrics.init` and by decoding, so a
    /// caller cannot hand the view an unsorted body by any route the app actually uses.
    func testLyricsInitSortsSyncedLines() {
        let lyrics = Lyrics(
            body: .synced([line(20, "three"), line(0, "one"), line(10, "two")]),
            attribution: nil,
            matchedDuration: nil
        )

        guard case .synced(let lines) = lyrics.body else { return XCTFail("expected synced body") }
        XCTAssertEqual(lines.map(\.text), ["one", "two", "three"])
    }

    /// Exact repeats — same instant, same words — come from files that have been concatenated or
    /// merged, and they show up as a line printed twice. Two *different* texts at one timestamp are
    /// left alone: they may be a real overlap, and dropping words is worse than a tie the cursor
    /// already resolves deterministically.
    func testLyricsInitDropsOnlyIdenticalRepeats() {
        let lyrics = Lyrics(
            body: .synced([line(10, "a"), line(10, "a"), line(10, "b"), line(0, "intro")]),
            attribution: nil,
            matchedDuration: nil
        )

        guard case .synced(let lines) = lyrics.body else { return XCTFail("expected synced body") }
        XCTAssertEqual(lines.map(\.text), ["intro", "a", "b"])
        XCTAssertEqual(lines.map(\.at), [0, 10, 10])
    }

    /// Sorting keeps the file's order for lines sharing a timestamp. Reordering them would make
    /// the cursor's "last of the run" rule pick a different line depending on how the sort felt,
    /// which is the flicker `testDuplicateTimestampsAreDeterministic...` exists to forbid.
    func testSortingIsStableAcrossEqualTimestamps() {
        let lyrics = Lyrics(
            body: .synced([line(5, "first"), line(5, "second"), line(5, "third"), line(1, "before")]),
            attribution: nil,
            matchedDuration: nil
        )

        guard case .synced(let lines) = lyrics.body else { return XCTFail("expected synced body") }
        XCTAssertEqual(lines.map(\.text), ["before", "first", "second", "third"])
    }

    /// The cache decodes bodies straight off disk, so decoding is the other door the invariant has
    /// to be defended at — a snapshot written by an older build (or hand-edited) must not come back
    /// unsorted and quietly break the search.
    func testDecodingRepairsAnUnsortedSyncedBody() throws {
        let json = """
        {"synced":[{"at":9,"text":"late"},{"at":1,"text":"early"},{"at":9,"text":"late"}]}
        """
        let decoded = try JSONDecoder().decode(LyricsBody.self, from: Data(json.utf8))

        guard case .synced(let lines) = decoded else { return XCTFail("expected synced body") }
        XCTAssertEqual(lines.map(\.text), ["early", "late"])
    }

    // MARK: - Codable

    func testSyncedBodyRoundTrips() throws {
        let original = Lyrics(
            body: .synced([line(0, "one"), line(1.25, "two")]),
            attribution: "LRCLIB",
            matchedDuration: 214
        )

        let decoded = try JSONDecoder().decode(Lyrics.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testPlainBodyRoundTrips() throws {
        let original = Lyrics(
            body: .plain(["one", "", "two"]),
            attribution: nil,
            matchedDuration: nil
        )

        let decoded = try JSONDecoder().decode(Lyrics.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    /// The two cases must not decode into each other. They carry different payload types, but the
    /// encoding is hand-written, so "synced read back as plain" is a real thing to get wrong once.
    func testTheTwoCasesStayDistinctThroughACodingRoundTrip() throws {
        let synced = try JSONDecoder().decode(
            LyricsBody.self, from: JSONEncoder().encode(LyricsBody.synced([line(0, "one")])))
        let plain = try JSONDecoder().decode(
            LyricsBody.self, from: JSONEncoder().encode(LyricsBody.plain(["one"])))

        if case .plain = synced { XCTFail("a synced body decoded as plain") }
        if case .synced = plain { XCTFail("a plain body decoded as synced") }
    }

    /// Empty is a shape both cases can hold — an LRC file of nothing but metadata parses to zero
    /// lines — and it has to survive the trip rather than being nil-ed out somewhere in the middle.
    func testEmptyBodiesRoundTrip() throws {
        for body in [LyricsBody.synced([]), LyricsBody.plain([])] {
            let decoded = try JSONDecoder().decode(LyricsBody.self, from: JSONEncoder().encode(body))
            XCTAssertEqual(decoded, body)
        }
    }
}
