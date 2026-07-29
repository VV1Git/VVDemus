import AVFoundation
import XCTest
@testable import VVDemus

/// Bluetooth headphones are the primary way this app gets listened to, and every one of
/// these cases used to be unhandled: there was no `routeChangeNotification` observer at
/// all, so `isPlaying` was pure bookkeeping that drifted out of step with the hardware the
/// moment anything happened outside the app.
@MainActor
final class AirPodsRouteTests: XCTestCase {
    private var harness: PlayerHarness!

    override func setUp() async throws {
        harness = PlayerHarness()
    }

    // MARK: - Disconnecting

    func testRemovingAirPodsPausesPlayback() async {
        harness.connectAirPods()
        await harness.startPlaying(Fixtures.track("a"))
        XCTAssertTrue(harness.player.isPlaying)

        harness.engine.clearEvents()
        harness.disconnectAirPods()
        await harness.settle { !self.harness.player.isPlaying }

        XCTAssertFalse(harness.player.isPlaying, "Pulling out AirPods must pause, not switch to the speaker")
        XCTAssertTrue(harness.engine.events.contains(.pause))
    }

    func testRemovingAirPodsUpdatesTheLockScreen() async {
        harness.connectAirPods()
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 42)

        harness.disconnectAirPods()
        await harness.settle { self.harness.nowPlaying.latest?.rate == 0 }

        let info = harness.nowPlaying.latest
        XCTAssertEqual(info?.rate, 0, "A lock screen still claiming rate 1.0 scrubs forward over silence")
        XCTAssertEqual(info?.elapsed ?? -1, 42, accuracy: 0.001)
    }

    /// The bug this really guards: with `isPlaying` stuck true after a disconnect, the
    /// next AirPods tap was interpreted as "pause", so the user had to tap twice to get
    /// their music back.
    func testSingleTapResumesAfterAirPodsReconnect() async {
        harness.connectAirPods()
        await harness.startPlaying(Fixtures.track("a"))
        harness.disconnectAirPods()
        await harness.settle { !self.harness.player.isPlaying }

        harness.connectAirPods()
        harness.engine.clearEvents()
        harness.commands.fire(.togglePlayPause)

        XCTAssertTrue(harness.player.isPlaying, "One tap should resume — not the second one")
        XCTAssertTrue(harness.engine.events.contains(.play))
    }

    func testReconnectingAirPodsDoesNotStartPlayingByItself() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.commands.fire(.togglePlayPause) // pause
        XCTAssertFalse(harness.player.isPlaying)

        harness.engine.clearEvents()
        harness.connectAirPods()
        await harness.drain()

        XCTAssertFalse(harness.player.isPlaying, "Connecting headphones must not start blasting music on its own")
        XCTAssertFalse(harness.engine.events.contains(.play))
    }

    /// Connecting has to leave the session live on the new route, or the first tap plays
    /// into a dead session and makes no sound.
    func testConnectingAirPodsReactivatesTheSession() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.session.clear()

        harness.connectAirPods()
        await harness.settle { !self.harness.session.activations.isEmpty }

        XCTAssertEqual(harness.session.activations.last, .init(casting: false))
    }

    func testRouteChangeWithNoTrackLoadedIsHarmless() async {
        harness.disconnectAirPods()
        harness.connectAirPods()
        await harness.drain()

        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertNil(harness.player.currentTrack)
    }

    func testDisconnectWhileAlreadyPausedChangesNothing() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.commands.fire(.togglePlayPause)
        XCTAssertFalse(harness.player.isPlaying)
        let publishedBefore = harness.nowPlaying.published.count

        harness.disconnectAirPods()
        await harness.drain()

        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertGreaterThanOrEqual(harness.nowPlaying.published.count, publishedBefore)
    }

    /// While a browser is producing the sound, this phone's route going away says nothing
    /// about whether the music should stop.
    func testDisconnectingAirPodsDoesNotPauseTheComputer() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }
        XCTAssertTrue(harness.player.isPlaying)

        harness.disconnectAirPods()
        await harness.drain()

        XCTAssertTrue(harness.player.isPlaying, "The computer is making the sound; the phone's route is irrelevant")
    }

    // MARK: - Reconciling with the engine

    /// A stall or any other silent stop has to show up in `isPlaying`, or the UI, the lock
    /// screen and the earbud gesture all disagree with reality.
    func testEngineStoppingOnItsOwnIsReflectedOnTheNextTick() async {
        await harness.startPlaying(Fixtures.track("a"))
        XCTAssertTrue(harness.player.isPlaying)

        harness.engine.stopBehindOurBack()
        harness.engine.tick(to: 12)
        await harness.settle { !self.harness.player.isPlaying }

        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertEqual(harness.nowPlaying.latest?.rate, 0)
    }

    func testCategoryChangeReconcilesRatherThanPausing() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.clearEvents()

        harness.postRouteChange(.categoryChange)
        await harness.drain()

        XCTAssertTrue(harness.player.isPlaying, "Another app reshaping the route shouldn't stop us")
        XCTAssertFalse(harness.engine.events.contains(.pause))
    }

    func testUnknownRouteChangeReasonIsIgnored() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.clearEvents()

        harness.postRouteChange(.unknown)
        harness.postRouteChange(.wakeFromSleep)
        await harness.drain()

        XCTAssertTrue(harness.player.isPlaying)
        XCTAssertFalse(harness.engine.events.contains(.pause))
    }

    func testMalformedRouteChangeNotificationIsIgnored() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.notifications.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: [:])
        harness.notifications.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: "not a number"]
        )
        await harness.drain()

        XCTAssertTrue(harness.player.isPlaying)
    }
}
