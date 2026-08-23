import XCTest
@testable import VVDemus

/// `LRCParser.parse(_:)` — text off a lyrics host, `[LyricsLine]` out.
///
/// The format looks like one regular expression and is not. Every case below is a shape that
/// LRCLIB really serves: a chorus written once and stamped four times, an `[offset:]` tag that
/// is silently wrong when ignored, an instrumental break encoded as a timestamp with nothing
/// after it, and files that arrive with CRLF endings or a BOM because whoever contributed them
/// pasted out of Notepad. A parser that is merely *approximately* right here scrolls the wrong
/// line over someone's song, which is the failure this whole feature is written to avoid.
///
/// Pure text in, values out: no network, no player, no clock.
final class LRCParserTests: XCTestCase {

    // MARK: - Timestamp shapes

    /// Contributors use all three of these, often inside the same file, and the two-digit
    /// fraction is hundredths while the three-digit one is milliseconds — read the wrong way a
    /// `.5` becomes a `.005` and a line lands half a second early for the whole song.
    func testHundredthsMillisecondsAndBareSecondsAllParse() {
        let lines = LRCParser.parse("""
        [00:12.34] hundredths
        [00:13.456] milliseconds
        [00:14] bare seconds
        """)

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].at, 12.34, accuracy: 0.0005)
        XCTAssertEqual(lines[1].at, 13.456, accuracy: 0.0005,
                       "Three digits after the dot are milliseconds, not hundredths")
        XCTAssertEqual(lines[2].at, 14, accuracy: 0.0005)
        XCTAssertEqual(lines.map(\.text), ["hundredths", "milliseconds", "bare seconds"])
    }

    /// Minutes are not clock minutes: a long track passes 60 and nothing about the format says
    /// it may not.
    func testMinutesBeyondSixtyAreArithmeticNotAnError() {
        let lines = LRCParser.parse("[63:07.50] still going")

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].at, 63 * 60 + 7.5, accuracy: 0.0005)
    }

    // MARK: - One text, several times

    /// The whole reason a chorus is not repeated in the file. Stamping it once and dropping the
    /// other timestamps loses every repeat, which reads as "the lyrics stop halfway through".
    func testARepeatedChorusYieldsOneLinePerTimestamp() {
        let lines = LRCParser.parse("""
        [00:10.00] verse
        [00:30.00][01:20.00][02:40.00] the chorus
        """)

        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.map(\.at), [10, 30, 80, 160])
        XCTAssertEqual(lines.filter { $0.text == "the chorus" }.count, 3)
    }

    // MARK: - Metadata

    /// `[ar:]` and friends are file headers. Rendered as lyrics they put the artist's name and
    /// the word "length" at the top of the screen at time zero, which is exactly what an
    /// unfiltered `[tag] text` parser does.
    func testMetadataTagsAreNotLyrics() {
        let lines = LRCParser.parse("""
        [ar:Some Artist]
        [ti:Some Song]
        [al:Some Album]
        [by:some contributor]
        [length:03:21]
        [00:01.00] first real line
        """)

        XCTAssertEqual(lines.map(\.text), ["first real line"])
        XCTAssertEqual(lines.first?.at, 1)
    }

    /// `[length:03:21]` is the trap: it is shaped like a timestamp once the key is ignored, so
    /// a parser that only strips brackets emits a lyric line at 3:21 reading "03:21".
    func testTheLengthTagIsNotMistakenForATimestamp() {
        let lines = LRCParser.parse("[length:03:21]\n[00:05.00] words")

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].at, 5, accuracy: 0.0005)
    }

    // MARK: - Offset

    /// Sign convention, which the format states and half the files in the wild depend on:
    /// **a positive `[offset:]` makes the words appear earlier**, so it is *subtracted* from
    /// every timestamp. Getting this backwards is invisible in review and doubles the error on
    /// screen, so both directions are pinned here.
    func testAPositiveOffsetPullsEveryTimestampEarlier() {
        let lines = LRCParser.parse("""
        [offset:+250]
        [00:10.00] one
        [00:20.00] two
        """)

        XCTAssertEqual(lines.map(\.at), [9.75, 19.75])
    }

    func testANegativeOffsetPushesEveryTimestampLater() {
        let lines = LRCParser.parse("""
        [offset:-250]
        [00:10.00] one
        [00:20.00] two
        """)

        XCTAssertEqual(lines.map(\.at), [10.25, 20.25])
    }

    /// Nothing requires the tag to come first, and a tag applied only to the lines below it
    /// would shift half a song.
    func testAnOffsetAtTheEndOfTheFileStillAppliesToTheLinesAboveIt() {
        let lines = LRCParser.parse("""
        [00:10.00] one
        [00:20.00] two
        [offset:+1000]
        """)

        XCTAssertEqual(lines.map(\.at), [9, 19])
    }

    /// An offset large enough to drag the opening line before the start of the track. Negative
    /// times are meaningless to both `LyricsCursor` and `PlayerService.seek(to:)`, so they land
    /// on zero rather than propagating.
    func testAnOffsetCannotPushALineBeforeTheStartOfTheTrack() {
        let lines = LRCParser.parse("[offset:+5000]\n[00:01.00] one\n[00:10.00] two")

        XCTAssertEqual(lines.map(\.at), [0, 5])
    }

    // MARK: - Instrumental gaps

    /// A timestamp with nothing after it is how the format writes "eight bars of nothing here".
    /// Dropping it as an empty line makes the previous lyric the active one for the whole
    /// instrumental, so the screen holds a highlighted line while the singing has stopped.
    func testATimestampWithNoTextIsAnInstrumentalGapAndSurvives() {
        let lines = LRCParser.parse("""
        [00:10.00] last words of the verse
        [00:14.00]
        [00:38.00] and back in
        """)

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1].at, 14, accuracy: 0.0005)
        XCTAssertEqual(lines[1].text, "")
    }

    /// Blank source lines are layout, not content, and must not become lyrics of their own or
    /// stop the parse.
    func testBlankSourceLinesBetweenStampsAreIgnoredWithoutLosingTheStamps() {
        let lines = LRCParser.parse("""
        [00:10.00] one

        [00:20.00] two

        """)

        XCTAssertEqual(lines.map(\.text), ["one", "two"])
    }

    // MARK: - Damage

    /// One bad tag is one bad line. A parser that gives up on the file loses a whole song's
    /// words to a single typo in a community-contributed upload.
    func testAMalformedTimestampSkipsItsOwnLineAndNothingElse() {
        let lines = LRCParser.parse("""
        [00:10.00] before
        [ab:cd] nonsense
        [00:99.00] seconds that are not seconds
        [12:34 unclosed
        [00:20.00] after
        """)

        XCTAssertEqual(lines.map(\.text), ["before", "after"],
                       "Every damaged line is dropped on its own; the good ones either side stay")
    }

    /// The malformed shape that was not merely mishandled but fatal: `minutes * 60` is `Int`
    /// arithmetic and Swift *traps* on overflow rather than throwing, so an all-digit minutes
    /// field of eighteen or nineteen digits — well-formed as far as every guard here was
    /// concerned — killed the process. From a remote, community-edited file, on a screen opened
    /// to read along with a song, and uncatchable by any caller.
    func testAnAbsurdlyLargeMinutesFieldIsRefusedRatherThanOverflowing() {
        let lines = LRCParser.parse("""
        [00:10.00] before
        [200000000000000000:00] the one that used to take the process
        [9223372036854775807:59.99] and its cousin at the very top of Int
        [00:20.00] after
        """)

        XCTAssertEqual(lines.map(\.text), ["before", "after"])
    }

    /// The bound above is on the digit count, so it must not cost a real timestamp anything: a
    /// six-digit minutes field is a hundred and ninety years, and long tracks are the reason
    /// minutes past 60 are allowed at all.
    func testALongTrackKeepsItsMinutesPastAnHour() {
        XCTAssertEqual(LRCParser.parse("[125:30.00]still going").first?.at, 125 * 60 + 30)
        XCTAssertEqual(LRCParser.parse("[999999:00.00]absurd but arithmetic").first?.at, 999_999 * 60)
    }

    /// Plain lyrics with no timestamps at all. The caller reads the empty array as "there is
    /// nothing timed here" and falls back to plain text, so an array of zero-second lines would
    /// be worse than nothing.
    func testTextWithNoTimestampsYieldsNothing() {
        XCTAssertTrue(LRCParser.parse("just some words\nand some more").isEmpty)
        XCTAssertTrue(LRCParser.parse("").isEmpty)
        XCTAssertTrue(LRCParser.parse("[ar:Some Artist]\n[ti:Some Song]").isEmpty,
                      "A file of nothing but headers is not timed lyrics")
    }

    // MARK: - How the bytes arrive

    /// CRLF survives every hop between a Windows contributor and this parser. Left on, the
    /// carriage return rides along on the end of every line's text and shows up on screen as a
    /// stray glyph or a phantom line break.
    func testCRLFLineEndingsLeaveNoCarriageReturnInTheText() {
        let lines = LRCParser.parse("[00:10.00] one\r\n[00:20.00] two\r\n")

        XCTAssertEqual(lines.map(\.text), ["one", "two"])
        XCTAssertEqual(lines.map(\.at), [10, 20])
    }

    /// A BOM sits in front of the first `[`, so without stripping it the first tag is malformed
    /// and the file loses exactly one line — its opening one, the one most likely to be noticed
    /// and least likely to be diagnosed.
    func testALeadingByteOrderMarkDoesNotEatTheFirstLine() {
        let lines = LRCParser.parse("\u{FEFF}[00:10.00] one\n[00:20.00] two")

        XCTAssertEqual(lines.map(\.text), ["one", "two"])
    }

    // MARK: - Order

    /// `LyricsCursor.activeIndex(in:at:)` binary-searches what it is given, so unsorted input
    /// is not a cosmetic problem: it silently returns the wrong line. Files arrive out of order
    /// whenever a chorus is stamped with several times, which is most of them.
    func testOutputIsSortedByTime() {
        let lines = LRCParser.parse("""
        [02:00.00] last
        [00:30.00][01:00.00] chorus
        [00:10.00] first
        """)

        XCTAssertEqual(lines.map(\.at), [10, 30, 60, 120])
        XCTAssertEqual(lines.map(\.text), ["first", "chorus", "chorus", "last"])
    }

    /// Two contributors stamping the same moment, or a call and its response written as two
    /// lines. Both are kept, in the order the file wrote them — the sort must not reorder a tie
    /// and turn a response into a call.
    func testDuplicateTimestampsKeepTheirSourceOrder() {
        let lines = LRCParser.parse("""
        [00:10.00] call
        [00:10.00] response
        """)

        XCTAssertEqual(lines.map(\.text), ["call", "response"])
    }
}
