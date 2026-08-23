import XCTest
@testable import VVDemus

/// The gate that decides whether a lyrics result is allowed to scroll over someone's song.
///
/// Lyrics have the failure mode the rest of the app does not: they can be confidently wrong. A
/// cover, a live take, a remix and the studio master share a title and an artist and differ only
/// in length, so every case below asserts what the *verdict* is rather than whether something
/// was found. `.acceptUntimedOnly` is the interesting one — it is what stops good words being
/// thrown away because their timing cannot be trusted.
final class LyricsMatchTests: XCTestCase {

    private func candidate(_ title: String,
                           _ artist: String,
                           album: String? = nil,
                           seconds: Int?) -> LyricsCandidate {
        LyricsCandidate(title: title, artist: artist, album: album, durationSeconds: seconds)
    }

    // MARK: - The happy case

    func testAnExactMatchIsAccepted() {
        let track = Fixtures.track("v1", title: "Bohemian Rhapsody",
                                   artist: "Queen", durationSeconds: 354)

        XCTAssertEqual(
            LyricsMatch.score(track: track,
                              candidate: candidate("Bohemian Rhapsody", "Queen", seconds: 354)),
            .accept
        )
    }

    /// The catalogues never write either field the same way, which is the whole reason the
    /// normalisation is `TrackMatcher`'s and not a second copy: "- Topic" and a remaster suffix
    /// must not cost a track its timed lyrics.
    func testDecorationOnEitherSideStillAccepts() {
        let track = Fixtures.track("v1", title: "Bohemian Rhapsody - Remastered 2011",
                                   artist: "Queen - Topic", durationSeconds: 354)

        XCTAssertEqual(
            LyricsMatch.score(track: track,
                              candidate: candidate("Bohemian Rhapsody", "Queen", seconds: 355)),
            .accept,
            "If this ever fails, someone has stopped reusing TrackMatcher's strip list"
        )
    }

    // MARK: - The case that actually bites

    /// A live cut runs long. Same title, same artist, and its timing is a minute of applause
    /// away from the studio master — the exact result a naive lookup scrolls over your song.
    func testALiveCutRunningFortySecondsLongIsRejected() {
        let track = Fixtures.track("v1", title: "Live Forever",
                                   artist: "Oasis", durationSeconds: 276)

        XCTAssertEqual(
            LyricsMatch.score(track: track,
                              candidate: candidate("Live Forever (Live at Knebworth)", "Oasis",
                                                   seconds: 316)),
            .reject
        )
    }

    /// Three seconds is a remaster or a different encode: the words are right, the timing drifts.
    func testAThreeSecondLongerRemasterIsWordsOnly() {
        let track = Fixtures.track("v1", title: "Wish You Were Here",
                                   artist: "Pink Floyd", durationSeconds: 334)

        XCTAssertEqual(
            LyricsMatch.score(track: track,
                              candidate: candidate("Wish You Were Here", "Pink Floyd",
                                                   album: "Wish You Were Here", seconds: 337)),
            .acceptUntimedOnly
        )
    }

    /// A cover has the same title and can have the same length. The artist is the only field
    /// that ever disagrees, so disagreement there is fatal even at a perfect duration.
    func testACoverByADifferentArtistIsRejectedDespiteAnExactDuration() {
        let track = Fixtures.track("v1", title: "Fast Car",
                                   artist: "Tracy Chapman", durationSeconds: 296)

        XCTAssertEqual(
            LyricsMatch.score(track: track,
                              candidate: candidate("Fast Car", "Luke Combs", seconds: 296)),
            .reject
        )
    }

    /// Different song entirely, same length by coincidence.
    func testADifferentTitleIsRejected() {
        let track = Fixtures.track("v1", title: "Yesterday",
                                   artist: "The Beatles", durationSeconds: 205)

        XCTAssertEqual(
            LyricsMatch.score(track: track,
                              candidate: candidate("Yesterday Once More", "The Beatles",
                                                   seconds: 205)),
            .reject
        )
    }

    // MARK: - Boundaries

    /// Two seconds is what LRCLIB itself treats as the same recording, so the boundary belongs
    /// to `.accept` — inclusive on the timed side.
    func testExactlyTwoSecondsIsStillTimed() {
        let track = Fixtures.track("v1", title: "Strobe", artist: "deadmau5", durationSeconds: 634)

        XCTAssertEqual(
            LyricsMatch.score(track: track,
                              candidate: candidate("Strobe", "deadmau5", seconds: 636)),
            .accept
        )
        XCTAssertEqual(
            LyricsMatch.score(track: track,
                              candidate: candidate("Strobe", "deadmau5", seconds: 632)),
            .accept,
            "The tolerance is a magnitude, not a direction — a candidate two seconds short is "
            + "the same recording as one two seconds long"
        )
    }

    /// Fifteen is the last value that is still "probably the same song, badly measured"; the
    /// spec says *over* fifteen is a different cut, so the boundary belongs to the words-only
    /// side rather than to `.reject`.
    func testExactlyFifteenSecondsIsWordsOnlyAndSixteenIsNothing() {
        let track = Fixtures.track("v1", title: "Karma Police",
                                   artist: "Radiohead", durationSeconds: 261)

        XCTAssertEqual(
            LyricsMatch.score(track: track,
                              candidate: candidate("Karma Police", "Radiohead", seconds: 276)),
            .acceptUntimedOnly
        )
        XCTAssertEqual(
            LyricsMatch.score(track: track,
                              candidate: candidate("Karma Police", "Radiohead", seconds: 277)),
            .reject
        )
    }

    /// The one-second boundary between the two accepting verdicts, asserted from both sides so
    /// that a future tuning of the thresholds has to be deliberate.
    func testThreeSecondsIsAlreadyUntimed() {
        let track = Fixtures.track("v1", title: "Teardrop",
                                   artist: "Massive Attack", durationSeconds: 330)

        XCTAssertEqual(
            LyricsMatch.score(track: track,
                              candidate: candidate("Teardrop", "Massive Attack", seconds: 333)),
            .acceptUntimedOnly
        )
    }

    // MARK: - Missing evidence

    /// A track imported without a length, or one whose duration has not been reconciled yet.
    /// There is nothing to veto a live take with, so the words are shown and the timing is not.
    func testATrackWithNoDurationGetsWordsOnly() {
        let track = Fixtures.track("v1", title: "Redbone",
                                   artist: "Childish Gambino", durationSeconds: nil)

        XCTAssertEqual(
            LyricsMatch.score(track: track,
                              candidate: candidate("Redbone", "Childish Gambino", seconds: 326)),
            .acceptUntimedOnly
        )
    }

    func testANoDurationTrackWithADisagreeingArtistIsStillRejected() {
        let track = Fixtures.track("v1", title: "Redbone",
                                   artist: "Childish Gambino", durationSeconds: nil)

        XCTAssertEqual(
            LyricsMatch.score(track: track,
                              candidate: candidate("Redbone", "Bad Bunny", seconds: 326)),
            .reject,
            "A missing duration removes the veto, not the requirement that this be the song"
        )
    }

    /// `/api/search` results carry a duration; a hand-contributed one occasionally does not.
    func testACandidateWithNoDurationGetsWordsOnly() {
        let track = Fixtures.track("v1", title: "Redbone",
                                   artist: "Childish Gambino", durationSeconds: 326)

        XCTAssertEqual(
            LyricsMatch.score(track: track,
                              candidate: candidate("Redbone", "Childish Gambino", seconds: nil)),
            .acceptUntimedOnly
        )
    }

    /// Two names written in different alphabets are an absence of evidence, not a disagreement —
    /// the distinction `TrackMatcher.ArtistName.agreement` draws, and the reason every romanised
    /// J-pop and K-pop row is not a miss here either.
    func testARomanisedCreditIsNotTreatedAsADifferentArtist() {
        let track = Fixtures.track("v1", title: "Lemon",
                                   artist: "Kenshi Yonezu", durationSeconds: 256)

        XCTAssertEqual(
            LyricsMatch.score(track: track,
                              candidate: candidate("Lemon", "米津玄師", seconds: 256)),
            .accept
        )
    }

    // MARK: - Variants that survive the duration test

    /// A remix can be within two seconds of the original and share both fields. Nothing but the
    /// variant vocabulary can tell them apart, which is why the marker comparison runs before
    /// the durations are looked at.
    func testARemixOfTheSameLengthIsRejected() {
        let track = Fixtures.track("v1", title: "Blinding Lights",
                                   artist: "The Weeknd", durationSeconds: 200)

        XCTAssertEqual(
            LyricsMatch.score(track: track,
                              candidate: candidate("Blinding Lights (Remix)", "The Weeknd",
                                                   seconds: 200)),
            .reject
        )
    }

    /// The honest case the counting exists to protect: one "live" on each side is a song whose
    /// title contains the word, not a live recording.
    func testASongWhoseTitleContainsAVariantWordStillMatches() {
        let track = Fixtures.track("v1", title: "Live and Let Die",
                                   artist: "Wings", durationSeconds: 193)

        XCTAssertEqual(
            LyricsMatch.score(track: track,
                              candidate: candidate("Live and Let Die - Remastered 2010", "Wings",
                                                   seconds: 193)),
            .accept
        )
    }
}
