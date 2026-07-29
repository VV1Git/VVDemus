import XCTest
@testable import VVDemus

/// The play/pause button must agree with reality at every moment, including the second or
/// two at the start of a track when the player is still filling its buffer.
///
/// This suite exists because of a shipped regression: the engine's "is it playing" flag
/// was defined as `timeControlStatus == .playing`, which is false while AVPlayer buffers.
/// A periodic reconcile then flipped the app's `isPlaying` to false as playback was
/// starting, so the button showed the play triangle over audible music and the next press
/// was interpreted as "resume" instead of "pause" — two presses to pause, on screen and on
/// the lock screen.
@MainActor
final class PlayPauseStateTests: XCTestCase {
    private var harness: PlayerHarness!

    override func setUp() async throws {
        harness = PlayerHarness()
    }

    // MARK: - Buffering is not stopped

    func testStaysPlayingWhileTheTrackIsStillBuffering() async {
        await harness.startPlaying(Fixtures.track("a"))
        XCTAssertEqual(harness.engine.state, .buffering, "Precondition: the player buffers first")

        // The periodic observer fires during buffering — this is what used to undo it.
        harness.engine.tick(to: 0)
        await harness.drain()

        XCTAssertTrue(harness.player.isPlaying, "The button must not flip to 'play' while the track is starting")
        XCTAssertEqual(harness.nowPlaying.latest?.rate, 1, "and the lock screen must agree")
    }

    func testStaysPlayingAcrossSeveralBufferingTicks() async {
        await harness.startPlaying(Fixtures.track("a"))
        for _ in 0..<6 { harness.engine.tick(to: 0) }
        await harness.drain()

        XCTAssertTrue(harness.player.isPlaying)
    }

    func testStaysPlayingOnceAudioActuallyStarts() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.finishBuffering()
        harness.engine.tick(to: 1)
        await harness.drain()

        XCTAssertTrue(harness.player.isPlaying)
        XCTAssertEqual(harness.nowPlaying.latest?.rate, 1)
    }

    /// Re-buffering mid-track (a lift, a tunnel) is not the user pausing.
    func testStaysPlayingWhenItRebuffersMidTrack() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.finishBuffering()
        harness.engine.tick(to: 30)

        harness.engine.play() // back to .buffering, as AVPlayer does when it stalls
        harness.engine.tick(to: 30)
        await harness.drain()

        XCTAssertTrue(harness.player.isPlaying, "A stall is not a pause")
    }

    // MARK: - One press is one action

    /// The headline symptom: pressing pause while the track is still buffering must pause
    /// it, not "resume" something the app wrongly believed was stopped.
    func testOnePressPausesWhileBuffering() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 0)
        harness.engine.clearEvents()

        harness.player.togglePlayPause()

        XCTAssertFalse(harness.player.isPlaying, "One press should have paused it")
        XCTAssertTrue(harness.engine.events.contains(.pause))
        XCTAssertEqual(harness.nowPlaying.latest?.rate, 0)
    }

    func testOneLockScreenPressPausesWhileBuffering() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 0)
        harness.engine.clearEvents()

        harness.commands.fire(.pause)

        XCTAssertFalse(harness.player.isPlaying, "The lock screen needed two presses to pause")
        XCTAssertTrue(harness.engine.events.contains(.pause))
    }

    func testOneAirPodsTapPausesWhileBuffering() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 0)
        harness.engine.clearEvents()

        harness.commands.fire(.togglePlayPause)

        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertTrue(harness.engine.events.contains(.pause))
    }

    /// Press play, press pause, press play again — each press does exactly one thing.
    func testAlternatingPressesNeverDesynchronise() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.finishBuffering()

        for expected in [false, true, false, true] {
            harness.player.togglePlayPause()
            // A tick lands between presses in real use.
            harness.engine.tick(to: 5)
            await harness.drain(3)
            XCTAssertEqual(harness.player.isPlaying, expected)
            XCTAssertEqual(harness.nowPlaying.latest?.rate, expected ? 1 : 0)
            if expected { harness.engine.finishBuffering() }
        }
    }

    // MARK: - Genuine stops are still noticed

    /// The reconcile still has to do its job: a player that really stopped must be
    /// reflected, or the AirPods-disconnect fix regresses.
    func testAGenuineStopIsStillReflected() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.finishBuffering()
        harness.engine.tick(to: 10)
        XCTAssertTrue(harness.player.isPlaying)

        harness.engine.stopBehindOurBack()
        harness.engine.tick(to: 10)
        await harness.settle { !self.harness.player.isPlaying }

        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertEqual(harness.nowPlaying.latest?.rate, 0)
    }

    func testStartingATrackReportsPlayingImmediately() async {
        await harness.startPlaying(Fixtures.track("a"))

        XCTAssertTrue(harness.player.isPlaying, "Tapping a song should show the pause icon straight away")
        XCTAssertEqual(harness.nowPlaying.latest?.rate, 1)
    }
}

/// A stall is not a pause, and a stall that never recovers is not "still playing".
///
/// `.waitingToPlayAtSpecifiedRate` means both "filling the buffer at the start of a track"
/// and "ran dry in a tunnel". Treating the second as playing left the UI and lock screen
/// claiming playback over silence indefinitely, with a frozen scrubber and no error —
/// nothing failed, it just stopped.
@MainActor
final class StallHandlingTests: XCTestCase {
    private var harness: PlayerHarness!

    override func setUp() async throws {
        harness = PlayerHarness()
        // Short enough that the recovery branch actually runs inside a test. At the
        // production twelve seconds every assertion below fired before the task had begun,
        // so the whole suite passed regardless of what the code did.
        PlayerService.stallGrace = 0.05
    }

    override func tearDown() async throws {
        PlayerService.stallGrace = 12
    }

    /// The recovery itself: a stall that does not clear must re-resolve the stream, because
    /// nothing else ever will — the item did not fail, it stopped.
    func testAnUnrecoveredStallReResolvesTheStream() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.finishBuffering()
        let resolvesBefore = harness.streams.resolveCount["a"] ?? 0

        harness.engine.stall()
        await harness.settle { (self.harness.streams.resolveCount["a"] ?? 0) > resolvesBefore }

        XCTAssertGreaterThan(harness.streams.resolveCount["a"] ?? 0, resolvesBefore,
                             "A permanent stall left the app claiming to play over silence")
    }

    func testABriefStallDoesNotChangeTheButton() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.finishBuffering()
        harness.engine.tick(to: 20)

        harness.engine.stall()
        await harness.drain()

        XCTAssertTrue(harness.player.isPlaying, "A momentary stall shouldn't flip the button to paused")
    }

    /// The engine reports a stall, then recovers on its own before the grace period —
    /// nothing should be re-resolved.
    func testARecoveredStallIsNotTreatedAsAFailure() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.finishBuffering()
        let resolvesBefore = harness.streams.resolveCount["a"] ?? 0

        harness.engine.stall()
        harness.engine.play()          // buffer refilled
        harness.engine.finishBuffering()
        // Long enough for the recovery task to have run had it not been cancelled.
        await harness.drain(60)

        XCTAssertEqual(harness.streams.resolveCount["a"] ?? 0, resolvesBefore,
                       "A stall that recovered must not cost a re-resolve")
        XCTAssertTrue(harness.player.isPlaying)
    }

    func testStallsAreIgnoredWhileCasting() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }
        let resolvesBefore = harness.streams.resolveCount["a"] ?? 0

        harness.engine.stall()
        await harness.drain(60)

        XCTAssertEqual(harness.streams.resolveCount["a"] ?? 0, resolvesBefore,
                       "The browser is producing the sound; the phone's idle player stalling is irrelevant")
        XCTAssertTrue(harness.player.isPlaying)
    }

    func testStallsAreIgnoredWhenAlreadyPaused() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.togglePlayPause()
        let resolvesBefore = harness.streams.resolveCount["a"] ?? 0

        harness.engine.stall()
        await harness.drain(60)

        XCTAssertEqual(harness.streams.resolveCount["a"] ?? 0, resolvesBefore)
    }

    /// Starting a different track supersedes any pending stall recovery, so the recovery
    /// can't fire against a track the user has already left.
    func testANewTrackCancelsPendingStallRecovery() async {
        let queue = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(queue[0], context: queue)
        harness.engine.finishBuffering()
        harness.engine.stall()

        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" }
        await harness.drain(60)

        XCTAssertEqual(harness.player.currentTrack?.videoId, "b")
        XCTAssertTrue(harness.player.isPlaying)
        XCTAssertEqual(harness.streams.resolveCount["a"] ?? 0, 1,
                       "The cancelled recovery re-resolved a track the user had already left")
    }
}

/// The gap between asking for a track and the stream URL arriving — 1-3 seconds on a cold
/// cache. Anything the user or the system does inside that window must survive it.
///
/// `attach` used to hardcode `autoplay: true`, so a pause pressed during the gap was
/// silently undone when the URL landed and the music started by itself. The device-switch
/// path had already been fixed for exactly this; every ordinary track change had not.
@MainActor
final class LoadWindowIntentTests: XCTestCase {
    private var harness: PlayerHarness!

    override func setUp() async throws {
        harness = PlayerHarness()
    }

    /// Begin a load, then pause before the URL resolves.
    private func startSuspendedLoad() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.streams.isSuspended = true
        harness.player.play(track: Fixtures.track("b"))
        await harness.drain()
    }

    func testPausingDuringTheLoadWindowIsHonoured() async {
        await startSuspendedLoad()

        harness.player.togglePlayPause()
        XCTAssertFalse(harness.player.isPlaying)

        harness.streams.release()
        await harness.settle { !self.harness.player.isLoading }

        XCTAssertFalse(harness.player.isPlaying, "The pause was undone when the URL arrived")
        XCTAssertFalse(harness.engine.didPlayAfterLastAttach)
    }

    /// Taking AirPods out during the window must not end with the phone playing out loud.
    func testLosingTheRouteDuringTheLoadWindowKeepsItQuiet() async {
        await startSuspendedLoad()

        harness.disconnectAirPods()
        await harness.settle { !self.harness.player.isPlaying }

        harness.streams.release()
        await harness.settle { !self.harness.player.isLoading }

        XCTAssertFalse(harness.player.isPlaying, "This is the phone's loudspeaker blaring in a quiet room")
        XCTAssertFalse(harness.engine.didPlayAfterLastAttach)
    }

    func testAnInterruptionDuringTheLoadWindowKeepsItQuiet() async {
        await startSuspendedLoad()

        harness.beginInterruption()
        await harness.drain()

        harness.streams.release()
        await harness.settle { !self.harness.player.isLoading }

        XCTAssertFalse(harness.engine.didPlayAfterLastAttach, "Playing over a phone call")
    }

    /// The ordinary case still has to work: nothing intervened, so it plays.
    func testAnUninterruptedLoadStillPlays() async {
        await startSuspendedLoad()

        harness.streams.release()
        await harness.settle { !self.harness.player.isLoading }

        XCTAssertTrue(harness.player.isPlaying)
        XCTAssertTrue(harness.engine.didPlayAfterLastAttach)
    }

    /// The outgoing track must be silenced immediately, not left audible under the new
    /// title for the length of the resolve.
    func testTheOutgoingTrackIsSilencedImmediately() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.finishBuffering()
        harness.streams.isSuspended = true
        harness.engine.clearEvents()

        harness.player.play(track: Fixtures.track("b"))
        await harness.drain()

        XCTAssertTrue(harness.engine.events.contains(.pause), "The previous song kept playing under the new one")
    }

    /// And its clock must not be attributed to the incoming track.
    func testTheOutgoingClockIsNotCreditedToTheNewTrack() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.finishBuffering()
        harness.streams.isSuspended = true

        harness.player.play(track: Fixtures.track("b", durationSeconds: 200))
        await harness.drain()
        harness.engine.tick(to: 137) // the old item's position

        XCTAssertEqual(harness.player.progress, 0, accuracy: 0.001,
                       "The new track showed the old one's elapsed time")
        harness.streams.release()
        await harness.settle { !self.harness.player.isLoading }
    }
}

/// The media daemon restarting leaves every AVFoundation object inert — including the
/// player itself, so replacing its item recovers nothing.
@MainActor
final class MediaServicesResetTests: XCTestCase {
    func testResetRebuildsThePlayerRatherThanReusingIt() async {
        let harness = PlayerHarness()
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.finishBuffering()
        harness.engine.tick(to: 25)

        harness.resetMediaServices()
        await harness.settle { harness.engine.rebuildCount > 0 }

        XCTAssertEqual(harness.engine.rebuildCount, 1, "A dead AVPlayer has to be discarded, not reused")
        XCTAssertTrue(harness.engine.events.contains(.seek(25)), "and playback resumed where it was")
    }
}
