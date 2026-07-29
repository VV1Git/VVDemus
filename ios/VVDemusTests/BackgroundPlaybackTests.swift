import XCTest
@testable import VVDemus

/// What has to keep working with the screen off and the app in the background: tracks
/// advancing on their own, downloads playing without a network, failures not leaving the
/// queue dead, and the lock screen telling the truth throughout.
///
/// Nothing here can rely on the UI running — while the phone is asleep there is no view
/// hierarchy being updated, so every one of these paths has to be driven by the player
/// itself.
@MainActor
final class BackgroundPlaybackTests: XCTestCase {
    private var harness: PlayerHarness!

    override func setUp() async throws {
        harness = PlayerHarness()
    }

    // MARK: - Advancing unattended

    /// The end-of-track observer was once registered against the wrong object, so nothing
    /// advanced when a track finished — playback simply sat at the end of the song.
    func testATrackEndingAdvancesTheQueue() async {
        let list = Fixtures.tracks(["a", "b", "c"])
        await harness.startPlaying(list[0], context: list)

        harness.engine.finishTrack()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" }

        XCTAssertEqual(harness.player.currentTrack?.videoId, "b")
        XCTAssertTrue(harness.player.isPlaying)
    }

    func testAWholePlaylistPlaysThroughUnattended() async {
        let list = Fixtures.tracks(["a", "b", "c", "d"])
        harness.player.autoplayEnabled = false
        await harness.startPlaying(list[0], context: list)

        for expected in ["b", "c", "d"] {
            harness.engine.finishTrack()
            await harness.settle { self.harness.player.currentTrack?.videoId == expected }
        }

        XCTAssertEqual(harness.player.currentTrack?.videoId, "d")
        XCTAssertTrue(harness.player.contextQueue.isEmpty)
    }

    /// Running out of queue has to stop cleanly: leaving the player attached and running
    /// meant audio kept coming out under a UI that said paused, and the lock-screen
    /// scrubber ran forward over a finished track forever.
    func testRunningOutOfQueueStopsCleanly() async {
        harness.player.autoplayEnabled = false
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 100)

        harness.engine.finishTrack()
        await harness.settle { !self.harness.player.isPlaying }

        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertFalse(harness.player.isLoading)
        XCTAssertEqual(harness.nowPlaying.latest?.rate, 0)
    }

    func testAutoplayRollsIntoARadioWhenTheQueueRunsOut() async {
        harness.radios.results["a"] = Fixtures.tracks(["r1", "r2", "r3"])
        await harness.startPlaying(Fixtures.track("a"))

        harness.engine.finishTrack()
        await harness.settle { self.harness.player.currentTrack?.videoId == "r1" }

        XCTAssertEqual(harness.player.currentTrack?.videoId, "r1")
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["r2", "r3"])
        XCTAssertEqual(harness.player.queueContextTitle, "Track a Radio")
        XCTAssertEqual(harness.sideEffects.radioSeeds.last?.videoId, "a", "The station belongs in Your Radio")
    }

    func testAutoplayPrefersAnAlreadyCachedMix() async {
        harness.sideEffects.radioCache["a"] = Fixtures.tracks(["cached1", "cached2"])
        await harness.startPlaying(Fixtures.track("a"))

        harness.engine.finishTrack()
        await harness.settle { self.harness.player.currentTrack?.videoId == "cached1" }

        XCTAssertTrue(harness.radios.requests.isEmpty, "A cached mix means no network request")
    }

    func testAutoplaySkipsRecentlyPlayedTracks() async {
        harness.radios.results["a"] = Fixtures.tracks(["r1", "r2", "r3"])
        harness.sideEffects.recentIds = ["r1", "r2"]
        await harness.startPlaying(Fixtures.track("a"))

        harness.engine.finishTrack()
        await harness.settle { self.harness.player.currentTrack?.videoId == "r3" }

        XCTAssertEqual(harness.player.currentTrack?.videoId, "r3")
    }

    /// Hour-long "continuous mix" uploads read as ordinary songs in the API response and
    /// hijack the queue for the rest of the evening.
    func testAutoplayFiltersOutLongFormCompilations() async {
        harness.radios.results["a"] = [
            Fixtures.track("mix", durationSeconds: 3 * 3600),
            Fixtures.track("song", durationSeconds: 200),
        ]
        await harness.startPlaying(Fixtures.track("a"))

        harness.engine.finishTrack()
        await harness.settle { self.harness.player.currentTrack?.videoId == "song" }

        XCTAssertEqual(harness.player.currentTrack?.videoId, "song")
    }

    func testAutoplayFailingStopsCleanlyRatherThanHanging() async {
        harness.radios.failing = ["a"]
        await harness.startPlaying(Fixtures.track("a"))

        harness.engine.finishTrack()
        await harness.settle { !self.harness.player.isLoading && !self.harness.player.isPlaying }

        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertFalse(harness.player.isLoading, "A stuck spinner on the lock screen is worse than a clean stop")
    }

    func testAutoplayReturningNothingUsableStopsCleanly() async {
        harness.radios.results["a"] = [Fixtures.track("a")] // only the seed itself
        await harness.startPlaying(Fixtures.track("a"))

        harness.engine.finishTrack()
        await harness.settle { !self.harness.player.isLoading && !self.harness.player.isPlaying }

        XCTAssertFalse(harness.player.isPlaying)
    }

    func testAutoplayCanBeTurnedOff() async {
        harness.player.autoplayEnabled = false
        harness.radios.results["a"] = Fixtures.tracks(["r1"])
        await harness.startPlaying(Fixtures.track("a"))

        harness.engine.finishTrack()
        await harness.settle { !self.harness.player.isPlaying }

        XCTAssertTrue(harness.radios.requests.isEmpty)
        XCTAssertEqual(harness.player.currentTrack?.videoId, "a")
    }

    // MARK: - Offline

    func testDownloadedTracksPlayStraightFromDiskWithNoNetwork() async {
        let track = Fixtures.track("a")
        let localURL = URL(fileURLWithPath: "/tmp/vvdemus-test/a.m4a")
        harness.downloads.localFiles["a"] = localURL

        await harness.startPlaying(track)

        XCTAssertEqual(harness.engine.attachedURL, localURL)
        XCTAssertEqual(harness.streams.resolveCount["a"] ?? 0, 0, "A downloaded track must not hit the network")
        XCTAssertTrue(harness.player.isPlaying)
    }

    func testADownloadedTrackPlaysEvenWhileEveryStreamResolveFails() async {
        harness.streams.failing = ["a"]
        harness.downloads.localFiles["a"] = URL(fileURLWithPath: "/tmp/vvdemus-test/a.m4a")

        await harness.startPlaying(Fixtures.track("a"))

        XCTAssertTrue(harness.player.isPlaying)
        XCTAssertNil(harness.player.errorMessage)
    }

    /// Going offline mid-queue: the failure has to be visible and must not leave the UI
    /// and lock screen claiming to play.
    func testAFailedLoadReportsAnErrorAndStopsClaimingToPlay() async {
        harness.streams.failing = ["b"]
        let list = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(list[0], context: list)

        harness.player.advance()
        await harness.settle { self.harness.player.errorMessage != nil }

        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertFalse(harness.player.isLoading)
        XCTAssertEqual(harness.nowPlaying.latest?.rate, 0)
    }

    // MARK: - Playback failing mid-stream

    /// An expired stream URL is the routine case: they are time-limited, so a queue built
    /// an hour ago hits this. One silent re-resolve is much better than a dead play button.
    func testAFailedItemIsRetriedOnceWithAFreshUrl() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 40)
        let resolvesBefore = harness.streams.resolveCount["a"] ?? 0

        harness.engine.fail()
        await harness.settle { (self.harness.streams.resolveCount["a"] ?? 0) > resolvesBefore }

        XCTAssertTrue(harness.streams.invalidated.contains("a"), "The dead URL has to be dropped from the cache first")
        await harness.settle { self.harness.player.isPlaying }
        XCTAssertTrue(harness.engine.events.contains(.seek(40)), "and playback should resume where it failed")
    }

    func testASecondFailureSurfacesAnErrorInsteadOfLoopingForever() async {
        await harness.startPlaying(Fixtures.track("a"))

        harness.engine.fail()
        await harness.settle { (self.harness.streams.resolveCount["a"] ?? 0) > 1 }
        await harness.settle { !self.harness.player.isLoading }
        harness.engine.fail()
        await harness.settle { self.harness.player.errorMessage != nil }

        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertLessThanOrEqual(harness.streams.resolveCount["a"] ?? 0, 3, "It must not retry in a loop")
    }

    func testTheRetryBudgetResetsForEachNewTrack() async {
        let list = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(list[0], context: list)
        harness.engine.fail()
        await harness.settle { (self.harness.streams.resolveCount["a"] ?? 0) > 1 }

        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" && !self.harness.player.isLoading }
        let resolvesBefore = harness.streams.resolveCount["b"] ?? 0

        harness.engine.fail()
        await harness.settle { (self.harness.streams.resolveCount["b"] ?? 0) > resolvesBefore }

        XCTAssertGreaterThan(harness.streams.resolveCount["b"] ?? 0, resolvesBefore)
    }

    func testAFailureWhileCastingIsNotTreatedAsAPhoneFailure() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }
        let resolvesBefore = harness.streams.resolveCount["a"] ?? 0

        harness.engine.fail()
        await harness.drain()

        XCTAssertEqual(harness.streams.resolveCount["a"] ?? 0, resolvesBefore)
        XCTAssertTrue(harness.player.isPlaying, "The browser is the one playing; the phone's idle item failing is irrelevant")
    }

    // MARK: - Rapid input

    /// Hammering next while backgrounded (a stuck button, a car stereo repeating) must
    /// land on the right track with no stale load overtaking a newer one.
    func testRapidSkippingLandsOnTheRightTrack() async {
        let list = Fixtures.tracks(["a", "b", "c", "d", "e"])
        await harness.startPlaying(list[0], context: list)

        harness.player.advance()
        harness.player.advance()
        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "d" && !self.harness.player.isLoading }

        XCTAssertEqual(harness.player.currentTrack?.videoId, "d")
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["e"])
        XCTAssertTrue(harness.player.isPlaying)
    }

    /// A slow resolve for a track the user has already skipped past must not attach.
    func testAStaleLoadCannotOvertakeANewerOne() async {
        let list = Fixtures.tracks(["a", "b", "c"])
        await harness.startPlaying(list[0], context: list)

        harness.streams.isSuspended = true
        harness.player.advance() // starts loading "b"
        await harness.drain()
        harness.player.advance() // user skips on to "c" while "b" is still resolving
        await harness.drain()

        harness.streams.release()
        await harness.settle { !self.harness.player.isLoading }

        XCTAssertEqual(harness.player.currentTrack?.videoId, "c")
        XCTAssertEqual(harness.engine.attachedURL?.absoluteString, "https://stream.test/c.m4a")
    }
}
