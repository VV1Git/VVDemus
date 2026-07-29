import XCTest
@testable import VVDemus

/// Moving playback between the phone and a browser, and keeping the two honest about what
/// is actually coming out of the speakers.
@MainActor
final class DeviceSwitchingTests: XCTestCase {
    private var harness: PlayerHarness!

    override func setUp() async throws {
        harness = PlayerHarness()
    }

    // MARK: - Handing off to the computer

    func testSwitchingToComputerPausesThePhoneAndResolvesAStream() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.clearEvents()

        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }

        XCTAssertTrue(harness.engine.events.contains(.pause), "The phone must stop decoding once the browser takes over")
        XCTAssertEqual(harness.player.externalStream?.videoId, "a")
        XCTAssertEqual(harness.player.activeDevice, .computer)
    }

    /// Switching mid-playback used to leave the browser with nothing to play, because only
    /// a *new* track load resolved a URL for it.
    func testSwitchingMidTrackStillGivesTheBrowserAUrl() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 45)

        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }

        XCTAssertEqual(harness.player.externalStream?.videoId, "a")
        XCTAssertEqual(harness.player.progress, 45, accuracy: 0.001)
    }

    func testCastingSetsAMixingAudioSession() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.session.clear()

        harness.player.setActiveDevice(.computer)
        await harness.drain()

        XCTAssertEqual(harness.session.activations.first, .init(casting: true))
    }

    /// The URL and the track it belongs to must never be observable out of step, or the
    /// browser plays one track behind the phone with nothing to correct it.
    func testStreamUrlIsNeverPairedWithTheWrongTrack() async {
        let queue = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(queue[0], context: queue)
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }

        harness.streams.isSuspended = true
        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" }

        // Mid-resolve: either there's no URL yet, or it's the new track's — never the old one.
        if let stream = harness.player.externalStream {
            XCTAssertEqual(stream.videoId, "b")
        }
        harness.streams.release()
        await harness.settle { self.harness.player.externalStream?.videoId == "b" }
    }

    // MARK: - Taking playback back

    func testSwitchingBackToThePhoneResumesAtTheSamePosition() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }

        harness.player.applyExternalReport(
            epoch: harness.player.playbackEpoch,
            videoId: "a",
            progress: 64,
            duration: 180,
            isPlaying: true
        )
        harness.engine.clearEvents()
        let attachesBefore = harness.engine.attachCount

        harness.player.setActiveDevice(.iphone)
        await harness.settle { self.harness.engine.attachCount > attachesBefore }

        XCTAssertTrue(harness.engine.events.contains(.seek(64)), "Playback should pick up where the computer left it")
        XCTAssertTrue(harness.engine.events.contains(.play))
        XCTAssertNil(harness.player.externalStream, "The browser must be told to stop")
    }

    func testSwitchingBackWhilePausedDoesNotStartPlaying() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }
        harness.player.togglePlayPause() // pause on the computer
        XCTAssertFalse(harness.player.isPlaying)
        let attachesBefore = harness.engine.attachCount

        harness.player.setActiveDevice(.iphone)
        await harness.settle { self.harness.engine.attachCount > attachesBefore }

        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertFalse(harness.engine.didPlayAfterLastAttach)
    }

    /// Resolving a stream is async, so a pause pressed *during* the hand-back has to be
    /// honoured by the reattach rather than reverted by it.
    func testPausingDuringAHandBackIsHonoured() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }

        harness.streams.isSuspended = true
        let attachesBefore = harness.engine.attachCount
        harness.player.setActiveDevice(.iphone)
        await harness.drain()

        harness.player.togglePlayPause() // pause while the URL is still resolving
        XCTAssertFalse(harness.player.isPlaying)

        harness.streams.release()
        await harness.settle { self.harness.engine.attachCount > attachesBefore }

        XCTAssertFalse(harness.player.isPlaying, "The pause pressed mid-hand-back must survive the reattach")
        XCTAssertFalse(harness.engine.didPlayAfterLastAttach)
    }

    /// Switch back to the phone, then immediately away again. The late-arriving resolve
    /// must not attach and start the phone playing *on top of* the browser.
    func testSwitchingAwayAgainMidHandBackDoesNotStartPhoneAudio() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }

        harness.streams.isSuspended = true
        harness.player.setActiveDevice(.iphone)
        await harness.drain()
        harness.engine.clearEvents()

        harness.player.setActiveDevice(.computer)
        harness.streams.release()
        await harness.drain()

        XCTAssertEqual(harness.player.activeDevice, .computer)
        XCTAssertFalse(
            harness.engine.events.contains(.play),
            "The phone would be playing out loud over the browser"
        )
    }

    func testAFailedHandBackDoesNotWedgeTransportControls() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }

        harness.streams.failing = ["a"]
        harness.player.setActiveDevice(.iphone)
        await harness.settle { self.harness.player.errorMessage != nil }

        XCTAssertFalse(harness.player.isPlaying, "A failed hand-back must not leave the UI claiming to play")

        // The stuck-flag bug: from here on, play/pause silently did nothing forever,
        // because the resume flag was never cleared and every toggle took the branch that
        // only records intent.
        harness.engine.clearEvents()
        harness.player.togglePlayPause()
        XCTAssertTrue(harness.engine.events.contains(.play), "Play/pause must still reach the player")

        harness.streams.failing = []
        harness.player.play(track: Fixtures.track("b"))
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" && !self.harness.player.isLoading }
        XCTAssertTrue(harness.player.isPlaying, "A later track must still be playable")
        XCTAssertTrue(harness.engine.events.contains(.play))
    }

    // MARK: - Reports from the browser

    func testReportsFromTheBrowserDriveProgress() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }

        harness.player.applyExternalReport(
            epoch: harness.player.playbackEpoch,
            videoId: "a",
            progress: 30,
            duration: 180,
            isPlaying: true
        )

        XCTAssertEqual(harness.player.progress, 30, accuracy: 0.001)
        XCTAssertEqual(harness.player.duration, 180, accuracy: 0.001)
    }

    func testStaleEpochReportsAreDiscarded() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }
        let currentEpoch = harness.player.playbackEpoch

        harness.player.applyExternalReport(
            epoch: currentEpoch,
            videoId: "a",
            progress: 30,
            duration: 180,
            isPlaying: true
        )
        harness.player.seek(to: 120) // bumps the epoch

        harness.player.applyExternalReport(
            epoch: currentEpoch,
            videoId: "a",
            progress: 31,
            duration: 180,
            isPlaying: true
        )

        XCTAssertEqual(harness.player.progress, 120, accuracy: 0.001, "A report from before the seek must not rewind it")
    }

    func testReportsForTheOutgoingTrackAreDiscarded() async {
        let queue = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(queue[0], context: queue)
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }
        harness.player.applyExternalReport(
            epoch: harness.player.playbackEpoch, videoId: "a", progress: 90, duration: 180, isPlaying: true
        )

        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" }

        harness.player.applyExternalReport(
            epoch: harness.player.playbackEpoch, videoId: "a", progress: 92, duration: 180, isPlaying: true
        )

        XCTAssertEqual(harness.player.progress, 0, accuracy: 0.001, "Track b must not start 92 seconds in")
    }

    func testReportWithoutAVideoIdIsDiscarded() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }

        harness.player.applyExternalReport(
            epoch: harness.player.playbackEpoch, videoId: nil, progress: 55, duration: 180, isPlaying: true
        )

        XCTAssertEqual(harness.player.progress, 0, accuracy: 0.001)
    }

    func testReportsAreIgnoredOnceThePhoneIsTheActiveDevice() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 10)

        harness.player.applyExternalReport(
            epoch: harness.player.playbackEpoch, videoId: "a", progress: 200, duration: 300, isPlaying: false
        )

        XCTAssertEqual(harness.player.progress, 10, accuracy: 0.001)
        XCTAssertTrue(harness.player.isPlaying)
    }

    func testNonFiniteReportValuesAreRejected() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }

        harness.player.applyExternalReport(
            epoch: harness.player.playbackEpoch, videoId: "a", progress: .nan, duration: .infinity, isPlaying: true
        )

        XCTAssertTrue(harness.player.progress.isFinite)
        XCTAssertTrue(harness.player.duration.isFinite)
    }

    /// A pause pressed on the phone while casting has to stick, even though reports
    /// describing the browser still playing keep arriving under the new epoch for a while.
    func testAPauseFromThePhoneIsNotUndoneByAnInFlightReport() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }

        harness.player.togglePlayPause()
        XCTAssertFalse(harness.player.isPlaying)

        // The browser hasn't caught up yet and reports itself as still playing.
        harness.player.applyExternalReport(
            epoch: harness.player.playbackEpoch, videoId: "a", progress: 12, duration: 180, isPlaying: true
        )

        XCTAssertFalse(harness.player.isPlaying, "The pause bounced back to playing")
        XCTAssertEqual(harness.player.progress, 12, accuracy: 0.001, "but the position is still worth taking")
    }

    func testThePhoneAcceptsTheBrowserOnceItAgrees() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }
        harness.player.togglePlayPause()

        harness.player.applyExternalReport(
            epoch: harness.player.playbackEpoch, videoId: "a", progress: 12, duration: 180, isPlaying: false
        )
        // Once agreed, the browser is authoritative again — e.g. the user pressed play on
        // the Mac itself.
        harness.player.applyExternalReport(
            epoch: harness.player.playbackEpoch, videoId: "a", progress: 13, duration: 180, isPlaying: true
        )

        XCTAssertTrue(harness.player.isPlaying)
    }

    // MARK: - Adopting playback the browser carried on with

    func testAdoptingCatchesThePhoneUpWithoutRestartingTheTrack() async {
        let queue = Fixtures.tracks(["a", "b", "c"])
        await harness.startPlaying(queue[0], context: queue)
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }
        let loadEpochBefore = harness.player.trackLoadEpoch

        harness.player.adoptExternalPlayback(videoId: "b", progress: 20)
        await harness.drain()

        XCTAssertEqual(harness.player.currentTrack?.videoId, "b")
        XCTAssertEqual(harness.player.progress, 20, accuracy: 0.001)
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["c"], "The queue should follow on from where the browser got to")
        XCTAssertEqual(
            harness.player.trackLoadEpoch,
            loadEpochBefore,
            "Bumping the load epoch would tell the browser to start the track over"
        )
    }

    /// The reclaim path switches the device first, which starts resolving the *outgoing*
    /// track. That task used to survive and overwrite the adopted track's URL.
    func testAdoptingCancelsAnInFlightResolveForTheOldTrack() async {
        let queue = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(queue[0], context: queue)

        harness.streams.isSuspended = true
        harness.player.setActiveDevice(.computer)
        await harness.drain()

        harness.player.adoptExternalPlayback(videoId: "b", progress: 5)
        harness.streams.release()
        await harness.settle { self.harness.player.externalStream?.videoId == "b" }

        XCTAssertEqual(harness.player.currentTrack?.videoId, "b")
        XCTAssertEqual(
            harness.player.externalStream?.videoId,
            "b",
            "The stale resolve overwrote the adopted track's URL with the previous track's"
        )
    }

    func testAdoptingATrackNotInAnyQueueIsIgnored() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }

        harness.player.adoptExternalPlayback(videoId: "unknown", progress: 10)
        await harness.drain()

        XCTAssertEqual(harness.player.currentTrack?.videoId, "a")
    }

    func testAdoptingIsIgnoredWhenThePhoneIsTheActiveDevice() async {
        let queue = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(queue[0], context: queue)

        harness.player.adoptExternalPlayback(videoId: "b", progress: 10)
        await harness.drain()

        XCTAssertEqual(harness.player.currentTrack?.videoId, "a")
    }

    // MARK: - Prefetching what plays next

    /// The browser's lifeline if the phone is unreachable at a track boundary.
    func testTheNextTrackIsPrefetchedWhileCasting() async {
        let queue = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(queue[0], context: queue)

        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.upNextStream != nil }

        XCTAssertEqual(harness.player.upNextTrack?.videoId, "b")
        XCTAssertEqual(harness.player.upNextStream?.videoId, "b")
    }

    func testNothingIsPrefetchedWhilePlayingOnThePhone() async {
        let queue = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(queue[0], context: queue)
        await harness.drain()

        XCTAssertNil(harness.player.upNextStream)
        XCTAssertNil(harness.player.upNextTrack)
    }

    /// Re-resolving a URL that was already prefetched put a second of silence into every
    /// track change while casting.
    func testAdvancingReusesThePrefetchedUrl() async {
        let queue = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(queue[0], context: queue)
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.upNextStream != nil }
        let resolvesBefore = harness.streams.resolveCount["b"] ?? 0

        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" }

        XCTAssertEqual(harness.player.externalStream?.videoId, "b")
        XCTAssertFalse(harness.player.isLoading, "The URL was already in hand; there is nothing to wait for")
        XCTAssertEqual(harness.streams.resolveCount["b"] ?? 0, resolvesBefore, "It shouldn't be resolved a second time")
    }

    func testSwitchingBackToThePhoneClearsThePrefetch() async {
        let queue = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(queue[0], context: queue)
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.upNextStream != nil }

        harness.player.setActiveDevice(.iphone)
        await harness.drain()

        XCTAssertNil(harness.player.upNextStream)
        XCTAssertNil(harness.player.upNextTrack)
    }

    // MARK: - Epochs

    func testEveryInstructionAdvancesThePlaybackEpoch() async {
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 300))
        var epoch = harness.player.playbackEpoch

        harness.player.togglePlayPause()
        XCTAssertGreaterThan(harness.player.playbackEpoch, epoch)
        epoch = harness.player.playbackEpoch

        harness.player.seek(to: 10)
        XCTAssertGreaterThan(harness.player.playbackEpoch, epoch)
        epoch = harness.player.playbackEpoch

        harness.player.setActiveDevice(.computer)
        XCTAssertGreaterThan(harness.player.playbackEpoch, epoch)
    }

    /// Restarting the track that's already playing doesn't change the videoId, so the
    /// browser keys its reload on this instead.
    func testRestartingTheCurrentTrackAdvancesTheLoadEpoch() async {
        let queue = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(queue[0], context: queue)
        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" }
        let epoch = harness.player.trackLoadEpoch

        harness.player.previous()
        await harness.settle { self.harness.player.currentTrack?.videoId == "a" }
        harness.player.previous() // back to the top of "a"

        XCTAssertGreaterThan(harness.player.trackLoadEpoch, epoch)
    }

    func testSwitchingToTheSameDeviceIsANoOp() async {
        await harness.startPlaying(Fixtures.track("a"))
        let epoch = harness.player.playbackEpoch

        harness.player.setActiveDevice(.iphone)

        XCTAssertEqual(harness.player.playbackEpoch, epoch)
    }
}
