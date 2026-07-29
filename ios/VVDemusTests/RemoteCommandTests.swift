import XCTest
@testable import VVDemus

/// AirPods have no transport protocol of their own — a stem press or a tap arrives as an
/// `MPRemoteCommand`. A single press is `togglePlayPause`, a double is `nextTrack`, a
/// triple is `previousTrack`. If any of them isn't registered, or a handler lies about
/// having succeeded, the earbud control simply does nothing and there is no other way for
/// the user to notice why.
@MainActor
final class RemoteCommandTests: XCTestCase {
    private var harness: PlayerHarness!

    override func setUp() async throws {
        harness = PlayerHarness()
    }

    // MARK: - Registration

    func testEveryTransportCommandIsRegistered() {
        for kind in RemoteCommandKind.allCases {
            XCTAssertTrue(
                harness.commands.registeredCommands.contains(kind),
                "\(kind.rawValue) has no handler — the corresponding control is dead"
            )
            XCTAssertEqual(harness.commands.enabled[kind], true, "\(kind.rawValue) is registered but disabled")
        }
    }

    /// While `skipForwardCommand`/`skipBackwardCommand` are enabled, the lock screen shows
    /// ±15-second buttons *instead of* next/previous track.
    func testCommandsWeDoNotImplementAreTurnedOff() {
        XCTAssertTrue(harness.commands.didDisableUnhandled)
    }

    // MARK: - AirPods gestures

    func testSinglePressTogglesPlayback() async {
        await harness.startPlaying(Fixtures.track("a"))

        XCTAssertEqual(harness.commands.fire(.togglePlayPause), .success)
        XCTAssertFalse(harness.player.isPlaying)

        XCTAssertEqual(harness.commands.fire(.togglePlayPause), .success)
        XCTAssertTrue(harness.player.isPlaying)
    }

    func testDoublePressSkipsToTheNextTrack() async {
        let queue = Fixtures.tracks(["a", "b", "c"])
        await harness.startPlaying(queue[0], context: queue)

        XCTAssertEqual(harness.commands.fire(.nextTrack), .success)
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" }

        XCTAssertEqual(harness.player.currentTrack?.videoId, "b")
        XCTAssertTrue(harness.player.isPlaying)
    }

    func testTriplePressGoesBack() async {
        let queue = Fixtures.tracks(["a", "b", "c"])
        await harness.startPlaying(queue[0], context: queue)
        harness.commands.fire(.nextTrack)
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" }

        XCTAssertEqual(harness.commands.fire(.previousTrack), .success)
        await harness.settle { self.harness.player.currentTrack?.videoId == "a" }

        XCTAssertEqual(harness.player.currentTrack?.videoId, "a")
    }

    /// Reporting `.success` for a gesture that did nothing tells the system the app
    /// handled it, so nothing else gets a chance to.
    func testGesturesOnAnIdlePlayerReportNoSuchContent() {
        XCTAssertNil(harness.player.currentTrack)
        XCTAssertEqual(harness.commands.fire(.togglePlayPause), .noSuchContent)
        XCTAssertEqual(harness.commands.fire(.nextTrack), .noSuchContent)
        XCTAssertEqual(harness.commands.fire(.previousTrack), .noSuchContent)
        XCTAssertEqual(harness.commands.fire(.play), .noSuchContent)
        XCTAssertEqual(harness.commands.fire(.pause), .noSuchContent)
    }

    // MARK: - Lock screen / Control Center

    func testPlayAndPauseAreNotSimplyToggles() async {
        await harness.startPlaying(Fixtures.track("a"))

        // Already playing: a play command must be a no-op, not a pause.
        XCTAssertEqual(harness.commands.fire(.play), .success)
        XCTAssertTrue(harness.player.isPlaying)

        XCTAssertEqual(harness.commands.fire(.pause), .success)
        XCTAssertFalse(harness.player.isPlaying)

        // Already paused: pausing again must not resume.
        XCTAssertEqual(harness.commands.fire(.pause), .success)
        XCTAssertFalse(harness.player.isPlaying)
    }

    func testScrubbingFromTheLockScreenSeeks() async {
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 200))
        harness.engine.itemDurationSeconds = 200
        harness.engine.tick(to: 10)

        XCTAssertEqual(harness.commands.fire(.changePlaybackPosition, position: 90), .success)

        XCTAssertEqual(harness.player.progress, 90, accuracy: 0.001)
        XCTAssertTrue(harness.engine.events.contains(.seek(90)))
    }

    func testScrubbingWithoutAPositionFails() async {
        await harness.startPlaying(Fixtures.track("a"))
        XCTAssertEqual(harness.commands.fire(.changePlaybackPosition, position: nil), .commandFailed)
    }

    /// A scrub while paused has to refresh the lock screen, or it keeps showing the old
    /// elapsed time until something else happens to update it.
    func testScrubbingWhilePausedUpdatesTheLockScreen() async {
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 200))
        harness.commands.fire(.togglePlayPause)

        harness.commands.fire(.changePlaybackPosition, position: 120)

        XCTAssertEqual(harness.nowPlaying.latest?.elapsed ?? -1, 120, accuracy: 0.001)
        XCTAssertEqual(harness.nowPlaying.latest?.rate, 0)
    }

    // MARK: - While casting

    /// The phone's own controls have to keep working when a browser is the one making
    /// sound; they get relayed instead of silently doing nothing.
    func testGesturesAreRelayedToTheBrowserWhileCasting() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }
        harness.engine.clearEvents()

        harness.commands.fire(.togglePlayPause)

        XCTAssertEqual(harness.relayedCommands, ["toggle"])
        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertFalse(harness.engine.events.contains(.pause), "The phone's player is already stopped; don't touch it")
    }

    func testSeekingWhileCastingIsRelayedAndNotAppliedLocally() async {
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 300))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }
        harness.engine.clearEvents()

        harness.commands.fire(.changePlaybackPosition, position: 75)

        XCTAssertEqual(harness.relayedCommands.last, "seek:75.0")
        XCTAssertEqual(harness.player.progress, 75, accuracy: 0.001)
        XCTAssertFalse(harness.engine.events.contains(.seek(75)))
    }

    func testNextTrackWhileCastingLoadsForTheBrowserNotThePhone() async {
        let queue = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(queue[0], context: queue)
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }
        harness.engine.clearEvents()

        harness.commands.fire(.nextTrack)
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" }

        XCTAssertEqual(harness.player.externalStream?.videoId, "b")
        XCTAssertFalse(
            harness.engine.events.contains { if case .replaceItem = $0 { return true }; return false },
            "The phone must not also start decoding the track"
        )
    }
}
