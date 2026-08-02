import AVFoundation
import XCTest
@testable import VVDemus

/// Phone calls, alarms, Siri, and other apps taking the audio route.
///
/// None of this was handled: `PlayerService` never observed
/// `AVAudioSession.interruptionNotification`, so a call left the app showing "playing"
/// with no sound, the lock-screen scrubber running forward over silence, and a play button
/// that did nothing because `isPlaying` still said true.
@MainActor
final class InterruptionTests: XCTestCase {
    private var harness: PlayerHarness!

    override func setUp() async throws {
        harness = PlayerHarness()
    }

    func testInterruptionPausesAndReportsPaused() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 30)

        harness.beginInterruption()
        await harness.settle { !self.harness.player.isPlaying }

        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertTrue(harness.player.isInterrupted)
        XCTAssertEqual(harness.nowPlaying.latest?.rate, 0)
    }

    func testPlaybackResumesWhenTheSystemSaysItMay() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.beginInterruption()
        await harness.settle { !self.harness.player.isPlaying }
        harness.engine.clearEvents()

        harness.endInterruption(shouldResume: true)
        await harness.settle { self.harness.player.isPlaying }

        XCTAssertTrue(harness.player.isPlaying)
        XCTAssertTrue(harness.engine.events.contains(.play))
        XCTAssertEqual(harness.nowPlaying.latest?.rate, 1)
    }

    /// The session is deactivated under us during an interruption; playing into a dead
    /// session is silent while still reporting success.
    func testResumingReactivatesTheAudioSessionFirst() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.beginInterruption()
        await harness.settle { !self.harness.player.isPlaying }
        harness.session.clear()

        harness.endInterruption(shouldResume: true)
        await harness.settle { self.harness.player.isPlaying }

        XCTAssertEqual(harness.session.activations.last, .init(casting: false))
    }

    /// `.shouldResume` absent means the interrupting app still owns the route. Resuming
    /// anyway is how apps end up fighting Siri for the speaker.
    func testPlaybackStaysPausedWhenTheSystemWithholdsShouldResume() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.beginInterruption()
        await harness.settle { !self.harness.player.isPlaying }
        harness.engine.clearEvents()

        harness.endInterruption(shouldResume: false)
        await harness.drain()

        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertFalse(harness.engine.events.contains(.play))
    }

    func testAnInterruptionWhilePausedDoesNotStartPlaybackOnItsEnd() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.commands.fire(.togglePlayPause) // user paused
        XCTAssertFalse(harness.player.isPlaying)

        harness.beginInterruption()
        harness.endInterruption(shouldResume: true)
        await harness.drain()

        XCTAssertFalse(harness.player.isPlaying, "It was paused before the call; it should still be paused after")
    }

    /// A user tapping play during the call — and then the interruption ending — must not
    /// double up or get overridden.
    func testUserPressingPlayDuringAnInterruptionWins() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.beginInterruption()
        await harness.settle { !self.harness.player.isPlaying }

        harness.commands.fire(.play)
        XCTAssertTrue(harness.player.isPlaying)

        harness.endInterruption(shouldResume: false)
        await harness.drain()

        XCTAssertTrue(harness.player.isPlaying, "An explicit play shouldn't be undone by the interruption ending")
    }

    func testRepeatedInterruptionsDoNotAccumulateState() async {
        await harness.startPlaying(Fixtures.track("a"))
        for _ in 0..<3 {
            harness.beginInterruption()
            await harness.settle { !self.harness.player.isPlaying }
            harness.endInterruption(shouldResume: true)
            await harness.settle { self.harness.player.isPlaying }
        }

        XCTAssertTrue(harness.player.isPlaying)
        XCTAssertFalse(harness.player.isInterrupted)
    }

    func testInterruptionWhileCastingDoesNotTouchTheBrowser() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }
        harness.engine.clearEvents()

        harness.beginInterruption()
        harness.endInterruption(shouldResume: true)
        await harness.drain()

        XCTAssertTrue(harness.player.isPlaying, "The computer never stopped playing")
        XCTAssertFalse(harness.engine.events.contains(.play), "The phone's own player must stay out of it")
    }

    func testMalformedInterruptionNotificationIsIgnored() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.notifications.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [:])
        await harness.drain()

        XCTAssertTrue(harness.player.isPlaying)
    }

    /// The media daemon restarting leaves every AVFoundation object inert. Without
    /// rebuilding, playback is dead until the app is force-quit.
    func testMediaServicesResetRebuildsPlayback() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 25)
        harness.engine.clearEvents()

        harness.resetMediaServices()
        await harness.settle { !self.harness.engine.events.isEmpty }

        XCTAssertTrue(
            harness.engine.events.contains { if case .replaceItem = $0 { return true }; return false },
            "The player item has to be rebuilt after a media services reset"
        )
        XCTAssertTrue(harness.engine.events.contains(.seek(25)), "and resumed where it was")
        XCTAssertTrue(harness.engine.events.contains(.play))
    }

    func testMediaServicesResetWhilePausedDoesNotStartPlaying() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.commands.fire(.togglePlayPause)
        harness.engine.clearEvents()

        harness.resetMediaServices()
        await harness.drain()

        XCTAssertFalse(harness.engine.events.contains(.play))
        XCTAssertFalse(harness.player.isPlaying)
    }

    // MARK: - An interruption that never ends

    /// iOS does not promise an `.ended` for every `.began`. An interruption the app is
    /// suspended through, or an interrupting app that never gives the route back, leaves
    /// `isInterrupted` set with nothing to clear it until the next `beginLoad` — a whole
    /// track later. Pressing play does not clear it: `togglePlayPause` starts the engine and
    /// sets `isPlaying`, but never touches the interruption bookkeeping, so the app spends
    /// the rest of the track playing audibly while still believing it is interrupted.
    ///
    /// What that costs is the recovery. `attach` vetoes `shouldPlay` whenever the flag is
    /// set, so when the stream URL expires mid-track the app re-resolves it, attaches the
    /// replacement item, and then refuses to start it. The music stops dead with no error
    /// and no failed load — the only symptom is silence, and a play button that needs
    /// pressing twice.
    func testRecoveringAnExpiredUrlStillPlaysAfterAnInterruptionThatNeverEnded() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.finishBuffering()
        harness.engine.tick(to: 40)

        // A `.began` with no `.ended` behind it — ever.
        harness.beginInterruption()
        await harness.settle { !self.harness.player.isPlaying }

        harness.commands.fire(.play)
        XCTAssertTrue(harness.player.isPlaying, "Precondition: the user got their music back")
        harness.engine.finishBuffering()
        harness.engine.clearEvents()

        // Mid-track the stream URL dies. One silent re-resolve is meant to put the music
        // back exactly where it was.
        harness.engine.fail()
        await harness.settle { (self.harness.streams.resolveCount["a"] ?? 0) > 1 }
        await harness.settle { !self.harness.player.isLoading }

        XCTAssertTrue(harness.engine.didPlayAfterLastAttach,
                      "The replacement item was attached and then left silent")
        XCTAssertTrue(harness.player.isPlaying)
        XCTAssertEqual(harness.nowPlaying.latest?.rate, 1, "and the lock screen has to agree")
    }

    /// The same latch switches off the only thing that notices the engine stopping by
    /// itself: `reconcileIsPlayingWithEngine` returns early while it is set. A later dropout
    /// then leaves `isPlaying` stuck true over silence — the AirPods double-tap bug again,
    /// for the rest of the track.
    func testTheEngineStoppingIsStillNoticedAfterAnInterruptionThatNeverEnded() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.beginInterruption()
        await harness.settle { !self.harness.player.isPlaying }

        harness.commands.fire(.play)
        XCTAssertTrue(harness.player.isPlaying, "Precondition: playing again")

        harness.engine.stopBehindOurBack()
        harness.engine.tick(to: 12)
        await harness.settle { !self.harness.player.isPlaying }

        XCTAssertFalse(harness.player.isPlaying, "The button claims playback over silence")
        XCTAssertEqual(harness.nowPlaying.latest?.rate, 0)
    }
}
