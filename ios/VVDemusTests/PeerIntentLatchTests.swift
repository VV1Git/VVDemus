import XCTest
@testable import VVDemus

/// What a press on a mirror turns into before it leaves the device.
///
/// The mirror's own `PlayerService` is empty — no `currentTrack`, no queue, `isPlaying` false —
/// and that emptiness is what every transport method has to be written around. Two things follow,
/// and both are load-bearing:
///
/// 1. The relay has to come *before* each method's own guard. `togglePlayPause` and `setPlayback`
///    both bail on `currentTrack == nil`, which on a mirror is always. Put the relay second and
///    every button on the mirroring device is dead, silently, with nothing in the log.
/// 2. Anything the empty player cannot answer has to travel unresolved. Negating `isPlaying` here
///    yields "play" every single time, and `advance()` has no current videoId to name — only the
///    relay knows what is actually on screen, so only the relay can turn those into the absolute
///    instruction that goes on the wire.
///
/// **What is not covered here, and why.** The play-intent latch itself — `pendingPlayIntent`, its
/// 5s expiry and its single retry at 2.5s, consumed by `displayedIsPlaying` — is not reachable
/// from a test. It is armed inside `PeerPlayback.command(for:)`, which `relay` only reaches while
/// `isMirroring`; that is computed from `isPeerReachable`, which is `private(set)` and is raised
/// only by a successful `PeerClient.peerState()` against a real paired device. Its timing
/// constants are `private static`, so they cannot be shortened either, and firing the retry would
/// mean a real 2.5-second sleep in the suite. There is no honest test of it short of a refactor;
/// see the report accompanying this file. What is asserted below is everything up to the latch's
/// door: that the press gets there, and that it arrives in the shape the latch records.
@MainActor
final class PeerIntentLatchTests: XCTestCase {
    private var mirror: MirroringDevice!

    override func setUp() async throws {
        mirror = MirroringDevice()
    }

    override func tearDown() async throws {
        mirror = nil
    }

    /// The press that would be swallowed twice over: once by the `currentTrack == nil` guard if
    /// the relay came second, and once by the empty player's `isPlaying` if the toggle were
    /// resolved here.
    func testAToggleOnAnEmptyMirrorReachesTheOwnerStillAToggle() {
        mirror.player.togglePlayPause()

        XCTAssertEqual(
            mirror.owner.relayed, [.togglePlaying],
            "A toggle resolved against this device's empty player sends play forever"
        )
        XCTAssertTrue(
            mirror.engine.events.isEmpty,
            "A mirror makes no sound; a press that touches the local engine is a second session"
        )
    }

    /// The same shape for skipping. `advance()` names the track the press was made against so the
    /// owner can ignore a next it has already handled — and on a mirror that name is nil, to be
    /// filled in by the relay from what is on screen.
    func testSkippingOnAnEmptyMirrorReachesTheOwnerWithNoTrackToName() {
        mirror.player.advance()
        mirror.player.previous()

        XCTAssertEqual(mirror.owner.relayed, [.next(from: nil), .previous])
        XCTAssertTrue(mirror.engine.events.isEmpty)
    }

    /// What the lock screen's separate Play and Pause buttons send, and what the latch records
    /// verbatim: absolute, both ways, from a device whose own player is paused and empty.
    ///
    /// A command crossing a network can arrive twice or arrive after the owner has already moved.
    /// Absolute, both cases settle on the same answer; folded into a toggle, the second copy flips
    /// playback back.
    func testPlayAndPauseCrossTheWireAsThemselves() {
        mirror.player.setPlayback(playing: true)
        mirror.player.setPlayback(playing: false)

        XCTAssertEqual(mirror.owner.relayed, [.setPlaying(true), .setPlaying(false)])
    }

    /// The other half of the same guard: with nobody to relay to, every press must act here.
    /// `relay` returning false is what makes the unpaired app — which is most installs, most of
    /// the time — behave as though none of this existed.
    func testWithNoOwnerToRelayToThePressActsLocally() async {
        mirror.owner.isMirroring = false
        await mirror.startPlaying(Fixtures.track("a"))
        // Cleared so what follows is only what the press did — starting a track pauses the
        // outgoing item on its way through `beginLoad`.
        mirror.engine.clearEvents()

        mirror.player.togglePlayPause()

        XCTAssertTrue(mirror.owner.relayed.isEmpty, "Nothing should have gone to a peer")
        XCTAssertFalse(mirror.player.isPlaying)
        XCTAssertEqual(mirror.engine.events, [.pause], "The press never reached the player")
    }
}

/// A `PlayerService` in the state a mirroring device's player is actually in: wired to fakes,
/// holding nothing, with every intent bound for the device that owns the session.
///
/// Separate from `PlayerHarness` only because that one does not take a `sessionOwner` — everything
/// else here is the same fakes assembled the same way.
@MainActor
private final class MirroringDevice {
    let owner = SpySessionOwner()
    let engine = FakePlaybackEngine()
    let streams = FakeStreamResolver()
    let player: PlayerService

    /// Private to this instance for the reason `PlayerHarness`'s is: volume is persisted, and a
    /// test must neither read the developer's own level nor leave one behind in the app's real
    /// defaults.
    private let suiteName: String

    init() {
        suiteName = "VVDemusTests-\(UUID().uuidString)"
        player = PlayerService(
            engine: engine,
            session: FakeAudioSession(),
            commandCenter: FakeRemoteCommandCenter(),
            nowPlaying: FakeNowPlayingCenter(),
            streams: streams,
            downloads: FakeDownloads(),
            sideEffects: FakeSideEffects(),
            radios: FakeRadioFetcher(),
            notifications: NotificationCenter(),
            sessionOwner: owner,
            defaults: UserDefaults(suiteName: suiteName)!
        )
        owner.isMirroring = true
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    /// Starts a track and waits for the attach, the way `PlayerHarness.startPlaying` does — the
    /// resolve is asynchronous, so nothing is settled by the time `play` returns.
    func startPlaying(_ track: Track) async {
        player.play(track: track)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if player.currentTrack?.videoId == track.videoId, !player.isLoading { return }
            await Task.yield()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTFail("Timed out starting \(track.videoId)")
    }
}
