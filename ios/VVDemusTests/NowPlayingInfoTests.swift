import XCTest
@testable import VVDemus

/// What the lock screen, Control Center, a car display and a paired Mac show. Every one of
/// these is the only feedback the user gets while the phone is in their pocket, so a stale
/// or wrong value here is indistinguishable from the app being broken.
@MainActor
final class NowPlayingInfoTests: XCTestCase {
    private var harness: PlayerHarness!

    override func setUp() async throws {
        harness = PlayerHarness()
    }

    func testStartingATrackPublishesItsMetadata() async {
        await harness.startPlaying(Fixtures.track("a", title: "Real Song", artist: "Someone", album: "An Album"))

        let info = harness.nowPlaying.latest
        XCTAssertEqual(info?.title, "Real Song")
        XCTAssertEqual(info?.artist, "Someone")
        XCTAssertEqual(info?.album, "An Album")
        XCTAssertEqual(info?.rate, 1)
    }

    /// The scrubber is driven from elapsed time *and* rate; a rate of 1 with a frozen
    /// elapsed time makes the lock screen run forward over silence.
    func testPausingPublishesRateZero() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 20)

        harness.player.togglePlayPause()

        XCTAssertEqual(harness.nowPlaying.latest?.rate, 0)
        XCTAssertEqual(harness.nowPlaying.latest?.elapsed ?? -1, 20, accuracy: 0.001)
    }

    func testElapsedTimeTracksPlayback() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 5)
        harness.engine.tick(to: 10)

        XCTAssertEqual(harness.nowPlaying.latest?.elapsed ?? -1, 10, accuracy: 0.001)
    }

    /// Handing playback back from a computer while paused never ticks, so a duration that
    /// only ever came from the player left the scrubber a one-second stub reading 0:00.
    func testDurationIsSeededFromTheTracksOwnMetadata() async {
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 245))

        XCTAssertEqual(harness.player.duration, 245, accuracy: 0.001)
        XCTAssertEqual(harness.nowPlaying.latest?.duration ?? -1, 245, accuracy: 0.001)
    }

    func testTheRealDurationOverridesTheMetadataOnce() async {
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 245))
        harness.engine.itemDurationSeconds = 248.5
        harness.engine.tick(to: 1)

        XCTAssertEqual(harness.player.duration, 248.5, accuracy: 0.001)
    }

    func testATrackWithNoKnownDurationOmitsIt() async {
        await harness.startPlaying(Fixtures.track("a", durationSeconds: nil))

        XCTAssertNil(harness.nowPlaying.latest?.duration)
    }

    func testChangingTrackPublishesTheNewOneImmediately() async {
        let list = [Fixtures.track("a", title: "First"), Fixtures.track("b", title: "Second")]
        await harness.startPlaying(list[0], context: list)

        harness.player.advance()
        await harness.settle { self.harness.nowPlaying.latest?.title == "Second" }

        XCTAssertEqual(harness.nowPlaying.latest?.title, "Second")
        XCTAssertEqual(harness.nowPlaying.latest?.elapsed ?? -1, 0, accuracy: 0.001)
    }

    func testSeekingRefreshesTheLockScreenEvenWhilePaused() async {
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 300))
        harness.player.togglePlayPause()

        harness.player.seek(to: 150)

        XCTAssertEqual(harness.nowPlaying.latest?.elapsed ?? -1, 150, accuracy: 0.001)
        XCTAssertEqual(harness.nowPlaying.latest?.rate, 0)
    }

    /// While a browser is producing the sound, the phone still owns the lock screen — the
    /// position comes from the browser's reports.
    func testTheLockScreenFollowsTheBrowserWhileCasting() async {
        await harness.startPlaying(Fixtures.track("a", title: "Casting"))
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }

        harness.player.applyExternalReport(
            epoch: harness.player.playbackEpoch, videoId: "a", progress: 88, duration: 200, isPlaying: true
        )

        XCTAssertEqual(harness.nowPlaying.latest?.title, "Casting")
        XCTAssertEqual(harness.nowPlaying.latest?.elapsed ?? -1, 88, accuracy: 0.001)
        XCTAssertEqual(harness.nowPlaying.latest?.rate, 1)
    }

    func testTheLockScreenIsClearedWhenNothingIsLoaded() {
        XCTAssertNil(harness.player.currentTrack)
        harness.player.togglePlayPause() // no-op, but must not publish a phantom track
        XCTAssertNil(harness.nowPlaying.latest?.title.isEmpty == false ? harness.nowPlaying.latest?.title : nil)
    }

    /// The periodic tick republishes twice a second; it must not restart the artwork fetch
    /// each time, which is what starved it on any connection slower than half a second.
    func testRepeatedTicksDoNotThrashTheNowPlayingCenter() async {
        await harness.startPlaying(Fixtures.track("a"))
        let before = harness.nowPlaying.published.count

        for second in 1...5 { harness.engine.tick(to: Double(second)) }

        XCTAssertEqual(harness.nowPlaying.published.count, before + 5, "One publish per tick, no more")
    }
}
