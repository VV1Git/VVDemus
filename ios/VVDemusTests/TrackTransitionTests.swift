import XCTest
@testable import VVDemus

/// The moment one track hands over to the next, and the transport controls immediately
/// after it.
///
/// The reported symptom: a song ends, the next one starts playing, and then the first
/// press does nothing — on the lock screen a whole pause-then-play cycle is swallowed
/// before a press finally lands. It happens on the phone's own button, on the lock screen
/// and on AirPods at once, which is the signature of `isPlaying` having drifted rather than
/// of any one control being broken: every surface reads that flag, and `.pause` is dropped
/// outright when it says false.
///
/// The drift comes from the reconcile being one-way. `AVPlayer.timeControlStatus` changes
/// asynchronously, so a periodic tick taken in the instant after `attach` calls `play()`
/// can still read `.paused` — and the periodic observer fires on exactly that instant,
/// because AVFoundation invokes it on every time jump and whenever playback starts or
/// stops, and replacing the item at a track boundary is both. One such reading used to set
/// `isPlaying = false` permanently: audio arrives a moment later, and nothing in the app
/// ever raised the flag back, because the reconcile only ever corrected a true that should
/// have been false.
@MainActor
final class TrackTransitionTests: XCTestCase {
    private var harness: PlayerHarness!

    override func setUp() async throws {
        harness = PlayerHarness()
    }

    /// Plays "a" out to its end, lets "b" attach, and then delivers the tick that catches
    /// the engine mid-instruction — reporting stopped about audio that is in fact starting.
    private func handOverToTheNextTrack() async {
        let queue = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(queue[0], context: queue)
        harness.engine.finishBuffering()
        harness.engine.tick(to: 170)

        harness.engine.finishTrack()
        await harness.settle {
            self.harness.player.currentTrack?.videoId == "b" && !self.harness.player.isLoading
        }
        XCTAssertTrue(harness.player.isPlaying, "Precondition: the new track was told to play")

        harness.engine.stopBehindOurBack()
        harness.engine.tick(to: 0)
        await harness.drain()

        // ...and the sound the instruction asked for arrives.
        harness.engine.startPlayingBehindOurBack()
        harness.engine.tick(to: 0.5)
        await harness.drain()
    }

    func testTheButtonStillMatchesAudibleMusicAfterAHandover() async {
        await handOverToTheNextTrack()

        XCTAssertTrue(harness.player.isPlaying,
                      "The play triangle was left showing over the track that had just started")
        XCTAssertEqual(harness.nowPlaying.latest?.rate, 1, "and the lock screen agreed with it")
    }

    /// The headline symptom, on the control the user reached for: the lock screen's and
    /// Control Centre's pause is a command of its own, and it used to be dropped entirely
    /// whenever `isPlaying` said the app was already stopped.
    func testOneLockScreenPressPausesAfterAHandover() async {
        await handOverToTheNextTrack()
        harness.engine.clearEvents()

        harness.commands.fire(.pause)
        await harness.drain()

        XCTAssertTrue(harness.engine.events.contains(.pause), "The press vanished — the music kept playing")
        XCTAssertFalse(harness.engine.isEnginePlaying)
        XCTAssertFalse(harness.player.isPlaying)
    }

    func testOneAirPodsTapPausesAfterAHandover() async {
        await handOverToTheNextTrack()
        harness.engine.clearEvents()

        harness.commands.fire(.togglePlayPause)
        await harness.drain()

        XCTAssertTrue(harness.engine.events.contains(.pause))
        XCTAssertFalse(harness.player.isPlaying)
    }

    func testOnePressOfTheAppsOwnButtonPausesAfterAHandover() async {
        await handOverToTheNextTrack()
        harness.engine.clearEvents()

        harness.player.togglePlayPause()
        await harness.drain()

        XCTAssertTrue(harness.engine.events.contains(.pause))
        XCTAssertFalse(harness.player.isPlaying)
    }

    /// The whole reported sequence, run as one: pause, play, pause. Each press does exactly
    /// one thing, rather than the first two being spent repairing a flag.
    func testPauseThenPlayThenPauseEachDoOneThingAfterAHandover() async {
        await handOverToTheNextTrack()

        harness.commands.fire(.pause)
        await harness.drain()
        XCTAssertFalse(harness.engine.isEnginePlaying, "First press: the music should have stopped")

        harness.commands.fire(.play)
        harness.engine.finishBuffering()
        await harness.drain()
        XCTAssertTrue(harness.engine.isEnginePlaying, "Second press: it should have started again")

        harness.commands.fire(.pause)
        await harness.drain()
        XCTAssertFalse(harness.engine.isEnginePlaying, "Third press: stopped again")
    }

    // MARK: - The safety net still has to work

    /// The reconcile exists because iOS does not always tell the app that playback stopped.
    /// Believing the engine in both directions must not cost that.
    func testAGenuineStopAfterAHandoverIsStillReported() async {
        await handOverToTheNextTrack()

        harness.engine.stopBehindOurBack()
        harness.engine.tick(to: 12)
        await harness.settle { !self.harness.player.isPlaying }

        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertEqual(harness.nowPlaying.latest?.rate, 0)
    }

    /// A pause the *user* asked for must not be undone by the reconcile deciding the engine
    /// knows better — the engine is stopped, so the two already agree.
    func testAUserPauseAfterAHandoverStays() async {
        await handOverToTheNextTrack()

        harness.player.togglePlayPause()
        for _ in 0..<4 { harness.engine.tick(to: 1) }
        await harness.drain()

        XCTAssertFalse(harness.player.isPlaying, "The pause was reverted by the periodic reconcile")
        XCTAssertFalse(harness.engine.isEnginePlaying)
    }

    // MARK: - Stopping means stopping the player, not only the flag

    /// Running out of queue writes `isPlaying = false`. If the player is left running, the
    /// app is claiming to be stopped over audio it can still hear — the same desync from the
    /// other end, and now one the reconcile would "repair" by declaring playback resumed.
    func testRunningOutOfQueueStopsThePlayerNotJustTheFlag() async {
        harness.player.autoplayEnabled = false
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.finishBuffering()
        harness.engine.tick(to: 30)

        harness.player.advance() // nothing queued, autoplay off
        await harness.drain()

        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertFalse(harness.engine.isEnginePlaying, "The queue ran out and the player was left running")
    }

    /// The mirror image inside `attach`: a load that decides not to play (a pause taken
    /// during the resolve, an interruption) has to stop the player rather than only writing
    /// the flag. `AVPlayer.replaceCurrentItem` keeps the rate it already had, so an attach
    /// that declines to play can otherwise start audio all by itself.
    func testALoadThatDeclinesToPlayLeavesThePlayerStopped() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.streams.isSuspended = true
        harness.player.play(track: Fixtures.track("b"))
        await harness.drain()

        harness.player.togglePlayPause() // pause while "b" is still resolving
        harness.streams.release()
        await harness.settle { !self.harness.player.isLoading }

        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertFalse(harness.engine.isEnginePlaying)
    }
}
