import XCTest
@testable import VVDemus

/// Two things the player got wrong about *when* it reads state: a scrub made while a
/// stream URL was still resolving, and a play pressed after the queue had run out.
@MainActor
final class LoadAndResumeTests: XCTestCase {
    private var harness: PlayerHarness!

    override func setUp() async throws {
        harness = PlayerHarness()
    }

    // MARK: - Scrubbing during a load

    /// Resolving a stream takes seconds on a cold cache and the scrubber is live the whole
    /// time. The load used to attach at 0:00 unconditionally, so the drag was thrown away
    /// and the position sprang back the moment the track started.
    func testScrubbingWhileATrackIsLoadingSurvivesTheAttach() async {
        harness.streams.isSuspended = true
        harness.player.play(track: Fixtures.track("a", durationSeconds: 180))
        await harness.drain()
        XCTAssertTrue(harness.player.isLoading, "The test needs the resolve to still be in flight")

        harness.player.seek(to: 45)
        XCTAssertEqual(harness.player.progress, 45, accuracy: 0.001)

        harness.streams.release()
        await harness.settle { !self.harness.player.isLoading }

        XCTAssertEqual(
            harness.engine.currentTimeSeconds, 45, accuracy: 0.001,
            "The player itself started at the top; the scrub never reached it"
        )
        // What the user sees: the next periodic tick reports the engine's real position, so
        // an engine left at zero drags the scrubber back to 0:00.
        harness.engine.tick(to: harness.engine.currentTimeSeconds)
        XCTAssertEqual(harness.player.progress, 45, accuracy: 0.001, "The scrubber snapped back")
    }

    /// A load with nothing scrubbed into it still starts from the top — the fix reads live
    /// progress, which `beginLoad` has already zeroed.
    func testAnUnscrubbedLoadStillStartsAtTheTop() async {
        let list = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(list[0], context: list)
        harness.engine.tick(to: 90)

        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" && !self.harness.player.isLoading }

        XCTAssertEqual(harness.player.progress, 0, accuracy: 0.001)
        XCTAssertEqual(harness.engine.currentTimeSeconds, 0, accuracy: 0.001)
    }

    /// The same read-it-late rule for the silent re-resolve after a dead stream URL: a
    /// scrub during the retry must win over the position playback died at.
    func testScrubbingDuringAFailureRetrySurvivesTheAttach() async {
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 180))
        harness.engine.itemDurationSeconds = 180
        harness.engine.tick(to: 20)

        harness.streams.isSuspended = true
        let attachesBefore = harness.engine.attachCount
        harness.engine.fail()
        await harness.drain()
        XCTAssertTrue(harness.player.isLoading, "The test needs the re-resolve to still be in flight")

        harness.player.seek(to: 120)
        // Waits for the *reattach* specifically. Waiting on the engine's clock instead is
        // useless here: the scrub above already moved it, so the condition holds before the
        // retry has done anything at all.
        harness.streams.release()
        await harness.settle { self.harness.engine.attachCount > attachesBefore }

        XCTAssertEqual(
            harness.engine.currentTimeSeconds, 120, accuracy: 0.001,
            "The retry resumed at the position playback died at, undoing the scrub"
        )
        XCTAssertEqual(harness.player.progress, 120, accuracy: 0.001)
    }

    // MARK: - Play after the queue ran out

    /// The queue ends, autoplay finds nothing, and the finished track stays loaded with the
    /// browser's `<audio>` element sitting at `ended`. Play used to flip `isPlaying` and
    /// bump only `playbackEpoch` — which app.js does not key a reload on — so the element
    /// was never reloaded and no sound ever came back.
    func testPlayAfterAFailedAutoplayReloadsTheTrackOnTheComputer() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }
        harness.player.applyExternalReport(
            epoch: harness.player.playbackEpoch, videoId: "a",
            progress: 178, duration: 180, isPlaying: true
        )

        harness.radios.failing = ["a"]
        harness.player.advance() // nothing queued; autoplay is the last resort and it fails
        await harness.settle { !self.harness.player.isPlaying }
        XCTAssertEqual(harness.player.currentTrack?.videoId, "a", "The finished track stays loaded")

        let loadEpochBefore = harness.player.trackLoadEpoch
        harness.player.togglePlayPause()

        XCTAssertTrue(harness.player.isPlaying)
        XCTAssertGreaterThan(
            harness.player.trackLoadEpoch, loadEpochBefore,
            "Only a new trackLoadEpoch makes the browser reload its ended <audio> element"
        )
        XCTAssertEqual(harness.player.progress, 0, accuracy: 0.001, "It restarts, so it restarts at the top")
    }

    /// The phone has the same problem for the same reason: an AVPlayer parked on the last
    /// frame of its item ignores `play()` until it is wound back.
    func testPlayAfterAFailedAutoplayRewindsThePhonesPlayer() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.radios.failing = ["a"]
        harness.engine.tick(to: 179)
        harness.engine.finishTrack()
        await harness.settle { !self.harness.player.isPlaying && !self.harness.player.isLoading }

        harness.engine.clearEvents()
        harness.player.togglePlayPause()

        XCTAssertTrue(harness.player.isPlaying)
        XCTAssertEqual(
            harness.engine.events, [.seek(0), .play],
            "Playing an item that has reached its end is a no-op without the rewind"
        )
    }

    /// Ordinary pause and play in the middle of a track must not be turned into a restart.
    func testAnOrdinaryResumeDoesNotRewind() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 60)
        harness.player.togglePlayPause() // pause

        harness.engine.clearEvents()
        harness.player.togglePlayPause() // play

        XCTAssertFalse(harness.engine.events.contains(.seek(0)))
        XCTAssertEqual(harness.player.progress, 60, accuracy: 0.001)
    }

    /// Scrubbing back into the finished track picks its own starting point, so the play
    /// that follows resumes from there rather than being wound back to zero.
    func testScrubbingAfterTheQueueEndsBeatsTheRestart() async {
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 180))
        harness.engine.itemDurationSeconds = 180
        harness.radios.failing = ["a"]
        harness.engine.tick(to: 179)
        harness.engine.finishTrack()
        await harness.settle { !self.harness.player.isPlaying && !self.harness.player.isLoading }

        harness.player.seek(to: 100)
        harness.engine.clearEvents()
        harness.player.togglePlayPause()

        XCTAssertEqual(harness.player.progress, 100, accuracy: 0.001)
        XCTAssertFalse(harness.engine.events.contains(.seek(0)))
    }

    /// Choosing another track clears the state, so its own pause/play behaves normally.
    func testStartingAnotherTrackClearsTheEndOfQueueRestart() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.radios.failing = ["a"]
        harness.engine.tick(to: 179)
        harness.engine.finishTrack()
        await harness.settle { !self.harness.player.isPlaying && !self.harness.player.isLoading }

        await harness.startPlaying(Fixtures.track("b"))
        harness.engine.tick(to: 30)
        harness.player.togglePlayPause() // pause
        harness.engine.clearEvents()
        harness.player.togglePlayPause() // play

        XCTAssertFalse(harness.engine.events.contains(.seek(0)))
        XCTAssertEqual(harness.player.progress, 30, accuracy: 0.001)
    }
}
