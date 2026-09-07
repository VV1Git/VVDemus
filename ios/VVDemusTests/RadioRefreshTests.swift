import XCTest
@testable import VVDemus

/// What Refresh on a radio screen is supposed to do, and the reason it did not.
///
/// The endpoint behind a radio answers the same question nearly the same way every time —
/// two back-to-back calls for one seed shared 31 of their 50 tracks — so "fetch it again"
/// reshuffles a list rather than replacing one. The guarantee is made here instead:
///
/// * the seed stays first,
/// * over half the list is songs the station has not shown,
/// * and nothing survives three refreshes.
///
/// All of it is exercised through the pure policy and a fake `RadioSource`, so the suite
/// never goes near YouTube — and never writes to the app's own `UserDefaults`, which is how
/// a previous round of tests poisoned the real Home feed.
final class RadioRefreshTests: XCTestCase {

    private let length = 50

    private func station(_ count: Int, prefix: String = "old") -> [Track] {
        Fixtures.tracks((0..<count).map { "\(prefix)\($0)" })
    }

    private func pool(_ count: Int, prefix: String) -> [Track] {
        Fixtures.tracks((0..<count).map { "\(prefix)\($0)" })
    }

    private func ids(_ tracks: [Track]) -> [String] { tracks.map(\.videoId) }

    // MARK: - The bar itself

    func testHalfTheListRoundedUp() {
        XCTAssertEqual(RadioRefreshPolicy.requiredNewCount(bodyLength: 49), 25)
        XCTAssertEqual(RadioRefreshPolicy.requiredNewCount(bodyLength: 50), 25)
        XCTAssertEqual(RadioRefreshPolicy.requiredNewCount(bodyLength: 1), 1)
        XCTAssertEqual(RadioRefreshPolicy.requiredNewCount(bodyLength: 0), 0)
    }

    // MARK: - One refresh

    func testARefreshReplacesOverHalfTheListAndKeepsTheSeedFirst() {
        let seed = Fixtures.track("seed")
        let current = [seed] + station(49)

        let outcome = RadioRefreshPolicy.apply(
            seed: seed,
            current: current,
            generations: [:],
            generation: 1,
            candidates: pool(60, prefix: "new"),
            length: length
        )

        XCTAssertEqual(outcome.tracks.count, 50, "A refresh must not cost the station songs")
        XCTAssertEqual(outcome.tracks.first?.videoId, "seed", "The seed is the station")
        XCTAssertTrue(outcome.metRequirement)

        let body = outcome.tracks.dropFirst()
        let fresh = body.filter { $0.videoId.hasPrefix("new") }
        XCTAssertGreaterThanOrEqual(fresh.count * 2, body.count, "Under half the list is not a refresh")
    }

    func testNewAndKeptSongsAlternate() {
        let seed = Fixtures.track("seed")
        let outcome = RadioRefreshPolicy.apply(
            seed: seed,
            current: [seed] + station(9),
            generations: [:],
            generation: 1,
            candidates: pool(9, prefix: "new"),
            length: 10
        )

        // Starting on a new song, so the change is visible in the first row rather than
        // somewhere below the fold.
        XCTAssertEqual(
            ids(outcome.tracks),
            ["seed", "new0", "old0", "new1", "old1", "new2", "old2", "new3", "old3", "new4"]
        )
    }

    func testAShortStationGrowsRatherThanStayingShort() {
        let seed = Fixtures.track("seed")
        let outcome = RadioRefreshPolicy.apply(
            seed: seed,
            current: [seed] + station(6),
            generations: [:],
            generation: 1,
            candidates: pool(60, prefix: "new"),
            length: length
        )

        XCTAssertEqual(outcome.tracks.count, 50)
        XCTAssertTrue(outcome.metRequirement)
    }

    // MARK: - Three refreshes

    func testThreeRefreshesLeaveNothingOfTheOriginalButTheSeed() {
        let seed = Fixtures.track("seed")
        let original = station(49)
        var tracks = [seed] + original
        var generations: [String: Int] = [:]

        for generation in 1...3 {
            let outcome = RadioRefreshPolicy.apply(
                seed: seed,
                current: tracks,
                generations: generations,
                generation: generation,
                candidates: pool(60, prefix: "gen\(generation)-"),
                length: length
            )
            XCTAssertTrue(outcome.metRequirement, "Refresh \(generation) did not clear the bar")
            XCTAssertGreaterThanOrEqual(
                outcome.newCount * 2,
                outcome.tracks.count - 1,
                "Every refresh owes half the list, not just the first"
            )
            tracks = outcome.tracks
            generations = outcome.generations
        }

        XCTAssertEqual(tracks.first?.videoId, "seed")
        XCTAssertEqual(tracks.count, 50)
        let survivors = Set(ids(tracks)).intersection(ids(original))
        XCTAssertTrue(survivors.isEmpty, "Still holding \(survivors.count) of the songs we started with")
    }

    /// The half-the-list rule alone would let a song hang on indefinitely if the pool were
    /// thin one round; the carry-over cap is what makes the three-refresh promise a promise.
    func testASongCannotSurviveThreeRefreshesEvenWithRoomToKeepIt() {
        let seed = Fixtures.track("seed")
        let veteran = Fixtures.track("veteran")
        let current = [seed, veteran] + station(8)

        // `veteran` was introduced two refreshes ago; the rest arrived last refresh. There is
        // easily room to keep all ten, and it must still go.
        var generations = Dictionary(uniqueKeysWithValues: station(8).map { ($0.videoId, 4) })
        generations["veteran"] = 3

        let outcome = RadioRefreshPolicy.apply(
            seed: seed,
            current: current,
            generations: generations,
            generation: 5,
            candidates: pool(60, prefix: "new"),
            length: length
        )

        XCTAssertFalse(ids(outcome.tracks).contains("veteran"))
        XCTAssertTrue(ids(outcome.tracks).contains("old0"), "Last refresh's songs are not veterans yet")
    }

    /// A mix that arrived from the other device by sync carries no generations. Treating that
    /// as "ancient" would replace the whole list on the first refresh — expensive, and it
    /// would usually fail the bar outright.
    func testSongsOfUnknownProvenanceAreTreatedAsOneRefreshOldNotAncient() {
        let seed = Fixtures.track("seed")
        let outcome = RadioRefreshPolicy.apply(
            seed: seed,
            current: [seed] + station(9),
            generations: [:],
            generation: 7,
            candidates: pool(60, prefix: "new"),
            length: 10
        )

        let kept = outcome.tracks.filter { $0.videoId.hasPrefix("old") }
        XCTAssertEqual(kept.count, 4, "Half the list, less the seed, should have survived")
    }

    // MARK: - When YouTube has nothing left

    func testARefreshThatCannotFindEnoughNewSongsIsReportedRatherThanHalfApplied() {
        let seed = Fixtures.track("seed")
        let outcome = RadioRefreshPolicy.apply(
            seed: seed,
            current: [seed] + station(49),
            generations: [:],
            generation: 1,
            candidates: pool(6, prefix: "new"),
            length: length
        )

        XCTAssertEqual(outcome.newCount, 6)
        XCTAssertEqual(outcome.requiredNewCount, 25)
        XCTAssertFalse(outcome.metRequirement, "Six of fifty is the bug, not a refresh")
    }

    func testCandidatesAlreadyInTheListAreNotCountedAsNew() {
        let seed = Fixtures.track("seed")
        let current = [seed] + station(9)

        let outcome = RadioRefreshPolicy.apply(
            seed: seed,
            current: current,
            generations: [:],
            generation: 1,
            // Everything on offer is already on screen, plus the seed itself twice over.
            candidates: [seed] + station(9) + [seed],
            length: 10
        )

        XCTAssertEqual(outcome.newCount, 0)
        XCTAssertFalse(outcome.metRequirement)
    }

    // MARK: - Gathering the candidates

    func testFreshenerPagesTheStationBeforeReachingForNeighbours() async {
        let source = FakeRadioSource()
        source.pages["seed"] = RadioPage(tracks: Fixtures.tracks(["a", "b"]), continuation: "p2")
        source.continuations["p1"] = RadioPage(tracks: Fixtures.tracks(["c", "d", "e"]), continuation: "p2")

        let supply = await RadioFreshener.candidates(
            seed: "seed",
            body: Fixtures.tracks(["x", "y"]),
            recentlyShown: [],
            needed: 3,
            continuation: "p1",
            rotation: 1,
            source: source
        )

        XCTAssertEqual(ids(supply.tracks), ["c", "d", "e"])
        XCTAssertEqual(supply.continuation, "p2", "The paging position has to be handed back")
        XCTAssertEqual(source.requested, ["continuation:p1"], "Page one was not worth a request here")
    }

    func testFreshenerFallsBackToTheSeedThenToNeighbours() async {
        let source = FakeRadioSource()
        // The stored token is spent: it answers with songs the station already has.
        source.continuations["stale"] = RadioPage(tracks: Fixtures.tracks(["x"]), continuation: "deeper")
        source.pages["seed"] = RadioPage(tracks: Fixtures.tracks(["a"]), continuation: nil)
        source.pages["x"] = RadioPage(tracks: Fixtures.tracks(["b", "c"]), continuation: "elsewhere")

        let supply = await RadioFreshener.candidates(
            seed: "seed",
            body: Fixtures.tracks(["x", "y"]),
            recentlyShown: ["x"],
            needed: 3,
            continuation: "stale",
            rotation: 0,
            source: source
        )

        XCTAssertEqual(ids(supply.tracks), ["a", "b", "c"])
        XCTAssertEqual(source.requested, ["continuation:stale", "page:seed", "page:x"])
        XCTAssertNil(
            supply.continuation,
            "A neighbour's token belongs to a different station and must not be adopted"
        )
    }

    func testFreshenerNeverOffersSomethingTheStationShowedRecently() async {
        let source = FakeRadioSource()
        source.continuations["p1"] = RadioPage(
            tracks: Fixtures.tracks(["retired", "onscreen", "genuinely-new"]),
            continuation: nil
        )

        let supply = await RadioFreshener.candidates(
            seed: "seed",
            body: Fixtures.tracks(["onscreen"]),
            recentlyShown: ["retired", "onscreen"],
            needed: 5,
            continuation: "p1",
            rotation: 0,
            source: source
        )

        XCTAssertEqual(ids(supply.tracks), ["genuinely-new"])
    }

    /// Measured against the live endpoint, a seed runs out of genuinely new suggestions
    /// around the fifth refresh in one sitting. Without a way back to what it played long
    /// ago, Refresh would answer "nothing new" from that point on forever.
    func testAnExhaustedStationReachesForItsOlderMaterialLast() async {
        let source = FakeRadioSource()
        source.continuations["p1"] = RadioPage(
            tracks: Fixtures.tracks(["long-ago-a", "brand-new", "long-ago-b"]),
            continuation: nil
        )

        let supply = await RadioFreshener.candidates(
            seed: "seed",
            body: [],
            recentlyShown: [],
            recyclable: ["long-ago-a", "long-ago-b"],
            needed: 3,
            continuation: "p1",
            rotation: 0,
            source: source
        )

        XCTAssertEqual(
            ids(supply.tracks),
            ["brand-new", "long-ago-a", "long-ago-b"],
            "Genuinely new songs come first; the old ones are filler, not competition"
        )
    }

    /// Recycled songs ride along; they do not satisfy the quota, and a page that produced
    /// nothing else ends that seam — paging deeper into material the station has already
    /// worked through spends the request budget on more of the same.
    func testAPageOfNothingButOldMaterialEndsThatSeamAndMovesOn() async {
        let source = FakeRadioSource()
        source.continuations["p1"] = RadioPage(tracks: Fixtures.tracks(["old-a", "old-b"]), continuation: "p2")
        source.pages["seed"] = RadioPage(tracks: Fixtures.tracks(["new-a"]), continuation: nil)

        let supply = await RadioFreshener.candidates(
            seed: "seed",
            body: [],
            recentlyShown: [],
            recyclable: ["old-a", "old-b"],
            needed: 1,
            continuation: "p1",
            rotation: 0,
            source: source
        )

        XCTAssertEqual(source.requested, ["continuation:p1", "page:seed"])
        XCTAssertEqual(ids(supply.tracks), ["new-a", "old-a", "old-b"])
    }

    func testFreshenerStopsAtTheRequestCeilingRatherThanPagingForever() async {
        let source = FakeRadioSource()
        source.everyContinuationYieldsOneNewTrack = true

        let supply = await RadioFreshener.candidates(
            seed: "seed",
            body: [],
            recentlyShown: [],
            needed: 100,
            continuation: "p1",
            rotation: 0,
            source: source
        )

        XCTAssertEqual(source.requested.count, RadioFreshener.maximumRequests)
        XCTAssertEqual(supply.tracks.count, RadioFreshener.maximumRequests)
    }

    func testFreshenerSurvivesASourceThatThrows() async {
        let source = FakeRadioSource()
        source.throwingTokens = ["p1"]
        source.pages["seed"] = RadioPage(tracks: Fixtures.tracks(["a"]), continuation: nil)

        let supply = await RadioFreshener.candidates(
            seed: "seed",
            body: [],
            recentlyShown: [],
            needed: 5,
            continuation: "p1",
            rotation: 0,
            source: source
        )

        XCTAssertEqual(ids(supply.tracks), ["a"], "A dead token must not take the refresh down with it")
    }

    func testPivotsRotateSoTwoRefreshesInARowDoNotAskTheSameNeighbour() {
        let body = Fixtures.tracks(["a", "b", "c", "d", "e"])
        let first = RadioFreshener.pivotSeeds(from: body, seed: "seed", rotation: 1)
        let second = RadioFreshener.pivotSeeds(from: body, seed: "seed", rotation: 2)

        XCTAssertEqual(first, ["c", "d"])
        XCTAssertEqual(second, ["e", "a"])
        XCTAssertTrue(RadioFreshener.pivotSeeds(from: [], seed: "seed", rotation: 3).isEmpty)
    }

    func testLongCompilationsAreNeverOfferedAsFreshSongs() async {
        let source = FakeRadioSource()
        source.continuations["p1"] = RadioPage(
            tracks: [
                Fixtures.track("mix", durationSeconds: 3 * 3600),
                Fixtures.track("song"),
            ],
            continuation: nil
        )

        let supply = await RadioFreshener.candidates(
            seed: "seed",
            body: [],
            recentlyShown: [],
            needed: 2,
            continuation: "p1",
            rotation: 0,
            source: source
        )

        XCTAssertEqual(ids(supply.tracks), ["song"], "An hour-long compilation hijacks the queue")
    }
}

/// The bookkeeping the guarantee rests on, through the real store.
///
/// Uses a unique station id per run: `RadioCacheStore.shared` writes to the simulator's own
/// defaults, and a fixed id would make these pass or fail on what an earlier run left behind.
@MainActor
final class RadioStationHistoryTests: XCTestCase {

    private func uniqueSeed() -> String { "seed-\(UUID().uuidString.prefix(8))" }

    func testASongIsOffLimitsForThreeRefreshesAndOfferableOnTheFourth() {
        let store = RadioCacheStore.shared
        let seed = uniqueSeed()
        let dropped = Fixtures.track("dropped")
        store.store([Fixtures.track(seed), dropped], for: seed)

        // Refresh once without it: from here on it is a song the station used to show.
        store.applyRefresh(
            [Fixtures.track(seed), Fixtures.track("kept")],
            generations: ["kept": 1],
            generation: 1,
            continuation: nil,
            for: seed
        )

        for generation in 2...3 {
            let state = store.refreshState(for: seed)
            XCTAssertEqual(state.generation, generation)
            XCTAssertTrue(
                state.recentlyShown.contains("dropped"),
                "A song dropped at refresh 1 must not come back at refresh \(generation)"
            )
            store.applyRefresh(
                [Fixtures.track(seed), Fixtures.track("g\(generation)")],
                generations: ["g\(generation)": generation],
                generation: generation,
                continuation: nil,
                for: seed
            )
        }

        let state = store.refreshState(for: seed)
        XCTAssertEqual(state.generation, 4)
        XCTAssertTrue(state.recyclable.contains("dropped"), "Past the promise, old material is fair game again")
        XCTAssertFalse(state.recentlyShown.contains("dropped"))
    }

    func testASongStillOnScreenNeverBecomesOfferableAgain() {
        let store = RadioCacheStore.shared
        let seed = uniqueSeed()
        let survivor = Fixtures.track("survivor")
        store.store([Fixtures.track(seed), survivor], for: seed)

        for generation in 1...5 {
            store.applyRefresh(
                [Fixtures.track(seed), survivor],
                generations: ["survivor": 0],
                generation: generation,
                continuation: nil,
                for: seed
            )
        }

        let state = store.refreshState(for: seed)
        XCTAssertTrue(state.recentlyShown.contains("survivor"))
        XCTAssertFalse(
            state.recyclable.contains("survivor"),
            "Offering back a song that is on the screen would be a refresh that changed nothing"
        )
    }

    func testAFirstLoadStartsTheHistoryOverRatherThanInheritingIt() {
        let store = RadioCacheStore.shared
        let seed = uniqueSeed()
        store.store([Fixtures.track(seed), Fixtures.track("first")], for: seed, continuation: "token")
        store.applyRefresh(
            [Fixtures.track(seed), Fixtures.track("second")],
            generations: ["second": 1],
            generation: 1,
            continuation: "deeper",
            for: seed
        )

        store.store([Fixtures.track(seed), Fixtures.track("rebuilt")], for: seed)

        let state = store.refreshState(for: seed)
        XCTAssertEqual(state.generation, 1, "A rebuilt station has not been refreshed")
        XCTAssertNil(state.continuation)
        XCTAssertTrue(state.generations.isEmpty)
        XCTAssertFalse(state.recentlyShown.contains("second"), "The previous station's history is not this one's")
    }
}

/// Stands in for YouTube. Records what was asked for, in order, because *which seam a refresh
/// spends its requests on* is half of what is being tested.
private final class FakeRadioSource: RadioSource, @unchecked Sendable {
    var pages: [String: RadioPage] = [:]
    var continuations: [String: RadioPage] = [:]
    var throwingTokens: Set<String> = []
    /// An endless station, for the request-ceiling test.
    var everyContinuationYieldsOneNewTrack = false

    private let lock = NSLock()
    private var log: [String] = []
    private var served = 0

    var requested: [String] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    struct Missing: Error {}

    func page(seed: String, limit: Int) async throws -> RadioPage {
        lock.lock()
        log.append("page:\(seed)")
        let page = pages[seed]
        lock.unlock()
        guard let page else { throw Missing() }
        return page
    }

    func continuationPage(_ token: String) async throws -> RadioPage {
        lock.lock()
        log.append("continuation:\(token)")
        let endless = everyContinuationYieldsOneNewTrack
        served += 1
        let index = served
        let page = continuations[token]
        let throwing = throwingTokens.contains(token)
        lock.unlock()
        if throwing { throw Missing() }
        if endless {
            return RadioPage(tracks: [Fixtures.track("endless\(index)")], continuation: "p\(index + 1)")
        }
        guard let page else { throw Missing() }
        return page
    }
}
