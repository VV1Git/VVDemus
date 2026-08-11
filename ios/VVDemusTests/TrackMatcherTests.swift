import XCTest
@testable import VVDemus

/// The scorer that decides which YouTube Music search result is the song Spotify meant.
///
/// This is the one part of the import that fails silently: a bad match is not an error, it is a
/// karaoke backing track sitting in the user's playlist looking exactly like a real song until
/// they press play three weeks later. Every case below is a shape that actually comes back from
/// a Songs-filtered search, and each asserts either "this must still match" or "this must be a
/// reported miss" — never "this is close enough".
///
/// No network, no store: two values in, an optional `Track` out.
final class TrackMatcherTests: XCTestCase {

    private func spotify(_ title: String, _ artist: String, _ ms: Int?) -> SpotifyTrack {
        SpotifyTrack(title: title, artist: artist, durationMs: ms)
    }

    // MARK: - Decoration that is not load-bearing

    /// YouTube Music's catalogue is full of "- Remastered 2011" and "(Remastered)" suffixes that
    /// Spotify's title does not carry. Refusing those would turn most of a classic-rock playlist
    /// into misses even though the recording is byte-for-byte the one that was asked for.
    func testARemasterSuffixStillMatchesTheOriginalRecording() {
        let wanted = spotify("Bohemian Rhapsody", "Queen", 354_000)
        let candidates = [
            Fixtures.track("v1", title: "Bohemian Rhapsody - Remastered 2011",
                           artist: "Queen - Topic", durationSeconds: 355),
        ]

        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: candidates)?.videoId, "v1",
                       "A remaster suffix is packaging, not a different recording — stripping it "
                       + "is the difference between importing a playlist and reporting it as 50 misses")
    }

    /// Same story for "(Radio Edit)", "(Official Video)" and "(Deluxe)": vocabulary that says
    /// something about the upload, nothing about which performance it is.
    func testRadioEditAndVideoDecorationsAreIgnored() {
        let wanted = spotify("Levels", "Avicii", 200_000)
        let candidates = [
            Fixtures.track("v1", title: "Levels (Radio Edit) (Official Video)",
                           artist: "Avicii", durationSeconds: 199),
        ]

        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: candidates)?.videoId, "v1")
    }

    /// Spotify hangs soundtrack attributions off the end of the title with a dash. YouTube Music
    /// carries none of it, so the two titles overlap in one word out of eight and a whole-title
    /// comparison rates the correct result at about 0.2 — which is half a film soundtrack
    /// reported as misses.
    func testASoundtrackAttributionOnTheSpotifySideIsNotTakenAsPartOfTheTitle() {
        let wanted = spotify("Sunflower - Spider-Man: Into the Spider-Verse",
                             "Post Malone, Swae Lee", 158_000)
        let candidates = [
            Fixtures.track("v1", title: "Sunflower", artist: "Post Malone", durationSeconds: 158),
        ]

        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: candidates)?.videoId, "v1")
    }

    /// Pins the decoration vocabulary itself, which the two tests above do not: they were both
    /// carried by the core comparison, so emptying `decorationWords` entirely — or dropping any
    /// single word from it, "remastered" included — left every assertion in this file green
    /// while real imports quietly got worse. The two candidates here are the same shape and
    /// differ only in whether their suffix is in the list, so the list is what decides.
    func testTheDecorationVocabularyIsWhatSeparatesPackagingFromAVariant() {
        let wanted = spotify("Bohemian Rhapsody", "Queen", 354_000)

        XCTAssertEqual(
            TrackMatcher.bestMatch(
                for: wanted,
                among: [Fixtures.track("v1", title: "Bohemian Rhapsody - Remastered 2011",
                                       artist: "Queen - Topic", durationSeconds: 355)]
            )?.videoId,
            "v1",
            "'remastered' is in the vocabulary, so the suffix is packaging and comes off"
        )

        XCTAssertNil(
            TrackMatcher.bestMatch(
                for: wanted,
                among: [Fixtures.track("v2", title: "Bohemian Rhapsody (Bass Boosted)",
                                       artist: "Queen - Topic", durationSeconds: 355)]
            ),
            "Identical shape, identical artist and length: the only difference is that this "
            + "suffix is not vocabulary, and that alone has to decide it"
        )
    }

    // MARK: - Decoration that is load-bearing

    /// The trap in stripping suffixes: "Blinding Lights - Remix" is a different recording, and it
    /// is exactly as close to the plain title as "Blinding Lights - Remastered" is. Duration and
    /// artist both agree here, so only the variant word itself can save us.
    func testARemixIsNotAcceptedForTheOriginal() {
        let wanted = spotify("Blinding Lights", "The Weeknd", 200_000)
        let candidates = [
            Fixtures.track("v1", title: "Blinding Lights - Remix",
                           artist: "The Weeknd", durationSeconds: 200),
        ]

        XCTAssertNil(TrackMatcher.bestMatch(for: wanted, among: candidates),
                     "A remix has the same artist and can have the same length; if the variant "
                     + "word doesn't reject it, nothing does")
    }

    /// Sped-up and nightcore edits are the single most common junk result for anything that was
    /// briefly popular on TikTok. They are often uploaded with no duration in the search response
    /// at all, so the duration check cannot be what catches them.
    func testASpedUpUploadIsRejectedEvenWithNoDurationToCompare() {
        let wanted = spotify("Heat Waves", "Glass Animals", 238_000)
        let spedUp = Fixtures.track("v1", title: "Heat Waves (Sped Up)",
                                    artist: "Glass Animals", durationSeconds: nil)

        XCTAssertNil(TrackMatcher.bestMatch(for: wanted, among: [spedUp]),
                     "Missing duration must not become permission to guess")

        let real = Fixtures.track("v2", title: "Heat Waves",
                                  artist: "Glass Animals", durationSeconds: 239)
        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: [spedUp, real])?.videoId, "v2",
                       "The real upload is still reachable when it is in the same result page")
    }

    /// The variant dictionary can never be complete, and for a long time an unlisted word was
    /// worth nothing at all: the core comparison drops *every* suffix, recognised or not, so any
    /// candidate differing only by a bracket scored 0.85 on the title and sailed past the 0.66
    /// threshold. "(Speed Up)" — "speed" and "up" are not in `variantWords`, only "sped" is —
    /// was measured being imported for the plain song at 0.850, next to a "(Slowed Down)" that
    /// was correctly refused, purely because one phrasing happened to be in the dictionary.
    func testAVariantSuffixWeHaveNoWordForIsStillRefused() {
        let wanted = spotify("Heat Waves", "Glass Animals", 238_000)
        let candidates = [
            Fixtures.track("v1", title: "Heat Waves (Speed Up)",
                           artist: "Glass Animals", durationSeconds: 238),
        ]

        XCTAssertNil(TrackMatcher.bestMatch(for: wanted, among: candidates),
                     "An unrecognised suffix must not be dropped as if it were packaging — the "
                     + "dictionary will always be one TikTok edit behind, so the scorer cannot "
                     + "treat 'not in the dictionary' as 'not significant'")

        let boosted = Fixtures.track("v2", title: "Blinding Lights (Bass Boosted)",
                                     artist: "The Weeknd", durationSeconds: 200)
        XCTAssertNil(
            TrackMatcher.bestMatch(for: spotify("Blinding Lights", "The Weeknd", 200_000),
                                   among: [boosted]),
            "Same shape, different unlisted word: 'boosted' is not in the dictionary either"
        )
    }

    /// The worst reading of the same defect: an unrecognised suffix, an artist string nobody can
    /// read and no duration on the candidate at all still added up to 0.679 and an import. Three
    /// pieces of missing evidence are not a match.
    func testAnUnrecognisedSuffixWithNoOtherEvidenceIsNotAnImport() {
        let wanted = spotify("Heat Waves", "Glass Animals", 238_000)
        let candidates = [
            Fixtures.track("v1", title: "Heat Waves (Bass Boosted)",
                           artist: "Unknown Artist", durationSeconds: nil),
        ]

        XCTAssertNil(TrackMatcher.bestMatch(for: wanted, among: candidates))
    }

    /// The relaxation the two cases above tightened has to survive in the direction it was built
    /// for. A suffix the Spotify row itself accounts for — the artist's name written into the
    /// YouTube title, or the soundtrack Spotify already named — is not evidence of a different
    /// recording, and refusing those would trade one silent-wrong-match bug for a wall of misses.
    func testASuffixTheSpotifyRowAlreadyAccountsForIsStillDropped() {
        XCTAssertEqual(
            TrackMatcher.bestMatch(
                for: spotify("Shape of You", "Ed Sheeran", 234_000),
                among: [Fixtures.track("v1", title: "Shape of You - Ed Sheeran",
                                       artist: "Ed Sheeran", durationSeconds: 234)]
            )?.videoId,
            "v1",
            "Uploads titled 'Song - Artist' are everywhere; the artist is named on both sides"
        )

        XCTAssertEqual(
            TrackMatcher.bestMatch(
                for: spotify("Sunflower - Spider-Man: Into the Spider-Verse",
                             "Post Malone, Swae Lee", 158_000),
                among: [Fixtures.track("v1", title: "Sunflower (From Spider-Man: Into the Spider-Verse)",
                                       artist: "Post Malone", durationSeconds: 158)]
            )?.videoId,
            "v1",
            "Both catalogues named the same film, just in different brackets"
        )
    }

    /// Variant words used to be compared as sets, which made every song whose real title already
    /// contains one permanently blind to that variant: "Live Forever" and "Live Forever - Live at
    /// Knebworth" both reduce to `{live}`, so the Knebworth take passed the one gate built to
    /// catch it — with the same artist and a three-second length difference, nothing else could.
    func testALiveTakeOfASongWhoseTitleContainsLiveIsStillRejected() {
        let wanted = spotify("Live Forever", "Oasis", 276_000)
        let knebworth = Fixtures.track("v1", title: "Live Forever - Live at Knebworth",
                                       artist: "Oasis", durationSeconds: 279)

        XCTAssertNil(TrackMatcher.bestMatch(for: wanted, among: [knebworth]),
                     "Two occurrences of 'live' are not one occurrence; collapsing them into a "
                     + "set is what let a live album into a studio playlist")

        XCTAssertNil(
            TrackMatcher.bestMatch(for: spotify("Live and Let Die", "Wings", 192_000),
                                   among: [Fixtures.track("v2", title: "Live and Let Die (Live)",
                                                          artist: "Wings", durationSeconds: 200)])
        )

        // And the case the set comparison existed for is untouched: one `live` on each side.
        XCTAssertEqual(
            TrackMatcher.bestMatch(
                for: spotify("Live and Let Die", "Wings", 192_000),
                among: [Fixtures.track("v3", title: "Live and Let Die - Remastered 2011",
                                       artist: "Wings", durationSeconds: 193)]
            )?.videoId,
            "v3",
            "A song whose real title contains a variant word must still be importable"
        )
    }

    /// "Original Mix" is what the dance catalogue calls the *original*, and YouTube Music carries
    /// the Beatport-style suffix where Spotify does not. Treating its "mix" as a variant word
    /// reported the correct master — same artist, same millisecond count — as a miss, which is
    /// most of an electronic playlist.
    func testAnOriginalMixIsTheOriginalAndNotADifferentRecording() {
        let wanted = spotify("Strobe", "deadmau5", 634_000)
        let candidates = [
            Fixtures.track("v1", title: "Strobe (Original Mix)",
                           artist: "deadmau5", durationSeconds: 634),
        ]

        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: candidates)?.videoId, "v1")

        // Keyed on the pair, not on the word: an extended or club mix really is another cut, so
        // "mix" must not become ordinary decoration on its own.
        XCTAssertNil(
            TrackMatcher.bestMatch(for: wanted,
                                   among: [Fixtures.track("v2", title: "Strobe (Extended Mix)",
                                                          artist: "deadmau5", durationSeconds: 640)])
        )
        XCTAssertNil(
            TrackMatcher.bestMatch(for: wanted,
                                   among: [Fixtures.track("v3", title: "Strobe (Club Mix)",
                                                          artist: "deadmau5", durationSeconds: 634)])
        )
    }

    /// Karaoke channels title their uploads with the real song and the real artist, which makes
    /// them score perfectly on everything except the one word that matters.
    func testAKaraokeVersionIsRejected() {
        let wanted = spotify("Vampire", "Olivia Rodrigo", 219_000)
        let candidates = [
            Fixtures.track("v1", title: "Vampire (Karaoke Version)",
                           artist: "Olivia Rodrigo", durationSeconds: 219),
        ]

        XCTAssertNil(TrackMatcher.bestMatch(for: wanted, among: candidates))
    }

    // MARK: - Artist strings that don't look alike

    /// Nearly every real song in YouTube Music search comes back under an auto-generated
    /// "<Artist> - Topic" channel. Comparing artist strings for equality would reject the entire
    /// catalogue.
    func testATopicChannelCountsAsTheArtist() {
        let wanted = spotify("Creep", "Radiohead", 238_000)
        let candidates = [
            Fixtures.track("v1", title: "Creep", artist: "Radiohead - Topic", durationSeconds: 239),
        ]

        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: candidates)?.videoId, "v1")
    }

    /// The other channel shape is a label channel with the name run together and a suffix glued
    /// on — "TheWeekndVEVO" shares no whitespace-separated token with "The Weeknd", so a token
    /// comparison alone scores it zero and the right result gets thrown away.
    func testAVevoChannelCountsAsTheArtist() {
        let wanted = spotify("Blinding Lights", "The Weeknd", 200_000)
        let candidates = [
            Fixtures.track("v1", title: "Blinding Lights",
                           artist: "TheWeekndVEVO", durationSeconds: 200),
        ]

        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: candidates)?.videoId, "v1")
    }

    /// Spotify comma-joins every credited artist while YouTube usually names only the lead, so
    /// the two sides are routinely unequal even when they agree. Containment, not equality.
    func testAMultiArtistSpotifyStringMatchesTheLeadArtistAlone() {
        let wanted = spotify("One Kiss", "Calvin Harris, Dua Lipa", 214_000)
        let candidates = [
            Fixtures.track("v1", title: "One Kiss", artist: "Calvin Harris", durationSeconds: 214),
        ]

        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: candidates)?.videoId, "v1")
    }

    /// A featured artist appears in the title on one side and in the artist field on the other,
    /// in whichever combination the two catalogues happen to disagree on today.
    func testAFeaturedArtistOnOnlyOneSideStillMatches() {
        let wanted = spotify("Stay", "The Kid LAROI, Justin Bieber", 141_000)
        let candidates = [
            Fixtures.track("v1", title: "STAY (feat. Justin Bieber)",
                           artist: "The Kid LAROI", durationSeconds: 141),
        ]

        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: candidates)?.videoId, "v1")
    }

    /// A cover by somebody else is titled identically and is often the same length. The artist
    /// field is the only thing that distinguishes it, so total artist disagreement has to be
    /// fatal rather than merely expensive.
    func testACoverByADifferentArtistIsRejected() {
        let wanted = spotify("Fast Car", "Tracy Chapman", 296_000)
        let candidates = [
            Fixtures.track("v1", title: "Fast Car", artist: "Luke Combs", durationSeconds: 297),
        ]

        XCTAssertNil(TrackMatcher.bestMatch(for: wanted, among: candidates))
    }

    /// The gate above only ever caught impostors whose name shares *nothing* with the real one.
    /// A tribute or karaoke channel names itself after the artist, so its credit *contains* the
    /// wanted one and the containment rule handed it a perfect 1.0 — and it titles its uploads
    /// plainly, so no variant word appears in the title either. Measured at 1.000 and imported.
    func testATributeBandNamedAfterTheArtistIsNotTheArtist() {
        let wanted = spotify("Nothing Else Matters", "Metallica", 388_000)
        let tribute = Fixtures.track("v1", title: "Nothing Else Matters",
                                     artist: "Metallica Tribute Band", durationSeconds: 389)

        XCTAssertNil(TrackMatcher.bestMatch(for: wanted, among: [tribute]),
                     "A credit containing the artist's name is not the artist; the variant "
                     + "vocabulary has to be read off the credit as well as the title")

        // The real recording is not always the closer length — here it is six seconds out, which
        // used to lose outright to the tribute's perfect score.
        let real = Fixtures.track("v2", title: "Nothing Else Matters",
                                  artist: "Metallica", durationSeconds: 394)
        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: [tribute, real])?.videoId, "v2")
    }

    /// A composer-only credit is a different story and must keep matching: YouTube Music files a
    /// great deal of classical under the composer alone, and refusing it would turn every
    /// classical row into a miss. Containment is right here — it is only the variant vocabulary
    /// above that had to be added.
    func testAComposerOnlyCreditStillMatchesAPerformerCredit() {
        let wanted = spotify("Nocturne in E-Flat Major, Op. 9 No. 2",
                             "Frédéric Chopin, Arthur Rubinstein", 270_000)
        let candidates = [
            Fixtures.track("v1", title: "Nocturne in E-Flat Major, Op. 9 No. 2",
                           artist: "Frédéric Chopin", durationSeconds: 262),
        ]

        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: candidates)?.videoId, "v1")
    }

    /// One shared token, and it is the surname: Natalie Cole's 1991 "Unforgettable" is within a
    /// second of Nat King Cole's 1951 original and titled identically, and a half-credit of
    /// artist agreement was worth enough to carry it over the threshold at 0.885. Namesakes are
    /// common enough — Willie and Lukas Nelson, the Marleys, the Coles — that a surname on its
    /// own cannot count as evidence.
    func testASharedSurnameAloneIsNotEnoughToAcceptADifferentArtist() {
        let wanted = spotify("Unforgettable", "Nat King Cole", 209_000)
        let daughter = Fixtures.track("v1", title: "Unforgettable",
                                      artist: "Natalie Cole", durationSeconds: 210)

        XCTAssertNil(TrackMatcher.bestMatch(for: wanted, among: [daughter]),
                     "This bites exactly when YouTube Music surfaces the cover and not the "
                     + "original, which is the case the user has no way to check")

        let original = Fixtures.track("v2", title: "Unforgettable",
                                      artist: "Nat King Cole", durationSeconds: 209)
        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: [daughter, original])?.videoId,
                       "v2")
    }

    /// Partial agreement is still worth something when the *leading* name is the shared one —
    /// that is a line-up difference between two catalogues, not a different artist.
    func testPartialArtistAgreementOnTheLeadingNameStillMatches() {
        let wanted = spotify("Save Your Tears", "The Weeknd, Ariana Grande", 191_000)
        let candidates = [
            Fixtures.track("v1", title: "Save Your Tears",
                           artist: "The Weeknd, Doja Cat", durationSeconds: 191),
        ]

        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: candidates)?.videoId, "v1")
    }

    /// Spotify romanises the credit and YouTube Music answers with the catalogue's own name.
    /// Nothing here transliterates, so the two share no token and scored a flat 0 — which is
    /// fatal, so an identical title and an exact duration counted for nothing and a J-pop or
    /// K-pop playlist imported as a wall of misses. Two names with no letters in common are an
    /// absence of evidence, exactly like the unreadable credit that has always been tolerated.
    func testAnArtistWrittenInAnotherScriptIsNotTreatedAsADifferentArtist() {
        XCTAssertEqual(
            TrackMatcher.bestMatch(
                for: spotify("Lemon", "Kenshi Yonezu", 256_000),
                among: [Fixtures.track("v1", title: "Lemon", artist: "米津玄師", durationSeconds: 256)]
            )?.videoId,
            "v1"
        )
        XCTAssertEqual(
            TrackMatcher.bestMatch(
                for: spotify("Dynamite", "BTS", 199_000),
                among: [Fixtures.track("v1", title: "Dynamite", artist: "방탄소년단", durationSeconds: 199)]
            )?.videoId,
            "v1"
        )
        XCTAssertEqual(
            TrackMatcher.bestMatch(
                for: spotify("Gruppa Krovi", "Kino", 285_000),
                among: [Fixtures.track("v1", title: "Gruppa Krovi", artist: "Кино", durationSeconds: 285)]
            )?.videoId,
            "v1"
        )

        // Same alphabet, nothing in common: still a cover, still fatal. The relaxation is about
        // being unable to compare two names, not about being unable to tell them apart.
        XCTAssertNil(
            TrackMatcher.bestMatch(
                for: spotify("Lemon", "Kenshi Yonezu", 256_000),
                among: [Fixtures.track("v2", title: "Lemon", artist: "Rihanna", durationSeconds: 256)]
            )
        )
    }

    // MARK: - Duration as evidence

    /// A live recording of a song is frequently uploaded under the plain studio title with the
    /// plain artist — nothing in the text gives it away. Spotify hands us exact milliseconds, so
    /// a minute of crowd noise and an extended outro is the signal that this is not the take the
    /// playlist asked for.
    func testALiveTakeWithNoTellInTheTitleIsRejectedOnLength() {
        let wanted = spotify("Creep", "Radiohead", 238_000)
        let liveTake = Fixtures.track("v1", title: "Creep", artist: "Radiohead", durationSeconds: 302)

        XCTAssertNil(TrackMatcher.bestMatch(for: wanted, among: [liveTake]),
                     "Sixty-four seconds is a different performance, not a different encode")

        let studio = Fixtures.track("v2", title: "Creep", artist: "Radiohead", durationSeconds: 239)
        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: [liveTake, studio])?.videoId, "v2",
                       "The length check must reject the wrong take without rejecting the right one")
    }

    /// An hour-long "Top 100 Hits" or "Best of" upload is classified as a song by YouTube Music
    /// and comes back from a Songs-filtered search looking ordinary — `Track.isLongFormMix`
    /// exists for exactly this. Here Spotify sent no duration at all, so the length comparison
    /// cannot fire and the mix guard is the only thing standing between the user and a
    /// three-hour queue hijack.
    func testALongFormMixIsNeverTheMatch() {
        let wanted = spotify("Levitating", "Dua Lipa", nil)
        let compilation = Fixtures.track("v1", title: "Levitating", artist: "Dua Lipa",
                                         durationSeconds: 3_820)

        XCTAssertNil(TrackMatcher.bestMatch(for: wanted, among: [compilation]))

        let song = Fixtures.track("v2", title: "Levitating", artist: "Dua Lipa", durationSeconds: 203)
        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: [compilation, song])?.videoId, "v2")
    }

    // MARK: - Choosing between plausible candidates

    /// Search returns the album version, the single edit and the sped-up rip all under the same
    /// name and artist. Everything textual ties, so the exact millisecond count is what picks
    /// the winner — and it must win from behind, not by being first in the list.
    func testTheClosestLengthWinsWhenSeveralCandidatesAreAcceptable() {
        let wanted = spotify("Blinding Lights", "The Weeknd", 200_040)
        let candidates = [
            Fixtures.track("v1", title: "Blinding Lights",
                           artist: "The Weeknd - Topic", durationSeconds: 207),
            Fixtures.track("v2", title: "Blinding Lights",
                           artist: "The Weeknd", durationSeconds: 200),
        ]

        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: candidates)?.videoId, "v2",
                       "Result order is relevance to a text query, not to a specific recording; "
                       + "taking the first acceptable candidate imports the wrong cut")
    }

    // MARK: - Titles that aren't plain ASCII

    /// Spotify writes "Déjà Vu" and YouTube Music writes "Deja Vu" (and vice versa) with no
    /// pattern to it. Without folding, every accented title in a French or Spanish playlist is
    /// reported as a miss.
    func testDiacriticsFoldSoAccentedTitlesMatch() {
        let wanted = spotify("Déjà Vu", "Olivia Rodrigo", 215_000)
        let candidates = [
            Fixtures.track("v1", title: "Deja Vu", artist: "Olivia Rodrigo - Topic",
                           durationSeconds: 215),
        ]

        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: candidates)?.videoId, "v1")
    }

    /// Japanese and Korean titles have no spaces to tokenise on. A word-based comparison that
    /// silently scores them zero would make every J-pop playlist import as nothing but misses.
    func testANonLatinTitleMatchesItself() {
        let wanted = spotify("夜に駆ける", "YOASOBI", 261_000)
        let candidates = [
            Fixtures.track("v1", title: "夜に駆ける", artist: "YOASOBI - Topic", durationSeconds: 261),
        ]

        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: candidates)?.videoId, "v1")
    }

    // MARK: - Normalisation edges

    /// Interlude and skit tracks are sometimes titled as nothing but a parenthetical. A stripper
    /// that removes every bracket unconditionally normalises those to the empty string, and two
    /// empty strings compare as a perfect match — so the first junk result in the list wins with
    /// a score of 1.0. Both candidates here would be indistinguishable under that bug.
    func testATitleThatIsEntirelyAParentheticalDoesNotNormaliseToNothing() {
        let wanted = spotify("(Audio)", "Frank Ocean", 90_000)
        let candidates = [
            Fixtures.track("v1", title: "(Official Video)", artist: "Frank Ocean", durationSeconds: 90),
            Fixtures.track("v2", title: "(Audio)", artist: "Frank Ocean", durationSeconds: 90),
        ]

        XCTAssertEqual(TrackMatcher.bestMatch(for: wanted, among: candidates)?.videoId, "v2",
                       "An empty normalised title matches everything, which is the worst possible "
                       + "failure mode for a scorer whose job is to refuse")
    }

    /// The title is the floor: "Yesterday Once More" shares its whole opening with "Yesterday",
    /// so a containment-style title score reads as a perfect hit. Artist and duration are pinned
    /// to agree here precisely so that nothing else can rescue it.
    func testASongThatMerelyStartsTheSameIsRejectedNoMatterWhatElseAgrees() {
        let wanted = spotify("Yesterday", "The Beatles", 125_000)
        let candidates = [
            Fixtures.track("v1", title: "Yesterday Once More",
                           artist: "The Beatles - Topic", durationSeconds: 125),
        ]

        XCTAssertNil(TrackMatcher.bestMatch(for: wanted, among: candidates))
    }

    /// `InnerTubeClient.parseSearchItem` substitutes these literals when the renderer is missing
    /// the field. They are not names, and treating them as ones lets a malformed result win.
    func testTheUnknownTitlePlaceholderIsNeverAMatch() {
        let wanted = spotify("Unknown Title", "Unknown Artist", 180_000)
        let candidates = [
            Fixtures.track("v1", title: "Unknown Title", artist: "Unknown Artist",
                           durationSeconds: 180),
        ]

        XCTAssertNil(TrackMatcher.bestMatch(for: wanted, among: candidates))
    }

    // MARK: - Refusing is the point

    /// An obscure track returns an empty array rather than throwing, so "search found nothing"
    /// arrives here as a normal call with no candidates.
    func testNoCandidatesIsAMissRatherThanACrash() {
        XCTAssertNil(TrackMatcher.bestMatch(for: spotify("Anything", "Anyone", 200_000), among: []))
    }

    /// Search always returns *something* for a query with real words in it. When the playlist
    /// holds a track YouTube Music does not have, these unrelated results are what comes back,
    /// and the honest answer is a reported miss.
    func testNothingCloseEnoughIsAMissRatherThanAGuess() {
        let wanted = spotify("Vampire", "Olivia Rodrigo", 219_000)
        let candidates = [
            Fixtures.track("v1", title: "Vampires Will Never Hurt You",
                           artist: "My Chemical Romance", durationSeconds: 240),
            Fixtures.track("v2", title: "Vampire", artist: "Sing King Karaoke",
                           durationSeconds: 219),
            Fixtures.track("v3", title: "Vampire Money", artist: "My Chemical Romance",
                           durationSeconds: 220),
        ]

        XCTAssertNil(TrackMatcher.bestMatch(for: wanted, among: candidates),
                     "Three near-misses are not one hit; a reported miss is recoverable by hand, "
                     + "a wrong track in the playlist is not even noticed")
    }
}
