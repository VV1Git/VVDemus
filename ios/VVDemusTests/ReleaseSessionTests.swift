import XCTest
@testable import VVDemus

/// Giving the session up because the paired device has taken it over.
///
/// Not a pause, and that distinction is the whole bug it fixes: a paused device still holds a
/// track and a queue, and two devices that both hold one is precisely the state in which neither
/// can be told it is mirroring — so handing playback over used to be a one-way trip that left the
/// two permanently unable to drive each other.
///
/// The harness is `SessionOwnerHarness` from `PeerRelayTests.swift`, which is the same
/// `PlayerService`-on-fakes as everywhere else with a `SpySessionOwner` in place of
/// `PeerPlayback`.
@MainActor
final class ReleaseSessionTests: XCTestCase {
    // MARK: - The seconds already listened to

    /// The outgoing track is credited before it is forgotten, which is why the call is ordered
    /// first in the method.
    ///
    /// Stats are otherwise recorded only when one track replaces another, and the track handed to
    /// the paired device is never replaced here — it is dropped. The recording is guarded on both
    /// `currentTrack` and a non-zero `progress`, and this method clears both, so an entry existing
    /// at all is what proves the ordering: run last, it would silently credit nothing and the
    /// minutes listened to before a handoff would simply vanish.
    func testCreditsTheOutgoingTracksSecondsBeforeForgettingIt() async {
        let harness = SessionOwnerHarness()
        await harness.startPlaying(PeerFixtures.track("a", duration: 200))
        harness.engine.tick(to: 47)
        XCTAssertTrue(harness.sideEffects.listening.isEmpty, "Precondition: nothing credited yet")

        harness.player.releaseSession()

        XCTAssertEqual(harness.sideEffects.listening.count, 1)
        XCTAssertEqual(harness.sideEffects.listening.first?.track.videoId, "a")
        XCTAssertEqual(harness.sideEffects.listening.first?.seconds, 47)
    }

    /// A handoff can be attempted more than once — the ack times out, the user presses again —
    /// and the same seconds must not be counted twice. They are only credited while there is
    /// still something to credit them to.
    func testCreditsTheOutgoingTrackOnlyOnce() async {
        let harness = SessionOwnerHarness()
        await harness.startPlaying(PeerFixtures.track("a", duration: 200))
        harness.engine.tick(to: 47)

        harness.player.releaseSession()
        harness.player.releaseSession()

        XCTAssertEqual(harness.sideEffects.listening.count, 1)
    }

    func testReleasingAnIdleDeviceCreditsNothing() {
        let harness = SessionOwnerHarness()

        harness.player.releaseSession()

        XCTAssertTrue(harness.sideEffects.listening.isEmpty)
        XCTAssertNil(harness.player.currentTrack)
    }

    // MARK: - Afterwards, this device holds nothing

    func testForgetsTheTrackAndEveryQueue() async {
        let harness = SessionOwnerHarness()
        let context = [PeerFixtures.track("a"), PeerFixtures.track("b"), PeerFixtures.track("c")]
        await harness.startPlaying(context[0], context: context, contextTitle: "Some Radio")
        // Somewhere to step back to, so the back stack has something in it to be cleared.
        harness.player.advance()
        await harness.settle {
            harness.player.currentTrack?.videoId == "b" && !harness.player.isLoading
        }
        harness.player.addToQueue(PeerFixtures.track("q"))
        harness.engine.tick(to: 30)
        XCTAssertTrue(harness.player.hasPrevious, "Precondition: there is a back stack to clear")

        harness.player.releaseSession()

        XCTAssertNil(harness.player.currentTrack)
        XCTAssertTrue(harness.player.manualQueue.isEmpty)
        XCTAssertTrue(harness.player.contextQueue.isEmpty)
        XCTAssertNil(harness.player.queueContextTitle)
        XCTAssertFalse(harness.player.hasPrevious, "A queue this device no longer owns has no history either")
        XCTAssertEqual(harness.player.progress, 0)
        XCTAssertEqual(harness.player.duration, 0)
        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertFalse(harness.player.isLoading)
    }

    /// Nothing is playing here, so nothing should be claiming the lock screen either. Left
    /// behind, this phone's Now Playing slot would keep offering transport for a track it no
    /// longer has, and the buttons would land on an empty player.
    func testClearsNowPlaying() async {
        let harness = SessionOwnerHarness()
        await harness.startPlaying(PeerFixtures.track("a"))
        harness.engine.tick(to: 30)
        XCTAssertEqual(harness.nowPlaying.latest?.rate, 1, "Precondition: the lock screen shows this device playing")

        harness.player.releaseSession()

        XCTAssertEqual(
            harness.nowPlaying.latest,
            NowPlayingSnapshot(title: "", artist: "", album: nil, duration: nil, elapsed: 0, rate: 0),
            "The fake records a cleared Now Playing as an empty snapshot"
        )
    }

    // MARK: - The engine is let go of, not merely stopped

    /// A paused engine still holds the item, still reports a duration, and still resumes on the
    /// next `play()` — which is exactly what must not happen on a device that has handed over.
    func testDetachesTheEngineRatherThanPausingIt() async {
        let harness = SessionOwnerHarness()
        await harness.startPlaying(PeerFixtures.track("a"))
        harness.engine.clearEvents()

        harness.player.releaseSession()

        XCTAssertEqual(harness.engine.events, [.detach], "A pause leaves the item loaded and the player armed")
        XCTAssertNil(harness.engine.attachedURL, "Something is still loaded for a stray play() to pick up")
    }

    /// The behaviour that costs, if the engine were only paused: a stray press — the lock screen,
    /// an AirPods tap, the button in this app's own UI — restarting the song on the device that
    /// just gave it away, on top of the device now playing it.
    func testAReleasedDeviceStaysSilent() async {
        let harness = SessionOwnerHarness()
        await harness.startPlaying(PeerFixtures.track("a"))
        harness.player.releaseSession()
        harness.engine.clearEvents()

        harness.player.togglePlayPause()
        harness.player.setPlayback(playing: true)
        await harness.drain()

        XCTAssertEqual(harness.engine.events, [], "A device that has handed over must make no sound")
        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertNil(harness.player.currentTrack)
    }
}
