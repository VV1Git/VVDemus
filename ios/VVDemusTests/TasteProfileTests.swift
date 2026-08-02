import XCTest
@testable import VVDemus

/// The affinity model behind the daylist and the "Because you listened to…" shelves.
///
/// Only the pure surface is exercised — `TasteProfile.current()` reads the real singletons,
/// and those write to the simulator's actual `UserDefaults` and Application Support
/// directory, which is how a previous round of tests left the app's own Home feed poisoned
/// with fixture tracks.
final class TasteProfileTests: XCTestCase {

    /// Fixed so decay maths is reproducible rather than dependent on when the suite runs.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// `daysAgo` before `now`, at `hour` local time. Built through `Calendar.current` because
    /// that is what `TimeOfDayBucket` reads — a fixture built in UTC would land in a
    /// different bucket than the one it claims on most of the planet.
    private func date(daysAgo: Int, hour: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        return calendar.startOfDay(for: day).addingTimeInterval(TimeInterval(hour) * 3600)
    }

    private func plays(
        _ track: Track,
        count: Int,
        secondsPlayed: Int = 180,
        hour: Int = 9,
        startingDaysAgo: Int = 0
    ) -> [PlayEvent] {
        (0..<count).map {
            PlayEvent(
                track: track,
                playedAt: date(daysAgo: startingDaysAgo + $0, hour: hour),
                secondsPlayed: secondsPlayed
            )
        }
    }

    // MARK: - Evidence, not row counts

    func testEngagementMeasuresHowMuchWasHeard() {
        let track = Fixtures.track("a", durationSeconds: 200)
        let complete = PlayEvent(track: track, playedAt: now, secondsPlayed: 200)
        let skip = PlayEvent(track: track, playedAt: now, secondsPlayed: 6)

        XCTAssertEqual(TasteProfile.engagement(of: complete), 1, accuracy: 0.0001)
        XCTAssertLessThan(TasteProfile.engagement(of: skip), 0.1, "Six seconds is not a listen")
    }

    /// The old model counted rows in the log, so a track skipped three times looked like a
    /// favourite.
    func testThreeSkipsDoNotOutrankOneCompletePlay() {
        let skipped = Fixtures.track("skipped", artist: "Skipped", durationSeconds: 240)
        let played = Fixtures.track("played", artist: "Played", durationSeconds: 240)
        let events = plays(skipped, count: 3, secondsPlayed: 6) + plays(played, count: 1, secondsPlayed: 240)

        let profile = TasteProfile.build(events: events, bucket: .morning, now: now)

        XCTAssertEqual(profile.candidates.first?.track.id, "played")
    }

    func testThisWeekOutweighsLastSpring() {
        let old = Fixtures.track("old", artist: "Old")
        let recent = Fixtures.track("recent", artist: "Recent")
        let events = plays(old, count: 12, startingDaysAgo: 180) + plays(recent, count: 2)

        let profile = TasteProfile.build(events: events, bucket: .morning, now: now)

        XCTAssertEqual(profile.candidates.first?.track.id, "recent", "Twelve plays half a year ago is a phase, not a taste")
    }

    func testALikedSongOutranksAnEquallyPlayedOne() {
        let liked = Fixtures.track("liked", artist: "Liked")
        let plain = Fixtures.track("plain", artist: "Plain")
        let events = plays(liked, count: 3) + plays(plain, count: 3)

        let profile = TasteProfile.build(events: events, liked: [liked], bucket: .morning, now: now)

        XCTAssertEqual(profile.candidates.first?.track.id, "liked")
        XCTAssertTrue(profile.likedArtists.contains("liked"), "Artists are matched on a normalized key")
    }

    // MARK: - Seeds

    /// Three songs off one album in a row used to become three shelves of the same radio.
    func testSeedsSpreadAcrossArtists() {
        var events = plays(Fixtures.track("dom-1", artist: "Dominant"), count: 1)
        events += plays(Fixtures.track("dom-2", artist: "Dominant"), count: 1)
        events += plays(Fixtures.track("dom-3", artist: "Dominant"), count: 1)
        events += plays(Fixtures.track("b", artist: "Second"), count: 1, startingDaysAgo: 2)
        events += plays(Fixtures.track("c", artist: "Third"), count: 1, startingDaysAgo: 3)

        let seeds = TasteProfile.build(events: events, bucket: .morning, now: now).seeds(3)

        XCTAssertEqual(seeds.count, 3)
        XCTAssertEqual(Set(seeds.map(\.artist)).count, 3, "One artist must not take every seed")
    }

    func testSeedsRepeatAnArtistOnlyWhenThatIsAllThereIs() {
        let events = (0..<3).flatMap { plays(Fixtures.track("t\($0)", artist: "Only"), count: 1, startingDaysAgo: $0) }

        let seeds = TasteProfile.build(events: events, bucket: .morning, now: now).seeds(3)

        XCTAssertEqual(seeds.count, 3, "A one-artist library still has to fill three shelves")
        XCTAssertEqual(Set(seeds.map(\.id)).count, 3, "…with three different songs")
    }

    /// Its radio is three more hours of the same, and one landing in a mix hijacks the queue
    /// for the afternoon.
    func testAnHourLongCompilationIsNeverASeed() {
        let compilation = Fixtures.track("mix", artist: "Compilations", durationSeconds: 3 * 3600)
        let song = Fixtures.track("song", artist: "Band")
        let events = plays(compilation, count: 5, secondsPlayed: 3 * 3600)
            + plays(song, count: 1, startingDaysAgo: 20)

        let seeds = TasteProfile.build(events: events, bucket: .morning, now: now).seeds(2)

        XCTAssertEqual(seeds.map(\.id), ["song"])
    }

    // MARK: - Time of day

    func testTheCurrentBucketBiasesSeedsTowardsWhatIsPlayedThen() {
        let night = Fixtures.track("night", artist: "Night")
        let morning = Fixtures.track("morning", artist: "Morning")
        let events = plays(night, count: 45, hour: 23) + plays(morning, count: 45, hour: 9)

        XCTAssertEqual(
            TasteProfile.build(events: events, bucket: .night, now: now).candidates.first?.track.id,
            "night"
        )
        XCTAssertEqual(
            TasteProfile.build(events: events, bucket: .morning, now: now).candidates.first?.track.id,
            "morning"
        )
    }

    /// There are four buckets, so a young history has almost nothing in the current one.
    /// Letting a single play decide a fifty-track mix is worse than ignoring the clock.
    func testAThinBucketDoesNotOverruleAllTimeTaste() {
        let allDay = Fixtures.track("allday", artist: "All Day")
        let once = Fixtures.track("once", artist: "Once")
        let events = plays(allDay, count: 20, hour: 14) + plays(once, count: 1, hour: 23)

        let profile = TasteProfile.build(events: events, bucket: .night, now: now)

        XCTAssertEqual(profile.candidates.first?.track.id, "allday")
        XCTAssertLessThan(profile.timeOfDayWeight, 0.1)
    }

    // MARK: - Cold start

    func testAFreshInstallHasAnEmptyProfileAndStillRanksAPool() {
        let profile = TasteProfile.build(events: [], bucket: .morning, now: now)

        XCTAssertTrue(profile.isEmpty)
        XCTAssertTrue(profile.seeds(3).isEmpty, "With no seeds the daylist falls back to the mood search")
        XCTAssertTrue(profile.artistAffinity.isEmpty)
        // Ranking a mood-search pool against an empty profile has to behave like the shuffle
        // it replaced: everything scores the same, so everything is still eligible.
        let ranked = profile.rank(Fixtures.tracks(["a", "b", "c"]), limit: 3, jitter: 0)
        XCTAssertEqual(Set(ranked.map(\.id)), ["a", "b", "c"])
    }

    func testLikesAloneAreEnoughToSeedFrom() {
        let profile = TasteProfile.build(
            events: [],
            liked: [Fixtures.track("l", artist: "Liked")],
            bucket: .morning,
            now: now
        )

        XCTAssertEqual(profile.seeds(1).map(\.id), ["l"])
    }

    /// All that exists for history written before `ListeningStatsStore`, or by someone whose
    /// plays have all fallen under its five-second recording floor.
    func testUntimedHistoryStillProducesSeeds() {
        let profile = TasteProfile.build(
            events: [],
            recents: Fixtures.tracks(["a", "b"]),
            bucket: .morning,
            now: now
        )

        XCTAssertEqual(profile.seeds(1).map(\.id), ["a"], "MRU order is the only signal an untimed list carries")
    }

    // MARK: - Ranking the pool

    private func makeProfile(topArtist: String, tracks: Int = 10) -> TasteProfile {
        let events = (0..<tracks).flatMap {
            plays(Fixtures.track("known-\($0)", artist: topArtist), count: 1)
        }
        return TasteProfile.build(events: events, bucket: .morning, now: now)
    }

    func testOneArtistCannotEatTheMix() {
        let profile = makeProfile(topArtist: "Top")
        let pool = (0..<20).map { Fixtures.track("t\($0)", artist: "Top") }
            + (0..<20).map { Fixtures.track("o\($0)", artist: "Other \($0)") }

        let ranked = profile.rank(pool, limit: 20, maxPerArtist: 3, jitter: 0)

        XCTAssertEqual(ranked.count, 20)
        XCTAssertEqual(ranked.filter { $0.artist == "Top" }.count, 3)
    }

    /// Ranking on affinity alone is a closed loop: the profile picks the seeds, the seeds
    /// decide the pool, the profile picks its own artists back out of the pool.
    func testSomeSlotsAreReservedForArtistsTheUserHasNeverHeard() {
        let profile = makeProfile(topArtist: "Known")
        let pool = (0..<20).map { Fixtures.track("k\($0)", artist: "Known") }
            + (0..<20).map { Fixtures.track("n\($0)", artist: "New \($0)") }

        let ranked = profile.rank(pool, limit: 10, maxPerArtist: 10, jitter: 0)

        XCTAssertEqual(ranked.count, 10)
        XCTAssertGreaterThanOrEqual(ranked.filter { $0.artist != "Known" }.count, 2)
    }

    /// Straight score order opens the mix with three songs by the same artist, which is the
    /// one thing the per-artist cap exists to prevent.
    func testTheMixDoesNotOpenWithOneArtistThreeTimes() {
        var events: [PlayEvent] = []
        events += plays(Fixtures.track("a1", artist: "A"), count: 5)
        events += plays(Fixtures.track("b1", artist: "B"), count: 4)
        events += plays(Fixtures.track("c1", artist: "C"), count: 3)
        let profile = TasteProfile.build(events: events, bucket: .morning, now: now)
        let pool = ["A", "B", "C"].flatMap { artist in
            (0..<4).map { Fixtures.track("\(artist)-\($0)", artist: artist) }
        } + (0..<6).map { Fixtures.track("u\($0)", artist: "Unknown \($0)") }

        let ranked = profile.rank(pool, limit: 12, maxPerArtist: 3, jitter: 0)

        XCTAssertEqual(Set(ranked.prefix(3).map(\.artist)).count, 3)
    }

    func testASongFromAStrongSeedsRadioOutranksOneFromTheMoodSearch() {
        let profile = makeProfile(topArtist: "Seed", tracks: 1)
        let fromRadio = Fixtures.track("radio", artist: "Unknown One")
        let fromMood = Fixtures.track("mood", artist: "Unknown Two")

        let ranked = profile.rank([fromMood, fromRadio], provenance: ["radio": 1], limit: 2, jitter: 0)

        XCTAssertEqual(ranked.first?.id, "radio")
    }

    func testRankingNeverDuplicatesOrInventsTracks() {
        let profile = makeProfile(topArtist: "Top")
        let pool = Fixtures.tracks(["a", "b", "c"])

        let ranked = profile.rank(pool, limit: 10, jitter: 0)

        XCTAssertEqual(ranked.count, 3, "Ten slots and three candidates is three tracks")
        XCTAssertEqual(Set(ranked.map(\.id)).count, 3)
    }

    /// A cold start where one lounge channel owns the mood search still has to fill a
    /// daylist, so the cap yields rather than returning a twelve-song mix.
    func testTheArtistCapYieldsRatherThanReturningAShortMix() {
        let profile = TasteProfile.build(events: [], bucket: .morning, now: now)
        let pool = (0..<8).map { Fixtures.track("t\($0)", artist: "Only Artist") }

        let ranked = profile.rank(pool, limit: 8, maxPerArtist: 3, jitter: 0)

        XCTAssertEqual(ranked.count, 8)
    }
}
