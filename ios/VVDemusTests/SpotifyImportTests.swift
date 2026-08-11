import Combine
import XCTest
@testable import VVDemus

/// The Spotify import orchestrator: link in, playlist out. Everything here runs against
/// injected `fetchPage` / `search` closures and a recording store, so the whole feature —
/// including the parts that only misbehave when a search is slow, throttled or cancelled
/// halfway — is reachable without a network, a Spotify playlist, or a real library to
/// pollute.
@MainActor
final class SpotifyImportTests: XCTestCase {

    // MARK: - Doubles

    /// Stands in for `PlaylistStore.shared`, which cannot be isolated: it is a singleton
    /// over `UserDefaults.standard` and its `save()` schedules a sync push to any paired
    /// device. This double records the same two calls and, crucially, reproduces the real
    /// store's no-op on a videoId it already holds.
    @MainActor
    private final class RecordingStore: PlaylistWriting {
        private(set) var created: [String] = []
        private(set) var addedVideoIds: [String] = []

        @discardableResult
        func create(name: String) -> Playlist {
            created.append(name)
            return Playlist(name: name)
        }

        func addTrack(_ track: Track, to playlist: Playlist) {
            guard !addedVideoIds.contains(track.videoId) else { return }
            addedVideoIds.append(track.videoId)
        }
    }

    /// A search that answers instantly for most rows but can be told to dawdle on specific
    /// ones, which is how the out-of-order test is made deterministic instead of hopeful.
    /// Main-actor isolated on purpose: the importer calls it from three concurrent child
    /// tasks, and a plain class recording `completionOrder` from all three is a data race
    /// that shows up as a flaky test rather than as a crash. `Task.sleep` suspends the actor
    /// rather than blocking it, so the concurrency being measured is still real.
    @MainActor
    private final class ScriptedSearch {
        /// index -> how long that row's search takes.
        var delays: [Int: Duration] = [:]
        /// index -> what comes back instead of the obvious match.
        var candidates: [Int: [Track]] = [:]
        /// index -> an error to throw rather than answering.
        var errors: [Int: Error] = [:]
        /// The order rows actually finished in. Asserted on, so a test that thinks it
        /// forced out-of-order completion can prove it.
        private(set) var completionOrder: [Int] = []
        private(set) var queries: [String] = []

        func run(_ query: String) async throws -> [Track] {
            queries.append(query)
            let index = Self.index(in: query)
            if let delay = delays[index] { try? await Task.sleep(for: delay) }
            completionOrder.append(index)
            if let error = errors[index] { throw error }
            return candidates[index] ?? [Fixtures.spotifyMatch(index)]
        }

        /// Rows are titled `Song 7`, so the query carries its own index back.
        private static func index(in query: String) -> Int {
            let digits = query.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
            return Int(digits) ?? -1
        }
    }

    /// A fetch that hangs on its first call and answers instantly afterwards, which is the shape
    /// of the window Cancel opens: the abandoned request is still out there against a 15-second
    /// timeout and a three-attempt retry ladder while the user is already retyping the link.
    @MainActor
    private final class GatedFetch {
        private(set) var calls = 0
        /// Set by the test to let the abandoned first call finally return.
        var isReleased = false
        private let page: SpotifyPlaylistPage

        init(_ page: SpotifyPlaylistPage) { self.page = page }

        func run() async -> SpotifyPlaylistPage {
            calls += 1
            if calls == 1 {
                while !isReleased { try? await Task.sleep(for: .milliseconds(5)) }
            }
            return page
        }
    }

    // MARK: - Fixtures

    private func spotifyTracks(_ count: Int) -> [SpotifyTrack] {
        (0..<count).map {
            SpotifyTrack(title: "Song \($0)", artist: "Artist \($0)", durationMs: 180_000)
        }
    }

    private func page(_ count: Int, name: String = "Road Trip") -> SpotifyPlaylistPage {
        SpotifyPlaylistPage(name: name, tracks: spotifyTracks(count))
    }

    private func makeImporter(
        page: SpotifyPlaylistPage,
        search: ScriptedSearch,
        store: RecordingStore
    ) -> SpotifyImporter {
        SpotifyImporter(
            fetchPage: { _ in page },
            search: { [search] query in try await search.run(query) },
            store: store
        )
    }

    private var link: String { "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M" }

    /// Runs the main run loop until `condition` holds, mirroring `PlayerHarness.settle`.
    /// The importer publishes from a task group, so nothing is synchronous with `run`.
    private func settle(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            await Task.yield()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertTrue(condition(), "Timed out waiting for condition", file: file, line: line)
    }

    private struct RunDidNotFinish: Error { let phase: SpotifyImporter.Phase }

    private func finishedSummary(
        of importer: SpotifyImporter,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ImportSummary {
        guard case .finished(let summary) = importer.phase else {
            XCTFail("Expected a finished run, got \(importer.phase)", file: file, line: line)
            throw RunDidNotFinish(phase: importer.phase)
        }
        return summary
    }

    // MARK: - The bug this file exists for

    /// Searches run three at a time, so they finish in whatever order YouTube answers in.
    /// Collecting them into an array as they land — the obvious `results.append` inside
    /// `for await` — writes the playlist in response-time order, which passes every test
    /// that only counts songs and is only noticed when someone plays the album back
    /// shuffled. The delays below make row 0 finish last on purpose.
    func testTheImportedPlaylistIsInSpotifyOrderEvenWhenSearchesFinishOutOfOrder() async throws {
        let search = ScriptedSearch()
        search.delays = [0: .milliseconds(200), 1: .milliseconds(120), 2: .milliseconds(10)]
        let store = RecordingStore()
        let importer = makeImporter(page: page(5), search: search, store: store)

        await importer.run(link: link, name: nil)

        XCTAssertNotEqual(
            search.completionOrder, Array(0..<5),
            "The test proves nothing unless the searches really did finish out of order"
        )
        XCTAssertEqual(
            store.addedVideoIds, (0..<5).map { "yt\($0)" },
            "The playlist must be written in Spotify's order, not in the order searches came back"
        )
    }

    // MARK: - Progress

    /// `completed` overshooting `total`, or stalling one short of it, is what turns a
    /// determinate bar into a bar that sits at 96% forever. Every published value is
    /// checked, not just the last one.
    func testProgressIsMonotonicAndEndsAtTheTotal() async throws {
        let search = ScriptedSearch()
        let store = RecordingStore()
        let importer = makeImporter(page: page(7), search: search, store: store)

        var seen: [(completed: Int, total: Int, current: String)] = []
        let subscription = importer.$phase.sink { phase in
            if case .matching(let completed, let total, let current) = phase {
                seen.append((completed, total, current))
            }
        }
        defer { subscription.cancel() }

        await importer.run(link: link, name: nil)

        XCTAssertTrue(seen.allSatisfy { $0.total == 7 }, "The total must not move mid-run")
        // The shape of the sequence, not merely its envelope. Monotonic-and-ends-at-the-total is
        // satisfied by two publishes — 0/7 and then 7/7 — which is a bar frozen at zero for the
        // whole run followed by a jump to done, the louder of the two failures this guards. A
        // determinate bar needs a tick per search, and there is exactly one search per row.
        XCTAssertEqual(
            seen.map(\.completed), Array(0...7),
            "Every search must move the counter: \(seen.map(\.completed))"
        )
        XCTAssertTrue(
            seen.allSatisfy { !$0.current.isEmpty },
            "Every progress update names the song being matched; an empty label reads as a hang"
        )
    }

    /// The label names the lowest row still in flight, deliberately, so it describes work that
    /// is happening rather than work that has just stopped. Naming the row that last *finished*
    /// passes every envelope assertion above and is invisible without staggered timings: here
    /// row 0 is still being searched for the whole run, so an honest label never says anything
    /// else — while a last-finished label would announce "Song 2" ten milliseconds in.
    func testTheProgressLabelNamesASongStillBeingSearchedNotTheLastToFinish() async throws {
        let search = ScriptedSearch()
        search.delays = [0: .milliseconds(400), 1: .milliseconds(120), 2: .milliseconds(10)]
        let importer = makeImporter(page: page(7), search: search, store: RecordingStore())

        var seen: [String] = []
        let subscription = importer.$phase.sink { phase in
            if case .matching(_, _, let current) = phase { seen.append(current) }
        }
        defer { subscription.cancel() }

        await importer.run(link: link, name: nil)

        XCTAssertEqual(search.completionOrder.last, 0, "Guards the timings, not the importer")
        XCTAssertEqual(
            Set(seen), ["Song 0"],
            "While row 0 is outstanding every tick has to name it: \(seen)"
        )
    }

    // MARK: - Misses

    /// A song nothing acceptable came back for is reported by name, never silently dropped
    /// and never replaced by whatever the search happened to return first — the whole point
    /// of the miss list is that the user can go and add those five by hand.
    func testASongWithNoAcceptableMatchIsReportedAsAMissRatherThanGuessedAt() async throws {
        let search = ScriptedSearch()
        search.candidates = [1: [], 3: []]
        let store = RecordingStore()
        let importer = makeImporter(page: page(5), search: search, store: store)

        await importer.run(link: link, name: nil)
        let summary = try finishedSummary(of: importer)

        XCTAssertEqual(
            summary.misses.map(\.title), ["Song 1", "Song 3"],
            "The misses must be the rows that failed to match, listed in Spotify's order"
        )
        XCTAssertEqual(summary.added, 3)
        XCTAssertTrue(summary.didCreatePlaylist, "Three songs went in, so there is a playlist")
        XCTAssertEqual(summary.requested, 5, "requested counts what Spotify gave us, not what matched")
        XCTAssertEqual(store.addedVideoIds, ["yt0", "yt2", "yt4"], "A miss must not shift the others")
    }

    /// One search failing on its own — a 500, a dropped connection — used to be a reason to
    /// abort. Ninety songs thrown away because the ninety-first request was unlucky.
    func testASingleFailedSearchIsAMissAndNotAnAbortedImport() async throws {
        let search = ScriptedSearch()
        search.errors = [2: APIError.http(status: 500)]
        let store = RecordingStore()
        let importer = makeImporter(page: page(4), search: search, store: store)

        await importer.run(link: link, name: nil)
        let summary = try finishedSummary(of: importer)

        XCTAssertFalse(summary.stoppedEarly, "A plain server error is not a reason to stop the run")
        XCTAssertEqual(summary.misses.map(\.title), ["Song 2"])
        XCTAssertEqual(store.addedVideoIds, ["yt0", "yt1", "yt3"])
    }

    // MARK: - Truncation

    /// The embed hands back at most 100 rows and no count of the rest, so a 100-row answer
    /// is indistinguishable from a 250-song playlist. The flag has to survive the whole run
    /// and land in the summary, or the user is told their 250-song playlist imported fine.
    func testTheTruncationWarningReachesTheSummary() async throws {
        let search = ScriptedSearch()
        let store = RecordingStore()
        let full = page(SpotifyImportClient.embedTrackLimit)
        XCTAssertTrue(full.isPossiblyTruncated, "Guards the fixture, not the importer")
        let importer = makeImporter(page: full, search: search, store: store)

        await importer.run(link: link, name: nil)

        XCTAssertTrue(try finishedSummary(of: importer).truncated, "The 100-row warning was dropped on the way out")
    }

    func testAShortPlaylistIsNotReportedAsTruncated() async throws {
        let importer = makeImporter(page: page(3), search: ScriptedSearch(), store: RecordingStore())
        await importer.run(link: link, name: nil)
        XCTAssertFalse(try finishedSummary(of: importer).truncated)
    }

    // MARK: - Failures before any matching

    func testAnUnparseableLinkFailsWithTheLinkMessageAndNeverFetches() async throws {
        var fetched = false
        let store = RecordingStore()
        let fixture = page(2)
        let importer = SpotifyImporter(
            fetchPage: { _ in fetched = true; return fixture },
            search: { _ in [] },
            store: store
        )

        await importer.run(link: "https://open.spotify.com/album/4aawyAB9vmqN3uQ7FjRGTy", name: nil)

        XCTAssertEqual(
            importer.phase, .failed(SpotifyImportError.notAPlaylistLink.errorDescription ?? ""),
            "An album link has to say it is not a playlist, not 'couldn't reach Spotify'"
        )
        XCTAssertFalse(fetched, "A link we already know is wrong must not cost a request")
        XCTAssertTrue(store.created.isEmpty)
    }

    /// A private or deleted playlist is the most common failure this feature will ever hit,
    /// and "unreadable" or a raw `URLError` description in the sheet tells the user nothing
    /// they can act on.
    func testAFetchFailureSurfacesTheClientsOwnMessage() async throws {
        let store = RecordingStore()
        let importer = SpotifyImporter(
            fetchPage: { _ in throw SpotifyImportError.notAvailable },
            search: { _ in [] },
            store: store
        )

        await importer.run(link: link, name: nil)

        XCTAssertEqual(importer.phase, .failed(SpotifyImportError.notAvailable.errorDescription ?? ""))
        XCTAssertTrue(store.created.isEmpty, "A failed fetch must not leave an empty playlist behind")
    }

    /// The sheet keeps the form up under a failure on purpose, so the user edits the link in
    /// place — and the message is about the link that is no longer in the field the moment they
    /// do. It used to stay put: "Spotify won't share that playlist" sat above a corrected link
    /// and an enabled Import button, and next to a second orange line about the half-typed
    /// replacement while it was still unparseable.
    func testEditingTheLinkTakesAStaleFailureMessageDown() async throws {
        let importer = SpotifyImporter(
            fetchPage: { _ in throw SpotifyImportError.notAvailable },
            search: { _ in [] },
            store: RecordingStore()
        )

        await importer.run(link: link, name: nil)
        XCTAssertEqual(importer.phase, .failed(SpotifyImportError.notAvailable.errorDescription ?? ""))

        importer.clearFailure()

        XCTAssertEqual(importer.phase, .idle, "The message outlived the link it described")
    }

    /// Only a failure is cleared. The same keystroke handler must not be able to wipe the
    /// summary the user is reading, which is the whole reason this is not `phase = .idle`.
    func testClearingAFailureLeavesAFinishedSummaryAlone() async throws {
        let importer = makeImporter(page: page(2), search: ScriptedSearch(), store: RecordingStore())
        await importer.run(link: link, name: nil)

        importer.clearFailure()

        XCTAssertEqual(try finishedSummary(of: importer).added, 2)
    }

    // MARK: - Rate limiting

    /// The gate is process-wide. Pushing the remaining eighty searches through it after the
    /// first 429 only deepens the cool-down and takes Search and Home down with the import.
    /// What matched before the throttle is still worth keeping, so the run finishes rather
    /// than failing.
    func testARateLimitStopsTheRunEarlyButKeepsWhatAlreadyMatched() async throws {
        let search = ScriptedSearch()
        // Rows 0 and 1 dawdle so they are still in flight when row 2 is throttled; they are
        // already past the gate, so they are allowed to land.
        search.delays = [0: .milliseconds(80), 1: .milliseconds(80)]
        search.errors = [2: APIError.rateLimited(retryAfter: 30)]
        let store = RecordingStore()
        let importer = makeImporter(page: page(9), search: search, store: store)

        await importer.run(link: link, name: nil)
        let summary = try finishedSummary(of: importer)

        XCTAssertTrue(summary.stoppedEarly, "The sheet has to say the run was cut short")
        XCTAssertEqual(store.addedVideoIds, ["yt0", "yt1"], "The matches from before the 429 are kept")
        XCTAssertEqual(summary.added, 2)
        XCTAssertEqual(summary.requested, 9)
        XCTAssertTrue(
            summary.misses.isEmpty,
            "A throttled row is not a miss — nothing says it would not have matched"
        )
        XCTAssertLessThanOrEqual(
            search.completionOrder.count, SpotifyImporter.concurrentSearches,
            "No new searches may be launched after a 429: \(search.completionOrder)"
        )
    }

    // MARK: - Cancel

    /// The playlist is created only once the run is over precisely so that Cancel is free.
    /// Creating it up front and filling it in was the first design, and cancelling left a
    /// half-imported playlist in the library that looked like a successful import.
    func testCancellingMidRunLeavesNothingInTheLibrary() async throws {
        let search = ScriptedSearch()
        for index in 0..<6 { search.delays[index] = .milliseconds(60) }
        let store = RecordingStore()
        let importer = makeImporter(page: page(6), search: search, store: store)

        let run = Task { await importer.run(link: link, name: nil) }
        await settle { if case .matching = importer.phase { return true }; return false }
        importer.cancel()
        _ = await run.value

        XCTAssertEqual(importer.phase, .idle, "Cancel must not leave the sheet stuck showing progress")
        XCTAssertTrue(store.created.isEmpty, "Cancel left a playlist behind")
        XCTAssertTrue(store.addedVideoIds.isEmpty)
    }

    func testCancellingBeforeAnythingStartsIsHarmless() async throws {
        let importer = makeImporter(page: page(2), search: ScriptedSearch(), store: RecordingStore())
        importer.cancel()
        XCTAssertEqual(importer.phase, .idle)

        // And the importer is still usable afterwards — a cancelled run must not poison the
        // next one, which is what a sticky cancellation flag would do.
        await importer.run(link: link, name: nil)
        XCTAssertEqual(try finishedSummary(of: importer).added, 2)
    }

    /// Cancel puts the sheet back to the link form with a live Import button, so the next thing
    /// the user does is fix the link they mis-pasted and tap it again — while the abandoned run
    /// is still unwinding. That used to be swallowed whole: the run slot was a flag cleared by a
    /// `defer`, so the second tap hit the re-entrancy guard and returned with no fetch, no
    /// phase change and no message, for as long as the abandoned fetch took to run out its
    /// retries. The only recovery was closing the sheet, and nothing on screen said so.
    func testImportWorksAgainImmediatelyAfterCancelEvenWhileTheAbandonedRunUnwinds() async throws {
        let fetch = GatedFetch(page(2))
        let search = ScriptedSearch()
        let store = RecordingStore()
        let importer = SpotifyImporter(
            fetchPage: { _ in await fetch.run() },
            search: { [search] query in try await search.run(query) },
            store: store
        )

        let abandoned = Task { await importer.run(link: link, name: nil) }
        await settle { importer.phase == .fetching }
        importer.cancel()
        XCTAssertEqual(importer.phase, .idle, "Cancel must not leave the sheet stuck showing progress")

        await importer.run(link: link, name: "Second Try")

        XCTAssertEqual(fetch.calls, 2, "The retry never left the ground — this is the dead button")
        XCTAssertEqual(store.created, ["Second Try"])
        XCTAssertEqual(try finishedSummary(of: importer).added, 2)

        // And the run the user walked away from stays walked away from, however late it lands.
        fetch.isReleased = true
        _ = await abandoned.value
        XCTAssertEqual(store.created, ["Second Try"], "The cancelled run wrote a second playlist")
        XCTAssertEqual(try finishedSummary(of: importer).playlistName, "Second Try",
                       "A cancelled run must not overwrite the summary of the one that replaced it")
    }

    /// A finished summary is what the sheet is showing when the user reaches for the button
    /// that dismisses it; wiping it here blanked the sheet for the instant before dismissal.
    func testCancellingAfterTheRunKeepsTheSummaryOnScreen() async throws {
        let importer = makeImporter(page: page(2), search: ScriptedSearch(), store: RecordingStore())
        await importer.run(link: link, name: nil)

        importer.cancel()

        XCTAssertEqual(try finishedSummary(of: importer).added, 2)
    }

    // MARK: - Naming and re-entrancy

    func testAnEmptyNameFallsBackToTheSpotifyPlaylistName() async throws {
        let store = RecordingStore()
        let importer = makeImporter(page: page(2, name: "Deep Focus"), search: ScriptedSearch(), store: store)

        await importer.run(link: link, name: "   ")

        XCTAssertEqual(store.created, ["Deep Focus"])
        XCTAssertEqual(try finishedSummary(of: importer).playlistName, "Deep Focus")
    }

    func testATypedNameWinsOverSpotifys() async throws {
        let store = RecordingStore()
        let importer = makeImporter(page: page(2, name: "Deep Focus"), search: ScriptedSearch(), store: store)

        await importer.run(link: link, name: "Studying")

        XCTAssertEqual(store.created, ["Studying"])
    }

    /// Two runs racing would interleave their progress on one `phase` and create two
    /// playlists from one tap.
    func testASecondRunWhileOneIsInFlightIsIgnored() async throws {
        let search = ScriptedSearch()
        for index in 0..<4 { search.delays[index] = .milliseconds(50) }
        let store = RecordingStore()
        let importer = makeImporter(page: page(4), search: search, store: store)

        let first = Task { await importer.run(link: link, name: nil) }
        await settle { if case .matching = importer.phase { return true }; return false }
        await importer.run(link: link, name: nil)
        _ = await first.value

        XCTAssertEqual(store.created.count, 1, "One tap, one playlist — the second run must be dropped")
        XCTAssertEqual(store.addedVideoIds, ["yt0", "yt1", "yt2", "yt3"])
    }

    /// Two Spotify rows can match the same YouTube video — a single released twice, an album
    /// and its deluxe edition in the same playlist. `PlaylistStore.addTrack` silently ignores
    /// a videoId it already holds, so counting successful matches reported four songs added
    /// to a playlist that contained three.
    func testDuplicateMatchesAreCountedOnceBecauseTheStoreOnlyKeepsOne() async throws {
        let search = ScriptedSearch()
        search.candidates = [2: [Fixtures.spotifyMatch(0, title: "Song 2", artist: "Artist 2")]]
        let store = RecordingStore()
        let importer = makeImporter(page: page(4), search: search, store: store)

        await importer.run(link: link, name: nil)

        XCTAssertEqual(store.addedVideoIds, ["yt0", "yt1", "yt3"])
        XCTAssertEqual(
            try finishedSummary(of: importer).added, 3,
            "added must be what the playlist really gained, not how many searches succeeded"
        )
    }

    /// Nothing matched, so there is nothing to put in a playlist. An empty one named after
    /// the Spotify playlist is litter the user then has to go and delete; the summary
    /// already tells them what happened.
    func testAnImportThatMatchesNothingCreatesNoPlaylist() async throws {
        let search = ScriptedSearch()
        for index in 0..<3 { search.candidates[index] = [] }
        let store = RecordingStore()
        let importer = makeImporter(page: page(3), search: search, store: store)

        await importer.run(link: link, name: nil)
        let summary = try finishedSummary(of: importer)

        XCTAssertTrue(store.created.isEmpty)
        XCTAssertEqual(summary.misses.count, 3)
        // The sheet's headline hangs off this. It used to lead with a green checkmark and
        // `Imported "Road Trip"` over "Added 0 of 3 songs", so the strongest thing on screen
        // named a playlist that had never been created and the user went looking for it.
        XCTAssertFalse(summary.didCreatePlaylist,
                       "A finished run is not a successful one when nothing was written")
        XCTAssertEqual(summary.playlistName, "Road Trip",
                       "The name is still carried — it is the claim of success that has to go")
    }

    /// The same screen from the other empty direction: a playlist with nothing in it, and a run
    /// whose very first search is throttled. Both reach `.finished` with `added == 0` and no
    /// misses to explain it, so the headline is the only thing that can tell the truth.
    func testAnEmptyPlaylistAndAnImmediateThrottleBothReportNothingImported() async throws {
        let store = RecordingStore()
        let empty = makeImporter(page: page(0), search: ScriptedSearch(), store: store)
        await empty.run(link: link, name: nil)
        let emptySummary = try finishedSummary(of: empty)

        XCTAssertFalse(emptySummary.didCreatePlaylist)
        XCTAssertEqual(emptySummary.requested, 0)
        XCTAssertTrue(store.created.isEmpty)

        let throttledSearch = ScriptedSearch()
        for index in 0..<3 { throttledSearch.errors[index] = APIError.rateLimited(retryAfter: 30) }
        let throttledStore = RecordingStore()
        let throttled = makeImporter(page: page(3), search: throttledSearch, store: throttledStore)
        await throttled.run(link: link, name: nil)
        let throttledSummary = try finishedSummary(of: throttled)

        XCTAssertTrue(throttledSummary.stoppedEarly)
        XCTAssertFalse(throttledSummary.didCreatePlaylist,
                       "Nothing was written, so nothing may be announced as imported")
        XCTAssertTrue(throttledStore.created.isEmpty)
    }

    // MARK: - Query building

    /// Spotify comma-joins every credited artist. Pasting all of them into one query pushes
    /// the real song off the first page in favour of remix compilations that name the same
    /// people, so only the primary artist goes into the search.
    func testTheSearchQueryCarriesTheTitleAndOnlyThePrimaryArtist() {
        let track = SpotifyTrack(title: "Sunflower", artist: "Post Malone, Swae Lee", durationMs: 158_000)
        XCTAssertEqual(SpotifyImporter.searchQuery(for: track), "Sunflower Post Malone")
    }

    /// And the run really routes through it. `ScriptedSearch` recovers a row's index from the
    /// digits in the query, so every other assertion in this file answers identically whether
    /// the importer searched "Song 3 Artist 3" or bare "Song 3" — the queries themselves were
    /// recorded and never read. Dropping the artist from the query ships green and then fills
    /// the first page of real results with covers, karaoke and the wrong artist entirely, which
    /// `TrackMatcher` correctly refuses: a 50-song playlist comes back as 40 misses.
    func testTheRunSearchesByTitleAndPrimaryArtistAndNotByTitleAlone() async throws {
        let search = ScriptedSearch()
        let store = RecordingStore()
        let tracks = [
            SpotifyTrack(title: "Song 0", artist: "Artist 0, Someone Else", durationMs: 180_000),
            SpotifyTrack(title: "Song 1", artist: "Artist 1", durationMs: 180_000),
        ]
        let importer = makeImporter(page: SpotifyPlaylistPage(name: "Road Trip", tracks: tracks),
                                    search: search, store: store)

        await importer.run(link: link, name: nil)

        XCTAssertEqual(
            search.queries.sorted(), ["Song 0 Artist 0", "Song 1 Artist 1"],
            "The artist has to reach YouTube Music, and only the primary one"
        )
        XCTAssertEqual(store.addedVideoIds, ["yt0", "yt1"])
    }
}

private extension Fixtures {
    /// The YouTube result the scripted search returns for row `index`: same title, same
    /// artist, same duration, so `TrackMatcher` has no reason to reject it and these tests
    /// stay about ordering and bookkeeping rather than about scoring.
    static func spotifyMatch(_ index: Int, title: String? = nil, artist: String? = nil) -> Track {
        Fixtures.track(
            "yt\(index)",
            title: title ?? "Song \(index)",
            artist: artist ?? "Artist \(index)",
            durationSeconds: 180
        )
    }
}
