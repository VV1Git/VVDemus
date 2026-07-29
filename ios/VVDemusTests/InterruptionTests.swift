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
}
