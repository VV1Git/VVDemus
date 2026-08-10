import XCTest
@testable import VVDemus

// MARK: - Phase and fraction

/// What a download row is allowed to claim, and — more importantly — what it must refuse to
/// claim.
///
/// Every case here stands in for something the old `[String: Double]` could not express.
/// `progress[id] = 0` was written the instant a track was accepted, so "queued behind
/// thirty-eight resolves", "asking InnerTube for a URL right now", "the server never said how
/// big this is" and "downloading, 0% done" were the same number — and a failure was
/// indistinguishable from never having been asked for.
final class DownloadStateTests: XCTestCase {

    func testFractionIsTheReceivedShareOfAKnownSize() {
        XCTAssertEqual(DownloadState.transferring(received: 250, expected: 1_000).fraction, 0.25)
    }

    /// The case the old delegate dropped on the floor: `guard totalBytesExpectedToWrite > 0
    /// else { return }` discarded every update from a server that sent no Content-Length, so
    /// such a transfer read zero for its entire life. nil has to mean "unknown", never "none
    /// arrived" — the bytes are still real and still worth showing.
    func testAnUnsizedTransferHasNoFractionButStillReportsItsBytes() {
        let state = DownloadState.transferring(received: 4_000_000, expected: nil)
        XCTAssertNil(state.fraction)
        XCTAssertEqual(state.receivedBytes, 4_000_000)
    }

    /// `NSURLSessionTransferSizeUnknown` arrives as a non-positive number rather than as an
    /// absence. Dividing by it is either a fake 0% or an infinity, and both render as a stall.
    func testANonPositiveExpectedSizeIsUnknownRatherThanZeroPercent() {
        XCTAssertNil(DownloadState.transferring(received: 10, expected: 0).fraction)
        XCTAssertNil(DownloadState.transferring(received: 10, expected: -1).fraction)
    }

    /// A real zero is still a zero. The distinction the ring draws is between "0% of a known
    /// size" (a stub arc) and "size unknown" (a sweep); flattening either into the other is
    /// exactly the bug.
    func testAKnownSizeWithNothingReceivedIsAGenuineZero() {
        XCTAssertEqual(DownloadState.transferring(received: 0, expected: 1_000).fraction, 0)
    }

    func testFractionIsClampedSoAnOverlongTransferCannotOverfillTheRing() {
        XCTAssertEqual(DownloadState.transferring(received: 1_500, expected: 1_000).fraction, 1)
    }

    func testPhasesWithNoTransferHaveNeitherFractionNorBytes() {
        for state: DownloadState in [.queued, .resolving, .failed(reason: "nope")] {
            XCTAssertNil(state.fraction, "\(state) must not claim a fraction")
            XCTAssertEqual(state.receivedBytes, 0, "\(state) must not claim bytes")
        }
    }

    /// `download(_:)` is the retry path and guards on `isDownloading`, which is `isInFlight`.
    /// A failure that counted as in flight would make the retry silently refuse — which is the
    /// whole reason a failed entry is retained rather than deleted.
    func testOnlyAFailureIsOutOfFlight() {
        XCTAssertTrue(DownloadState.queued.isInFlight)
        XCTAssertTrue(DownloadState.resolving.isInFlight)
        XCTAssertTrue(DownloadState.transferring(received: 1, expected: nil).isInFlight)
        XCTAssertFalse(DownloadState.failed(reason: "nope").isInFlight)

        XCTAssertTrue(DownloadState.failed(reason: "nope").isFailed)
        XCTAssertFalse(DownloadState.queued.isFailed)
        XCTAssertFalse(DownloadState.resolving.isFailed)
        XCTAssertFalse(DownloadState.transferring(received: 1, expected: 2).isFailed)
    }
}

// MARK: - Aggregate progress

/// The number under a collection's download bar. Unit-weighted on purpose: `downloadAll`
/// resolves stream URLs one at a time, so for most of a forty-track batch thirty-nine tracks
/// have no known content length at all, and a byte denominator that grows as each one resolves
/// makes the bar slide backwards for a minute straight.
final class CollectionDownloadProgressTests: XCTestCase {

    private func progress(
        total: Int,
        completed: Int = 0,
        failed: Int = 0,
        active: Int = 0,
        partial: Double = 0,
        bytes: Int64 = 0,
        preparing: String? = nil,
        limitedUntil: Date? = nil
    ) -> CollectionDownloadProgress {
        CollectionDownloadProgress(
            total: total, completed: completed, failed: failed, active: active,
            partial: partial, bytesReceived: bytes, preparingTitle: preparing,
            rateLimitedUntil: limitedUntil
        )
    }

    /// A header renders this before anything has been asked for, so it must not divide by
    /// zero and must not claim to be finished.
    func testAnEmptyCollectionIsNeitherActiveNorComplete() {
        let empty = CollectionDownloadProgress.empty
        XCTAssertEqual(empty.fraction, 0)
        XCTAssertEqual(empty.settled, 0)
        XCTAssertFalse(empty.isActive)
        XCTAssertFalse(empty.isComplete)
        XCTAssertFalse(empty.hasFailures)
        XCTAssertEqual(progress(total: 0).fraction, 0)
    }

    func testSettledCountsOnlyWhatIsActuallyOnDisk() {
        let mid = progress(total: 4, completed: 1, active: 3, partial: 0.5)
        XCTAssertEqual(mid.settled, 0.25, accuracy: 0.0001)
        XCTAssertEqual(mid.fraction, 0.375, accuracy: 0.0001)
        XCTAssertTrue(mid.isActive)
        XCTAssertFalse(mid.isComplete)
    }

    func testEveryTrackOnDiskReadsAsComplete() {
        let done = progress(total: 3, completed: 3)
        XCTAssertEqual(done.fraction, 1)
        XCTAssertEqual(done.settled, 1)
        XCTAssertTrue(done.isComplete)
        XCTAssertFalse(done.isActive)
    }

    /// The one way this metric could run backwards: a track sitting at 60% transferred fails,
    /// and its contribution to `partial` vanishes. Failures count toward the leading edge
    /// instead — a batch with three permanent failures is *finished*, not stuck at 92%.
    func testAFailureMidBatchMovesTheBarForwardsNotBackwards() {
        let transferring = progress(total: 2, completed: 1, active: 1, partial: 0.6)
        let thenFailed = progress(total: 2, completed: 1, failed: 1)
        XCTAssertEqual(transferring.fraction, 0.8, accuracy: 0.0001)
        XCTAssertEqual(thenFailed.fraction, 1, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(thenFailed.fraction, transferring.fraction)

        // ...but a failure is not a success: the solid portion of the bar does not grow.
        XCTAssertEqual(thenFailed.settled, 0.5, accuracy: 0.0001)
        XCTAssertFalse(thenFailed.isComplete)
        XCTAssertTrue(thenFailed.hasFailures)
        XCTAssertFalse(thenFailed.isActive)
    }

    /// Rounding, a radio collection that shrank between renders, or a duplicate videoId could
    /// each push the numerator past the denominator; a bar wider than its track is worse than
    /// a wrong one.
    func testFractionIsClampedToOne() {
        XCTAssertEqual(progress(total: 2, completed: 2, failed: 1).fraction, 1)
        XCTAssertEqual(progress(total: 1, active: 1, partial: 1.4).fraction, 1)
    }

    /// "Paused — resuming in…" is a promise, and it needs both halves to be true: a deadline
    /// that hasn't passed, and a queue that will actually resume when it does.
    ///
    /// It is evaluated against a supplied clock rather than `Date.now` because the view decides
    /// it on a `TimelineView` tick. Read at body time it only changed when the manager
    /// published, and a cool-down lapsing is precisely a moment when nothing does — so a batch
    /// that had permanently failed sat frozen on "Resuming in 0:00", orange, indefinitely.
    func testAPausedClaimNeedsADeadlineAheadAndSomethingStillWaitingOnIt() {
        let deadline = Date(timeIntervalSinceReferenceDate: 1_000)
        let justBefore = deadline.addingTimeInterval(-1)
        let justAfter = deadline.addingTimeInterval(1)

        XCTAssertFalse(
            progress(total: 4, completed: 1, active: 3).isRateLimited(at: justBefore),
            "No cool-down recorded means nothing to be paused by"
        )
        XCTAssertTrue(
            progress(total: 4, completed: 1, active: 3, limitedUntil: deadline).isRateLimited(at: justBefore)
        )
        XCTAssertFalse(
            progress(total: 4, completed: 1, active: 3, limitedUntil: deadline).isRateLimited(at: justAfter),
            "The view must retire the caption on its own tick, not wait for a publish"
        )
        // The fully-failed batch: nothing is queued behind the cool-down, so there is nothing
        // for it to resume and the honest reading is "3 failed", not "resuming in 0:12".
        XCTAssertFalse(
            progress(total: 4, completed: 1, failed: 3, limitedUntil: deadline).isRateLimited(at: justBefore)
        )
    }
}

// MARK: - Batch persistence

/// Batch records outlive the process — a background session finishing a forty-track job while
/// VVDemus is dead must not come back as forty anonymous downloads — so they go through the
/// same `DefaultsSnapshot` path `DownloadManager.init()` restores from.
final class DownloadBatchPersistenceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DownloadBatchPersistenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func batch(_ ids: [String], artwork: String? = "https://art.test/cover.jpg") -> DownloadBatch {
        DownloadBatch(
            id: UUID(),
            title: "Weekend Mix",
            artworkURL: artwork,
            videoIds: ids,
            // Fixed rather than `Date()`, so an equality failure means the encoding lost
            // something and not that a Double lost its last digit.
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testABatchSurvivesTheRoundTripIntact() throws {
        let saved = [batch(["aaa", "bbb", "ccc"]), batch(["ddd"], artwork: nil)]
        DefaultsSnapshot.save(saved, forKey: "batches", to: defaults)
        let restored = try XCTUnwrap(DefaultsSnapshot.load([DownloadBatch].self, forKey: "batches", from: defaults))
        XCTAssertEqual(restored, saved)
        // The field the card is built from: a batch that came back without the *whole*
        // collection would read "0 of 30" where it should read "10 of 40".
        XCTAssertEqual(restored.first?.videoIds, ["aaa", "bbb", "ccc"])
        XCTAssertNil(restored.last?.artworkURL)
    }

    func testAWallClockStartTimeSurvivesTheRoundTrip() throws {
        let now = Date()
        let saved = DownloadBatch(
            id: UUID(), title: "Now", artworkURL: nil, videoIds: ["zzz"], startedAt: now
        )
        DefaultsSnapshot.save([saved], forKey: "batches", to: defaults)
        let restored = try XCTUnwrap(
            DefaultsSnapshot.load([DownloadBatch].self, forKey: "batches", from: defaults)?.first
        )
        XCTAssertEqual(restored.id, saved.id)
        XCTAssertEqual(
            restored.startedAt.timeIntervalSinceReferenceDate,
            now.timeIntervalSinceReferenceDate,
            accuracy: 0.001
        )
    }

    func testNothingStoredRestoresAsNothingRatherThanFailing() {
        XCTAssertNil(DefaultsSnapshot.load([DownloadBatch].self, forKey: "batches", from: defaults))
    }

    /// A schema change to `DownloadBatch` must degrade to "no cards" and keep the bytes, not
    /// crash and not overwrite them — the same contract every other store in the app has.
    func testAnUndecodableBlobIsPreservedRatherThanRead() {
        defaults.set(Data("not a batch".utf8), forKey: "batches")
        let outcome = DefaultsSnapshot.read([DownloadBatch].self, forKey: "batches", from: defaults)
        XCTAssertTrue(outcome.isCorrupt)
        XCTAssertNil(outcome.value)
        let backups = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("batches\(DefaultsSnapshot.corruptSuffix)")
        }
        XCTAssertEqual(backups.count, 1, "The unreadable bytes must be kept under a side key")
    }
}

// MARK: - The manager

/// `DownloadManager`'s in-flight bookkeeping, driven without a network.
///
/// Everything asserted here is reachable because the two bulk entry points — `downloadAll` and
/// `retryFailed` — do all of their state work synchronously and only then spawn a drain Task
/// whose *first* statement re-checks `active`. So a test that sets up and tears down inside one
/// main-actor turn never reaches `startTransfer`, and no stream is ever resolved. `setUp`
/// closes `RateLimitGate` as a belt-and-braces clamp on that: a drain Task that does get a turn
/// parks on the gate rather than going to YouTube.
///
/// The delegate callbacks are driven with real `URLSessionDownloadTask`s from a session this
/// test owns. `URLSessionDownloadTask.response` is read-only and a task can only be made by a
/// session, so an unresumed task carries no response — which `isAcceptableDownload` rejects for
/// the same reason it rejects a 403 error document, and which is what makes the failure branch
/// testable in-process.
@MainActor
final class DownloadManagerProgressTests: XCTestCase {
    private var manager: DownloadManager { .shared }
    private var taskSession: URLSession!
    /// Cancelled in `tearDown` whatever the test did, so nothing this file queued can survive
    /// into the next test and be resolved for real.
    private var toCancel: [Track] = []
    private var tempFiles: [URL] = []

    override func setUp() async throws {
        taskSession = URLSession(configuration: .ephemeral)
        manager.errorMessage = nil
        // Long enough to outlast any single test body, short enough that a Task parked on it
        // is awake and gone well before the suite ends.
        RateLimitGate.shared.recordRateLimit(retryAfter: 5)
    }

    override func tearDown() async throws {
        // Synchronous, and first: clearing `active` is what makes a still-parked drain loop
        // skip its remaining tracks instead of resolving them.
        manager.cancelAll(toCancel)
        toCancel = []
        manager.errorMessage = nil
        RateLimitGate.shared.clear()
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        taskSession.invalidateAndCancel()
        taskSession = nil
    }

    // MARK: Helpers

    /// Ids are unique per test rather than shared: a drain Task parked on the rate-limit gate
    /// outlives the test that created it, and would otherwise wake up owning a later test's
    /// entry for the same videoId.
    private func makeTracks(_ count: Int, prefix: String) -> [Track] {
        let tracks = (0..<count).map { Fixtures.track("\(prefix)\($0)") }
        toCancel.append(contentsOf: tracks)
        return tracks
    }

    private func downloadTask(for track: Track) -> URLSessionDownloadTask {
        let task = taskSession.downloadTask(with: URL(string: "https://stream.test/\(track.videoId).m4a")!)
        // The round-trip the whole background session depends on: task identifiers are unique
        // only within one session instance, so the videoId travels in `taskDescription`.
        task.taskDescription = track.videoId
        return task
    }

    /// One chunk landing, exactly as `URLSession` reports it. `expected` of -1 is
    /// `NSURLSessionTransferSizeUnknown`.
    private func sendBytes(_ track: Track, received: Int64, expected: Int64) {
        manager.urlSession(
            taskSession,
            downloadTask: downloadTask(for: track),
            didWriteData: received,
            totalBytesWritten: received,
            totalBytesExpectedToWrite: expected
        )
    }

    /// Byte updates are coalesced for `flushInterval` (250 ms) before they publish, so nothing
    /// about a fraction is observable in the turn the chunk arrives.
    private func awaitFlush() async {
        try? await Task.sleep(for: .milliseconds(400))
    }

    private func writeTempFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(count: bytes).write(to: url)
        tempFiles.append(url)
        return url
    }

    /// A finished transfer whose response is unacceptable — the rejected-download branch.
    private func finishWithRejectedResponse(_ track: Track) throws -> URL {
        let location = try writeTempFile(bytes: 2_048)
        manager.urlSession(taskSession, downloadTask: downloadTask(for: track), didFinishDownloadingTo: location)
        return location
    }

    private func ourEntries(_ tracks: [Track]) -> [DownloadEntry] {
        let ids = Set(tracks.map(\.videoId))
        return manager.activeEntries.filter { ids.contains($0.id) }
    }

    // MARK: Queueing

    func testDownloadAllQueuesEveryTrackAndMintsExactlyOneBatch() throws {
        let tracks = makeTracks(3, prefix: "dlqueue")
        manager.downloadAll(tracks, title: "Test Album", artworkURL: "https://art.test/a.jpg")

        for track in tracks {
            XCTAssertEqual(manager.state(for: track), DownloadState.queued)
            XCTAssertTrue(manager.isDownloading(track))
        }
        // Insertion order, not the dictionary's — a list built from `active.values` reshuffles
        // every time a fraction publishes.
        XCTAssertEqual(ourEntries(tracks).map(\.id), tracks.map(\.videoId))

        let batch = try XCTUnwrap(manager.batch(for: tracks))
        XCTAssertEqual(batch.title, "Test Album")
        XCTAssertEqual(batch.artworkURL, "https://art.test/a.jpg")
        XCTAssertEqual(batch.videoIds, tracks.map(\.videoId))
        XCTAssertEqual(manager.batches.filter { $0.id == batch.id }.count, 1)
        XCTAssertEqual(ourEntries(tracks).compactMap(\.batchId), Array(repeating: batch.id, count: 3))

        let aggregate = manager.collectionProgress(for: tracks)
        XCTAssertEqual(aggregate.total, 3)
        XCTAssertEqual(aggregate.active, 3)
        XCTAssertEqual(aggregate.completed, 0)
        XCTAssertEqual(aggregate.failed, 0)
        XCTAssertEqual(aggregate.partial, 0)
        XCTAssertEqual(aggregate.bytesReceived, 0)
        XCTAssertEqual(aggregate.fraction, 0)
        XCTAssertFalse(aggregate.isComplete)
        // Queued is not preparing: only the one track actually asking InnerTube for a URL gets
        // named, or the header would claim to be preparing forty tracks at once.
        XCTAssertNil(aggregate.preparingTitle)
    }

    /// Tapping Download twice on the same album is one job, not two cards over the same tracks.
    func testAskingAgainForAlreadyQueuedTracksDoesNotMintASecondBatch() {
        let tracks = makeTracks(2, prefix: "dlrequeue")
        manager.downloadAll(tracks, title: "Test Album")
        manager.downloadAll(tracks, title: "Test Album")
        XCTAssertEqual(manager.batches.filter { $0.videoIds == tracks.map(\.videoId) }.count, 1)
        XCTAssertEqual(ourEntries(tracks).count, 2)
    }

    /// The batch has to land in `UserDefaults` under the key `init()` reads back, or a relaunch
    /// mid-batch loses the card and forty transfers come back anonymous. The literal key is
    /// spelled out because it is private to `DownloadManager` and a rename without a migration
    /// would otherwise fail silently.
    func testTheBatchIsPersistedUnderTheKeyLaunchRestoresFrom() throws {
        let tracks = makeTracks(2, prefix: "dlpersist")
        manager.downloadAll(tracks, title: "Persisted Mix", artworkURL: nil)
        let batch = try XCTUnwrap(manager.batch(for: tracks))

        let stored = try XCTUnwrap(DefaultsSnapshot.load([DownloadBatch].self, forKey: "downloads_batches_v1"))
        let restored = try XCTUnwrap(stored.first { $0.id == batch.id })
        XCTAssertEqual(restored.title, "Persisted Mix")
        XCTAssertEqual(restored.videoIds, tracks.map(\.videoId))
        XCTAssertNil(restored.artworkURL)
        XCTAssertEqual(
            restored.startedAt.timeIntervalSinceReferenceDate,
            batch.startedAt.timeIntervalSinceReferenceDate,
            accuracy: 0.001
        )
    }

    // MARK: Cancelling

    func testCancellingOneMemberLeavesTheRestAndKeepsTheBatch() throws {
        let tracks = makeTracks(3, prefix: "dlcancelone")
        manager.downloadAll(tracks, title: "Partial Cancel")
        let batch = try XCTUnwrap(manager.batch(for: tracks))

        manager.cancel(tracks[1])

        XCTAssertNil(manager.state(for: tracks[1]))
        XCTAssertFalse(manager.isDownloading(tracks[1]))
        XCTAssertEqual(manager.state(for: tracks[0]), DownloadState.queued)
        XCTAssertEqual(manager.state(for: tracks[2]), DownloadState.queued)
        XCTAssertEqual(ourEntries(tracks).map(\.id), [tracks[0].videoId, tracks[2].videoId])

        let aggregate = manager.collectionProgress(for: tracks)
        // The collection still has three tracks; one of them is now simply nothing — neither
        // downloading, nor failed, nor on disk.
        XCTAssertEqual(aggregate.total, 3)
        XCTAssertEqual(aggregate.active, 2)
        XCTAssertEqual(aggregate.completed, 0)
        XCTAssertEqual(aggregate.failed, 0)

        XCTAssertNotNil(manager.batches.first { $0.id == batch.id }, "A batch with live members must survive")
    }

    func testCancellingEveryMemberRetiresTheBatchRatherThanLeavingACardForNothing() throws {
        let tracks = makeTracks(3, prefix: "dlcancelall")
        manager.downloadAll(tracks, title: "Whole Cancel")
        let batch = try XCTUnwrap(manager.batch(for: tracks))

        manager.cancelAll(tracks)

        for track in tracks {
            XCTAssertNil(manager.state(for: track))
            XCTAssertFalse(manager.isDownloading(track))
        }
        XCTAssertTrue(ourEntries(tracks).isEmpty)
        XCTAssertNil(manager.batches.first { $0.id == batch.id })
        XCTAssertNil(manager.batch(for: tracks))
        XCTAssertFalse(manager.collectionProgress(for: tracks).isActive)
        // Pruned in the persisted copy too, or the card comes back at next launch.
        let stored = DefaultsSnapshot.load([DownloadBatch].self, forKey: "downloads_batches_v1") ?? []
        XCTAssertNil(stored.first { $0.id == batch.id })
    }

    /// The Downloads screen's batch card cancels by id, and has to reach members that were
    /// never on screen.
    func testCancelBatchClearsEveryMemberById() throws {
        let tracks = makeTracks(4, prefix: "dlcancelbatch")
        manager.downloadAll(tracks, title: "By Id")
        let batch = try XCTUnwrap(manager.batch(for: tracks))

        manager.cancelBatch(batch.id)

        XCTAssertTrue(ourEntries(tracks).isEmpty)
        XCTAssertNil(manager.batches.first { $0.id == batch.id })
    }

    // MARK: Bytes

    func testFirstBytesMoveAQueuedTrackToTransferringWithARealFraction() async throws {
        let tracks = makeTracks(1, prefix: "dlbytes")
        let track = tracks[0]
        manager.downloadAll(tracks, title: "Byte Mix")
        XCTAssertEqual(manager.state(for: track), DownloadState.queued)

        sendBytes(track, received: 1_024, expected: 4_096)
        await awaitFlush()

        XCTAssertEqual(manager.state(for: track), DownloadState.transferring(received: 1_024, expected: 4_096))
        XCTAssertEqual(manager.state(for: track)?.fraction, 0.25)
        XCTAssertTrue(manager.isDownloading(track))

        let aggregate = manager.collectionProgress(for: tracks)
        XCTAssertEqual(aggregate.active, 1)
        XCTAssertEqual(aggregate.partial, 0.25, accuracy: 0.0001)
        XCTAssertEqual(aggregate.bytesReceived, 1_024)
        XCTAssertEqual(aggregate.fraction, 0.25, accuracy: 0.0001)

        // The drain loop parked on the closed gate instead of failing thirty-nine resolves
        // through it, and said so — a batch waiting out a 429 is otherwise indistinguishable
        // from a hung one.
        XCTAssertNotNil(manager.rateLimitedUntil)
    }

    /// A cool-down belongs to whatever is waiting on it, not to the process.
    ///
    /// The date used to be published globally and read straight off the manager by every strip
    /// on screen, so one refused download tinted an unrelated batch's card orange and captioned
    /// it "Paused" while its own transfers carried on landing underneath the word.
    func testACoolDownIsScopedToTheCollectionActuallyParkedOnIt() async throws {
        let parked = makeTracks(1, prefix: "dlparkscope")
        manager.downloadAll(parked, title: "Parked Mix")
        // The drain loop only reaches the closed gate once the main actor yields.
        await awaitFlush()

        XCTAssertTrue(manager.rateLimitedIds.contains(parked[0].videoId))
        XCTAssertNotNil(
            manager.collectionProgress(for: parked).rateLimitedUntil,
            "The collection whose track is parked has to say so"
        )

        let bystander = [Fixtures.track("dlparkbystander0")]
        XCTAssertNil(
            manager.collectionProgress(for: bystander).rateLimitedUntil,
            "A collection with nothing parked is not paused, whatever else the app is waiting on"
        )
    }

    /// Two jobs share one gate, and the cool-down now lives as long as *something* is still
    /// parked on it rather than as long as one particular drain loop is running.
    ///
    /// It used to be a `defer { rateLimitedUntil = nil }` per loop, so a second job that never
    /// waited on anything wiped the date out from under the job that was genuinely parked — the
    /// header dropped straight from "Paused, resuming in 4:12" back to a silent stalled bar.
    func testAJobThatNeverWaitedDoesNotRetireAnotherJobsCoolDown() async throws {
        let parked = makeTracks(1, prefix: "dlparkkeeper")
        let bailing = makeTracks(1, prefix: "dlparkbailer")
        manager.downloadAll(parked, title: "Parked Mix")
        manager.downloadAll(bailing, title: "Bailing Mix")
        // Cancelled before its drain loop has had a turn, so that loop skips its only track and
        // runs to completion without ever touching the gate.
        manager.cancelAll(bailing)

        await awaitFlush()

        XCTAssertTrue(manager.rateLimitedIds.contains(parked[0].videoId))
        XCTAssertFalse(manager.rateLimitedIds.contains(bailing[0].videoId))
        XCTAssertNotNil(manager.rateLimitedUntil, "The still-parked job's cool-down must survive")
        XCTAssertNotNil(manager.collectionProgress(for: parked).rateLimitedUntil)
    }

    func testAnUnsizedTransferShowsItsBytesAndNeverAFakeZeroPercent() async throws {
        let tracks = makeTracks(1, prefix: "dlunsized")
        let track = tracks[0]
        manager.downloadAll(tracks, title: "Unsized Mix")

        sendBytes(track, received: 65_536, expected: -1)
        await awaitFlush()

        XCTAssertEqual(manager.state(for: track), DownloadState.transferring(received: 65_536, expected: nil))
        XCTAssertNil(manager.state(for: track)?.fraction, "No Content-Length means unknown, not zero")

        let aggregate = manager.collectionProgress(for: tracks)
        XCTAssertEqual(aggregate.bytesReceived, 65_536)
        XCTAssertEqual(aggregate.active, 1)
        // Pessimistic on purpose: an unknown size contributes nothing to the bar, so the bar
        // can only ever move forward when the size finally becomes known.
        XCTAssertEqual(aggregate.partial, 0)
    }

    func testAResumedTransferNeverReportsFewerBytesThanItAlreadyShowed() async throws {
        let tracks = makeTracks(1, prefix: "dlresume")
        let track = tracks[0]
        manager.downloadAll(tracks, title: "Resume Mix")

        sendBytes(track, received: 2_048, expected: 4_096)
        await awaitFlush()
        XCTAssertEqual(manager.state(for: track), DownloadState.transferring(received: 2_048, expected: 4_096))

        // A background-session retry replays the same response from a lower counter.
        sendBytes(track, received: 512, expected: 4_096)
        await awaitFlush()
        XCTAssertEqual(
            manager.state(for: track),
            DownloadState.transferring(received: 2_048, expected: 4_096),
            "The ring must not sweep backwards"
        )

        // A different expected size is a genuinely new response, so it is taken verbatim
        // rather than held at the previous attempt's high-water mark forever.
        sendBytes(track, received: 512, expected: 9_000)
        await awaitFlush()
        XCTAssertEqual(manager.state(for: track), DownloadState.transferring(received: 512, expected: 9_000))
    }

    /// The race the flush introduces: a chunk arrives, the user cancels, and the coalesced
    /// write lands 250 ms later against an entry that no longer exists.
    func testAFlushLandingAfterACancelDoesNotResurrectTheRow() async throws {
        let tracks = makeTracks(1, prefix: "dlghostflush")
        let track = tracks[0]
        manager.downloadAll(tracks, title: "Ghost Flush")

        sendBytes(track, received: 1_024, expected: 4_096)
        manager.cancel(track)
        await awaitFlush()

        XCTAssertNil(manager.state(for: track))
        XCTAssertFalse(manager.isDownloading(track))
    }

    /// Chunks for a videoId nobody is tracking — a task adopted from a previous launch and
    /// since deleted — must not conjure an entry out of nothing.
    func testBytesForAnUntrackedDownloadAreIgnored() async throws {
        let stray = Fixtures.track("dlstray0")
        sendBytes(stray, received: 1_024, expected: 4_096)
        await awaitFlush()
        XCTAssertNil(manager.state(for: stray))
    }

    // MARK: Failure, retry, dismissal

    func testARejectedResponseKeepsTheEntrySoTheRowCanOfferARetry() throws {
        let tracks = makeTracks(2, prefix: "dlreject")
        manager.downloadAll(tracks, title: "Reject Mix")
        let batch = try XCTUnwrap(manager.batch(for: tracks))

        let location = try finishWithRejectedResponse(tracks[0])

        let state = try XCTUnwrap(manager.state(for: tracks[0]))
        XCTAssertTrue(state.isFailed)
        // Retained but *not* in flight: `download(_:)` guards on exactly this, so a failure
        // that still counted as downloading could never be retried.
        XCTAssertFalse(manager.isDownloading(tracks[0]))
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: location.path),
            "A rejected body must not be left behind in the temp directory"
        )

        let aggregate = manager.collectionProgress(for: tracks)
        XCTAssertEqual(aggregate.failed, 1)
        XCTAssertEqual(aggregate.active, 1)
        XCTAssertEqual(aggregate.completed, 0)
        XCTAssertTrue(aggregate.hasFailures)
        // The failed track counts toward the leading edge: the batch is one track closer to
        // finished, even though it is not one track closer to downloaded.
        XCTAssertEqual(aggregate.fraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(aggregate.settled, 0)

        XCTAssertNotNil(
            manager.batches.first { $0.id == batch.id },
            "A batch with a retained failure still has something to show"
        )
    }

    func testATransportFailureIsRetainedTheSameWay() {
        let tracks = makeTracks(1, prefix: "dltransport")
        manager.downloadAll(tracks, title: "Transport Mix")

        manager.urlSession(
            taskSession,
            task: downloadTask(for: tracks[0]),
            didCompleteWithError: URLError(.networkConnectionLost)
        )

        XCTAssertEqual(manager.state(for: tracks[0])?.isFailed, true)
        XCTAssertFalse(manager.isDownloading(tracks[0]))
        XCTAssertEqual(manager.collectionProgress(for: tracks).failed, 1)
        XCTAssertNotNil(manager.errorMessage)
    }

    /// A cancel is the user's own doing, and its entry was already dropped synchronously — the
    /// late completion callback must not put a failed row back or shout about it.
    func testACancelledTransferCompletingIsNotReportedAsAFailure() {
        let tracks = makeTracks(1, prefix: "dlcancelerr")
        manager.downloadAll(tracks, title: "Cancel Mix")
        manager.cancel(tracks[0])

        manager.urlSession(
            taskSession,
            task: downloadTask(for: tracks[0]),
            didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        )

        XCTAssertNil(manager.state(for: tracks[0]))
        XCTAssertNil(manager.errorMessage)
    }

    func testRetryingAFailureRequeuesItWithoutMintingASecondBatch() throws {
        let tracks = makeTracks(2, prefix: "dlretry")
        manager.downloadAll(tracks, title: "Retry Mix")
        let batch = try XCTUnwrap(manager.batch(for: tracks))
        _ = try finishWithRejectedResponse(tracks[0])
        XCTAssertEqual(manager.state(for: tracks[0])?.isFailed, true)

        manager.retryFailed(in: tracks.map(\.videoId))

        XCTAssertEqual(manager.state(for: tracks[0]), DownloadState.queued)
        XCTAssertTrue(manager.isDownloading(tracks[0]))
        // The retried entry keeps its batch, so one job stays one card.
        XCTAssertEqual(ourEntries(tracks).compactMap(\.batchId), [batch.id, batch.id])
        XCTAssertEqual(manager.batches.filter { $0.videoIds == tracks.map(\.videoId) }.count, 1)

        let aggregate = manager.collectionProgress(for: tracks)
        XCTAssertEqual(aggregate.failed, 0)
        XCTAssertEqual(aggregate.active, 2)
    }

    /// Retrying must not disturb tracks that never failed, or a Retry on a partly-transferred
    /// batch would throw away the bytes already received.
    func testRetryingLeavesHealthyMembersAlone() async throws {
        let tracks = makeTracks(2, prefix: "dlretrykeep")
        manager.downloadAll(tracks, title: "Retry Keep")
        sendBytes(tracks[1], received: 1_024, expected: 4_096)
        await awaitFlush()
        _ = try finishWithRejectedResponse(tracks[0])

        manager.retryFailed(in: tracks.map(\.videoId))

        XCTAssertEqual(manager.state(for: tracks[0]), DownloadState.queued)
        XCTAssertEqual(manager.state(for: tracks[1]), DownloadState.transferring(received: 1_024, expected: 4_096))
    }

    func testDismissingTheLastFailureRetiresTheBatchCard() throws {
        let tracks = makeTracks(1, prefix: "dldismiss")
        manager.downloadAll(tracks, title: "Dismiss Mix")
        let batch = try XCTUnwrap(manager.batch(for: tracks))
        _ = try finishWithRejectedResponse(tracks[0])
        XCTAssertEqual(manager.state(for: tracks[0])?.isFailed, true)
        XCTAssertNotNil(manager.batches.first { $0.id == batch.id })

        manager.dismissFailed(in: tracks.map(\.videoId))

        XCTAssertNil(manager.state(for: tracks[0]))
        XCTAssertNil(manager.batches.first { $0.id == batch.id })
    }

    func testDismissingDoesNotTouchDownloadsThatAreStillGoing() throws {
        let tracks = makeTracks(2, prefix: "dldismisskeep")
        manager.downloadAll(tracks, title: "Dismiss Keep")
        _ = try finishWithRejectedResponse(tracks[0])

        manager.dismissFailed(in: tracks.map(\.videoId))

        XCTAssertNil(manager.state(for: tracks[0]))
        XCTAssertEqual(manager.state(for: tracks[1]), DownloadState.queued)
    }

    /// Deleting a track used to leave a retained failure behind as a row for something that no
    /// longer exists — `removeAll`'s old `if isDownloading(track) { cancel(track) }` could not
    /// see a `.failed` entry, because `isDownloading` is deliberately false for one.
    func testRemovingATrackAlsoClearsARetainedFailure() throws {
        let tracks = makeTracks(1, prefix: "dlghostrow")
        manager.downloadAll(tracks, title: "Ghost Row")
        _ = try finishWithRejectedResponse(tracks[0])
        XCTAssertEqual(manager.state(for: tracks[0])?.isFailed, true)

        manager.remove(tracks[0])

        XCTAssertNil(manager.state(for: tracks[0]))
        XCTAssertFalse(manager.isDownloaded(tracks[0]))
    }

    // MARK: The job a detail header actually shows

    /// Single-tap downloads are the one path that resolves without the drain loop's gate in front
    /// of it, so a test that leaves one alive would reach YouTube the moment it suspended. Each
    /// of these bodies is synchronous end to end and drops its entries before returning; the
    /// `active` check at the top of `startTransfer` is what makes that sufficient.
    private func tapDownload(_ tracks: [Track]) {
        for track in tracks { manager.download(track) }
    }

    /// The bug this scoping exists for: tapping download on a few rows of a long playlist used to
    /// raise the hero's collection bar over every track in it, captioned "Downloading 0 of 50",
    /// with a Stop that would have taken the other forty-seven with it.
    ///
    /// Fixing that by returning no job at all went too far the other way — the strip vanished
    /// from single-tap downloads entirely. The job is the tracks that were *asked for*: two taps
    /// on a fifty-track playlist is a job of two.
    func testSingleTapDownloadsRaiseAJobOverJustThoseTracks() throws {
        let tracks = makeTracks(50, prefix: "dlloose")
        tapDownload([tracks[3], tracks[7]])

        let job = try XCTUnwrap(manager.downloadJob(for: tracks))
        XCTAssertEqual(job.progress.total, 2, "Two rows were tapped, not fifty")
        XCTAssertEqual(job.progress.active, 2)
        XCTAssertEqual(job.videoIds, [tracks[3].videoId, tracks[7].videoId], "In collection order")

        // The collection aggregate still answers the other question — how much of this
        // collection is on disk — over all fifty.
        XCTAssertEqual(manager.collectionProgress(for: tracks).total, 50)

        manager.cancelAll(tracks)
    }

    /// Cancelling one of a pair withdraws it from the request, so the denominator shrinks with
    /// it rather than stalling at a total that includes a track nobody is fetching.
    func testCancellingOneLooseDownloadNarrowsTheJobToWhatIsLeft() throws {
        let tracks = makeTracks(50, prefix: "dloosecancel")
        tapDownload([tracks[3], tracks[7]])

        manager.cancel(tracks[3])
        let job = try XCTUnwrap(manager.downloadJob(for: tracks))
        XCTAssertEqual(job.progress.total, 1)
        XCTAssertEqual(job.videoIds, [tracks[7].videoId])

        manager.cancel(tracks[7])
        XCTAssertNil(manager.downloadJob(for: tracks), "Nothing is being fetched, so there is no job")
    }

    /// The strip must not reach a collection with none of these tracks in it.
    func testALooseJobIsInvisibleToACollectionThatDoesNotContainIt() {
        let mine = makeTracks(3, prefix: "dlloosemine")
        let theirs = makeTracks(3, prefix: "dlloosetheirs")
        tapDownload([mine[0]])

        XCTAssertNotNil(manager.downloadJob(for: mine))
        XCTAssertNil(manager.downloadJob(for: theirs))

        manager.cancel(mine[0])
    }

    func testDownloadAllRaisesAJobOverTheWholeCollection() throws {
        let tracks = makeTracks(3, prefix: "dljob")
        manager.downloadAll(tracks, title: "Job Mix")

        let job = try XCTUnwrap(manager.downloadJob(for: tracks))
        XCTAssertEqual(job.videoIds, tracks.map(\.videoId))
        XCTAssertEqual(job.progress.total, 3)
        XCTAssertEqual(job.progress.active, 3)
    }

    /// A batch started from an album's own screen shares a song with every playlist that song is
    /// in. Picking a job by mere overlap hung that album's progress under the playlist's header
    /// for the sake of the one track they have in common.
    func testAJobIsPickedByHowMuchOfTheCollectionItOwnsNotByOverlap() throws {
        let playlist = makeTracks(6, prefix: "dlownership")
        let foreignAlbum = makeTracks(4, prefix: "dlforeign") + [playlist[5]]

        manager.downloadAll(foreignAlbum, title: "Some Album")
        manager.downloadAll(playlist, title: "The Playlist")

        let job = try XCTUnwrap(manager.downloadJob(for: playlist))
        XCTAssertEqual(job.progress.total, 6, "The playlist's own job owns five of these six; the album owns one")
        // Scoped to what is on this screen, so the album's four other tracks are not counted here.
        XCTAssertEqual(Set(job.videoIds), Set(playlist.map(\.videoId)))

        // And the album's own screen still sees its own job, whole.
        let albumJob = try XCTUnwrap(manager.downloadJob(for: foreignAlbum))
        XCTAssertEqual(albumJob.progress.total, 5)
    }

    /// Download All over rows the user had already tapped by hand: those transfers join the job
    /// rather than running beside it. Left loose, the batch owned none of the live downloads.
    func testDownloadAllAdoptsTransfersTheUserStartedByHand() throws {
        let tracks = makeTracks(3, prefix: "dladopt")
        tapDownload([tracks[0]])
        XCTAssertEqual(manager.state(for: tracks[0]), DownloadState.resolving)

        manager.downloadAll(tracks, title: "Adopt Mix")

        let batch = try XCTUnwrap(manager.batch(for: tracks))
        XCTAssertEqual(ourEntries(tracks).compactMap(\.batchId), Array(repeating: batch.id, count: 3))
        // Re-parented rather than re-inserted, which is what protects an adopted transfer's
        // progress: `insert` carries nothing over, so it would have knocked this back to `.queued`
        // and reset the ring of something already part-way through.
        XCTAssertEqual(manager.state(for: tracks[0]), DownloadState.resolving)
        XCTAssertEqual(manager.state(for: tracks[1]), DownloadState.queued)

        let job = try XCTUnwrap(manager.downloadJob(for: tracks))
        XCTAssertEqual(job.progress.total, 3)
        XCTAssertEqual(job.progress.active, 3)

        manager.cancelAll(tracks)
    }

    /// The edge the adoption pass also fixes: with every row already tapped there is nothing left
    /// to queue, and the old `guard !queued.isEmpty` minted no batch at all — so Download All did
    /// nothing visible and its button stayed a plain arrow over a collection that was downloading.
    func testDownloadAllOverACollectionAlreadyFullyInFlightStillMintsAJob() throws {
        let tracks = makeTracks(2, prefix: "dladoptall")
        tapDownload(tracks)
        XCTAssertNil(manager.downloadJob(for: tracks))

        manager.downloadAll(tracks, title: "All In Flight")

        let job = try XCTUnwrap(manager.downloadJob(for: tracks))
        XCTAssertEqual(job.progress.active, 2)

        manager.cancelAll(tracks)
    }

    /// The hero's Stop is scoped to its job, so a song the user is separately downloading from a
    /// row is not collateral — `cancelAll(_:)` over the whole collection would have taken it.
    func testCancellingByJobIdsSparesLooseDownloadsInTheSameCollection() throws {
        let tracks = makeTracks(3, prefix: "dlscopedcancel")
        manager.downloadAll([tracks[0], tracks[1]], title: "Scoped Cancel")
        tapDownload([tracks[2]])

        let job = try XCTUnwrap(manager.downloadJob(for: tracks))
        XCTAssertEqual(job.progress.total, 2, "The loose download is not one of the job's tracks")
        manager.cancelAll(videoIds: job.videoIds)

        XCTAssertNil(manager.state(for: tracks[0]))
        XCTAssertNil(manager.state(for: tracks[1]))
        XCTAssertNotNil(manager.state(for: tracks[2]), "A single-tap download is not part of the collection's job")

        manager.cancel(tracks[2])
    }

    /// A cancel landing before the resolve Task gets its turn used to start the transfer anyway,
    /// after `cancelTasks` had already walked the session — so nothing was left to stop it, the
    /// whole file arrived minutes later, and the delegate dropped it for want of a track.
    func testCancellingBeforeTheResolveRunsLeavesNothingToResolve() async throws {
        let tracks = makeTracks(1, prefix: "dlcancelrace")
        manager.download(tracks[0])
        manager.cancel(tracks[0])

        // Long enough for the scheduled Task to have taken its turn and bailed. A resolve that
        // did happen would land an error on the manager, since the videoId is not a real one.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(manager.state(for: tracks[0]))
        XCTAssertNil(manager.errorMessage, "A cancelled download must not go on to resolve a stream")
    }

    // MARK: The whole picture

    /// One batch in every phase at once, which is what a forty-track playlist actually looks
    /// like a few seconds in — and the arithmetic the header's bar and label are built from.
    func testAggregateProgressAcrossAMixedBatch() async throws {
        let tracks = makeTracks(4, prefix: "dlmixed")
        manager.downloadAll(tracks, title: "Mixed Mix")

        sendBytes(tracks[0], received: 500, expected: 1_000)   // half of a known size
        sendBytes(tracks[1], received: 800, expected: -1)      // bytes arriving, size unknown
        await awaitFlush()
        _ = try finishWithRejectedResponse(tracks[2])          // lost
        // tracks[3] is still waiting its turn.

        let aggregate = manager.collectionProgress(for: tracks)
        XCTAssertEqual(aggregate.total, 4)
        XCTAssertEqual(aggregate.completed, 0)
        XCTAssertEqual(aggregate.failed, 1)
        XCTAssertEqual(aggregate.active, 3)
        XCTAssertEqual(aggregate.partial, 0.5, accuracy: 0.0001)
        XCTAssertEqual(aggregate.bytesReceived, 1_300)
        XCTAssertEqual(aggregate.fraction, 1.5 / 4, accuracy: 0.0001)
        XCTAssertEqual(aggregate.settled, 0)
        XCTAssertTrue(aggregate.isActive)
        XCTAssertTrue(aggregate.hasFailures)
        XCTAssertFalse(aggregate.isComplete)
        XCTAssertEqual(manager.state(for: tracks[3]), DownloadState.queued)
    }

    /// The sequence a row walks through, in one place: accepted into a queue, bytes start
    /// arriving, and the entry is gone once nothing is tracking it any more.
    ///
    /// The `.resolving` step in the middle and the successful terminal step are absent because
    /// both require a resolved stream URL: `DownloadManager` reaches `APIClient.shared`
    /// directly, and `URLSessionDownloadTask.response` cannot be set from outside a session, so
    /// neither is reachable without a network. `DownloadIntegrationTests` covers them.
    func testATrackWalksFromQueuedToTransferringAndThenOffTheList() async throws {
        let tracks = makeTracks(1, prefix: "dlwalk")
        let track = tracks[0]

        XCTAssertNil(manager.state(for: track))

        manager.downloadAll(tracks, title: "Walk Mix")
        XCTAssertEqual(manager.state(for: track), DownloadState.queued)
        XCTAssertNil(manager.state(for: track)?.fraction, "Queued has no fraction to show")

        sendBytes(track, received: 2_048, expected: 8_192)
        await awaitFlush()
        XCTAssertEqual(manager.state(for: track)?.fraction, 0.25)

        manager.cancel(track)
        XCTAssertNil(manager.state(for: track))
        XCTAssertFalse(manager.isDownloading(track))
        XCTAssertNil(manager.batch(for: tracks))
    }
}
