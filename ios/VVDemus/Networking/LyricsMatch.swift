import Foundation

/// How far a lyrics result is trusted for a track: all the way, words only, or not at all.
///
/// The middle case is the reason this is not a `Bool`. A result whose title and artist agree but
/// whose length does not is very probably the same song and very probably not the same *take* —
/// a remaster, a single edit, a different encode. Without a third verdict that collapses into
/// either discarding words that were right or scrolling timings that were not, and the second of
/// those is worse than showing nothing at all.
enum LyricsVerdict {
    case accept
    case acceptUntimedOnly
    case reject
}

/// The identifying fields of one lyrics result, from LRCLIB's exact lookup or its `/api/search`.
///
/// A struct rather than the response type so the decision stays a pure function of four values:
/// the interesting cases here — the live take, the cover, the missing duration — are ones that
/// only appear in a real response for a real song, and this is what lets them be provoked
/// directly in `VVDemusTests`.
struct LyricsCandidate {
    let title: String
    let artist: String
    let album: String?
    let durationSeconds: Int?
}

/// Decides whether a lyrics result belongs to the track that was asked for.
///
/// Duration is the strong signal, because the case that actually bites — a live cut, an extended
/// mix, a sped-up rip — agrees on every text field and differs only in length. Title and artist
/// agreement is the gate that duration cannot supply on its own: a cover runs to the second.
///
/// Every text comparison here is `TrackMatcher`'s. Its strip lists already know that
/// "- Remastered 2011" is packaging and "(Remix)" is not, that "Queen - Topic" is Queen, and
/// that a credit in another alphabet is an absence of evidence rather than a disagreement. A
/// second copy of any of that would drift from the first, and the drift would show up as lyrics
/// that scroll for the wrong recording, which is exactly the failure this type exists to stop.
enum LyricsMatch {

    static func score(track: Track, candidate: LyricsCandidate) -> LyricsVerdict {
        guard textAgrees(track: track, candidate: candidate) else { return .reject }

        // No length on either side is not permission — it is the loss of the only signal that
        // separates this recording from a live one of the same song, so the words are shown and
        // the timing is not.
        guard let wanted = track.durationSeconds,
              let theirs = candidate.durationSeconds else { return .acceptUntimedOnly }

        let delta = abs(wanted - theirs)
        // Both boundaries fall on the more generous side. Two seconds is what LRCLIB itself
        // treats as the same recording, so exactly two is still timed; fifteen is where a
        // different cut starts, so exactly fifteen is still worth its words. Thresholds to be
        // tuned against real tracks — the tests assert which side each boundary is on so that
        // tuning them has to be deliberate.
        switch delta {
        case ...timedTolerance: return .accept
        case ...wordsTolerance: return .acceptUntimedOnly
        default: return .reject
        }
    }

    private static let timedTolerance = 2
    private static let wordsTolerance = 15

    private static func textAgrees(track: Track, candidate: LyricsCandidate) -> Bool {
        let wantedTitle = TrackMatcher.normalisedTitle(track.title)
        let theirTitle = TrackMatcher.normalisedTitle(candidate.title)

        // Run before anything is scored, for the reason `TrackMatcher` gives: a remix or a
        // karaoke take can sit inside the two-second window with a title and a credit that
        // otherwise agree perfectly, and no similarity measure can tell it from the master.
        // Counted rather than collected, so "Live Forever" is not mistaken for "Live Forever -
        // Live at Knebworth" by the one occurrence they share.
        guard TrackMatcher.variantMarkers(in: wantedTitle.tokens)
            == TrackMatcher.variantMarkers(in: theirTitle.tokens) else { return false }

        // Compared whole and again on the title proper, because LRCLIB's contributors type the
        // title they saw and one of the two sides routinely carries a soundtrack or album
        // attribution the other never had.
        let whole = TrackMatcher.similarity(wantedTitle.tokens, theirTitle.tokens)
        let core = TrackMatcher.similarity(wantedTitle.core, theirTitle.core)
        guard max(whole, core) >= TrackMatcher.titleFloor else { return false }

        // nil is "neither name is readable, or they are written in different alphabets" — an
        // absence of evidence, and refusing on it would turn every romanised J-pop row into a
        // track with no lyrics. Only an actual disagreement between two names we can both read
        // is fatal, which is what keeps Luke Combs' words off Tracy Chapman's song.
        let artist = TrackMatcher.ArtistName(track.artist)
            .agreement(with: TrackMatcher.ArtistName(candidate.artist))
        return artist != 0
    }
}
