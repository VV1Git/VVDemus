import XCTest
@testable import VVDemus

/// The lyrics cache, which is the only store here that remembers *failures* as well as
/// successes — and the only one where remembering a failure too well is the bug.
///
/// Every test builds its own store against a throwaway `UserDefaults` suite and a fake
/// clock. `LyricsCacheStore.shared` is never touched: it writes to the simulator's real
/// defaults, which is how a previous round of tests left the app's own Home feed full of
/// fixture tracks (see `TasteProfileTests`).
@MainActor
final class LyricsCacheStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults = UserDefaults.standard
    /// Fixed, so "a week later" is a subtraction rather than a wait.
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        suiteName = "vvdemus.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore(limit: Int = 200) -> LyricsCacheStore {
        LyricsCacheStore(defaults: defaults, limit: limit, now: { [unowned self] in self.clock })
    }

    private let synced = Lyrics(
        body: .synced([
            LyricsLine(at: 0, text: "first line"),
            LyricsLine(at: 12.5, text: "second line"),
        ]),
        attribution: "LRCLIB",
        matchedDuration: 214
    )

    private let plain = Lyrics(
        body: .plain(["first line", "", "after an instrumental gap"]),
        attribution: "YouTube Music",
        matchedDuration: nil
    )

    // MARK: - Round trip

    func testSyncedLyricsSurviveARelaunch() {
        makeStore().store(synced, for: "abc")

        // A second store reading the same defaults is what the next launch does.
        XCTAssertEqual(makeStore().lyrics(for: "abc"), synced)
    }

    func testPlainLyricsSurviveARelaunch() {
        makeStore().store(plain, for: "abc")

        let reloaded = makeStore().lyrics(for: "abc")
        XCTAssertEqual(reloaded, plain)
        // The blank line is a real instrumental gap, not padding to be tidied away.
        if case .plain(let lines) = reloaded?.body {
            XCTAssertEqual(lines.count, 3)
        } else {
            XCTFail("A plain body must not come back as anything else")
        }
    }

    func testAnUnknownTrackHasNoLyricsAndNoMiss() {
        let store = makeStore()
        XCTAssertNil(store.lyrics(for: "never-looked-up"))
        XCTAssertFalse(store.isMissFresh("never-looked-up"))
    }

    // MARK: - Misses

    func testAStoredMissIsFreshImmediately() {
        let store = makeStore()
        store.storeMiss(for: "instrumental")

        XCTAssertTrue(store.isMissFresh("instrumental"), "Otherwise every open pays two requests")
        XCTAssertNil(store.lyrics(for: "instrumental"), "A miss is not lyrics")
    }

    func testAMissSurvivesARelaunchWithinItsTTL() {
        makeStore().storeMiss(for: "instrumental")
        clock += LyricsCacheStore.missTTL / 2

        XCTAssertTrue(makeStore().isMissFresh("instrumental"))
    }

    /// LRCLIB gains entries over time, so a permanent "no lyrics" is a bug that never heals.
    func testAMissExpiresSoonerThanAHitDoes() {
        let store = makeStore()
        store.store(synced, for: "has-lyrics")
        store.storeMiss(for: "instrumental")

        clock += LyricsCacheStore.missTTL + 1

        XCTAssertFalse(store.isMissFresh("instrumental"), "A stale miss must be re-asked")
        XCTAssertEqual(store.lyrics(for: "has-lyrics"), synced,
                       "A hit has no expiry — the words of a recording do not change")
    }

    func testAnExpiredMissIsNotReloadedFromDisk() {
        makeStore().storeMiss(for: "instrumental")
        clock += LyricsCacheStore.missTTL + 1

        XCTAssertFalse(makeStore().isMissFresh("instrumental"))
    }

    func testLyricsArrivingClearTheRecordedMiss() {
        let store = makeStore()
        store.storeMiss(for: "abc")
        store.store(synced, for: "abc")

        XCTAssertFalse(store.isMissFresh("abc"), "A cached miss beside a cached hit would keep "
                       + "the screen asking for words it already has")
        XCTAssertEqual(store.lyrics(for: "abc"), synced)
    }

    /// An empty body is a failed parse, not a song with no words — the trap `AlbumCacheStore`
    /// documents. Cached as a hit it would be served forever; recorded as a miss it retries
    /// once the TTL is up.
    func testAnEmptyBodyIsRecordedAsAMissRatherThanCached() {
        let store = makeStore()
        store.store(Lyrics(body: .plain([]), attribution: nil, matchedDuration: nil), for: "abc")

        XCTAssertNil(store.lyrics(for: "abc"))
        XCTAssertTrue(store.isMissFresh("abc"))
    }

    // MARK: - Trim

    func testTheOldestEntriesAreEvictedAtTheLimit() {
        let store = makeStore(limit: 3)
        for id in ["a", "b", "c"] { store.store(synced, for: id) }
        // Re-storing "a" makes it the most recent, so "b" is now the oldest.
        store.store(synced, for: "a")
        store.store(plain, for: "d")

        XCTAssertNil(store.lyrics(for: "b"))
        XCTAssertEqual(store.lyrics(for: "a"), synced)
        XCTAssertEqual(store.lyrics(for: "c"), synced)
        XCTAssertEqual(store.lyrics(for: "d"), plain)
    }

    func testMissesAreTrimmedWithoutEvictingLyrics() {
        let store = makeStore(limit: 2)
        store.store(synced, for: "keep")
        for id in ["m1", "m2", "m3"] {
            store.storeMiss(for: id)
            clock += 60
        }

        XCTAssertEqual(store.lyrics(for: "keep"), synced,
                       "A run of instrumentals must not push real lyrics off a plane")
        XCTAssertFalse(store.isMissFresh("m1"))
        XCTAssertTrue(store.isMissFresh("m3"))
    }

    // MARK: - Schema

    /// The store on a phone that has synced a newer build's backup, or a user rolling back a
    /// TestFlight. Reading a shape this build does not know must yield an empty cache, which
    /// costs a re-fetch, rather than a crash or a decode of nonsense.
    func testASnapshotFromAFutureVersionDegradesToEmpty() throws {
        // The entry itself is perfectly decodable by this build — encoded by this build. Only
        // the version says otherwise, so nothing but the version guard can make this pass.
        let entry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(synced))
        let future: [String: Any] = [
            "version": LyricsCacheStore.schemaVersion + 1,
            "cache": ["abc": entry],
            "order": ["abc"],
            "misses": [String: Double](),
            "somethingThisBuildHasNeverHeardOf": true,
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: future), forKey: LyricsCacheStore.defaultsKey)

        let store = makeStore()
        XCTAssertNil(store.lyrics(for: "abc"))
        XCTAssertFalse(store.isMissFresh("abc"))

        // And it still works afterwards, rather than being wedged by the blob it could not read.
        store.store(plain, for: "abc")
        XCTAssertEqual(makeStore().lyrics(for: "abc"), plain)
    }

    func testUnreadableBytesDegradeToEmptyRatherThanCrashing() {
        defaults.set(Data("not JSON at all".utf8), forKey: LyricsCacheStore.defaultsKey)

        XCTAssertNil(makeStore().lyrics(for: "abc"))
    }
}
