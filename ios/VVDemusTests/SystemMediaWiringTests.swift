import MediaPlayer
import XCTest
@testable import VVDemus

/// Exercises the *real* MediaPlayer framework objects, not the fakes.
///
/// Every other suite drives `PlayerService` through injected doubles, which proves the
/// logic behind each AirPods/Control Center command but says nothing about whether those
/// commands are actually bound to the system. A handler that is never registered, or a
/// command left disabled, is invisible to those tests and completely dead in the user's
/// hand. This suite checks the wiring itself.
@MainActor
final class SystemMediaWiringTests: XCTestCase {

    // MARK: - Remote command centre

    /// AirPods map their gestures onto these: single press → `togglePlayPause`, double →
    /// `nextTrack`, triple → `previousTrack`. A missing registration means the earbud
    /// control silently does nothing.
    func testEveryCommandAirPodsUseIsRegisteredAndEnabled() {
        let center = SystemRemoteCommandCenter.shared
        var fired: [RemoteCommandKind] = []
        for kind in RemoteCommandKind.allCases {
            center.setHandler(for: kind) { _ in
                fired.append(kind)
                return .success
            }
            center.setEnabled(true, for: kind)
        }

        let system = MPRemoteCommandCenter.shared()
        XCTAssertTrue(system.togglePlayPauseCommand.isEnabled, "AirPods single press is dead")
        XCTAssertTrue(system.nextTrackCommand.isEnabled, "AirPods double press is dead")
        XCTAssertTrue(system.previousTrackCommand.isEnabled, "AirPods triple press is dead")
        XCTAssertTrue(system.playCommand.isEnabled, "Control Center play is dead")
        XCTAssertTrue(system.pauseCommand.isEnabled, "Control Center pause is dead")
        XCTAssertTrue(system.changePlaybackPositionCommand.isEnabled, "Lock-screen scrubbing is dead")
    }

    /// While `skipForwardCommand`/`skipBackwardCommand` are enabled, the lock screen and
    /// Control Center show ±15-second buttons *instead of* next/previous track — so leaving
    /// them on costs the user the transport controls they actually want.
    func testCommandsWeDoNotImplementAreDisabled() {
        SystemRemoteCommandCenter.shared.disableUnhandledCommands()

        let system = MPRemoteCommandCenter.shared()
        XCTAssertFalse(system.skipForwardCommand.isEnabled, "±15s buttons would replace next/previous")
        XCTAssertFalse(system.skipBackwardCommand.isEnabled)
        XCTAssertFalse(system.seekForwardCommand.isEnabled)
        XCTAssertFalse(system.seekBackwardCommand.isEnabled)
        XCTAssertFalse(system.changeRepeatModeCommand.isEnabled)
        XCTAssertFalse(system.changeShuffleModeCommand.isEnabled)
    }

    /// The shared `PlayerService` is what the running app uses; this proves its init really
    /// does bind the system command centre rather than only the injected one.
    func testTheLivePlayerServiceRegistersSystemCommands() {
        _ = PlayerService.shared

        let system = MPRemoteCommandCenter.shared()
        XCTAssertTrue(system.togglePlayPauseCommand.isEnabled)
        XCTAssertTrue(system.nextTrackCommand.isEnabled)
        XCTAssertTrue(system.previousTrackCommand.isEnabled)
        XCTAssertFalse(system.skipForwardCommand.isEnabled)
    }

    // MARK: - Now Playing centre

    /// What the lock screen, Control Center, CarPlay and a paired Mac read.
    func testNowPlayingInfoReachesTheSystem() {
        let center = SystemNowPlayingCenter.shared
        center.publish(
            NowPlayingSnapshot(
                title: "Wiring Check",
                artist: "Test Artist",
                album: "Test Album",
                duration: 210,
                elapsed: 42,
                rate: 1
            ),
            artwork: nil
        )

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "Wiring Check")
        XCTAssertEqual(info?[MPMediaItemPropertyArtist] as? String, "Test Artist")
        XCTAssertEqual(info?[MPMediaItemPropertyAlbumTitle] as? String, "Test Album")
        XCTAssertEqual(info?[MPMediaItemPropertyPlaybackDuration] as? Double, 210)
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 42)
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
    }

    /// The playback *rate* is what a third-party app uses to convey play/pause on iOS.
    ///
    /// `MPNowPlayingInfoCenter.playbackState` is deliberately not set: it requires the
    /// private entitlement `com.apple.mediaremote.set-playback-state`, and every attempt was
    /// rejected at runtime with "Ignoring setPlaybackState…" — twice per button press.
    func testPlayPauseIsConveyedByTheRate() {
        let center = SystemNowPlayingCenter.shared

        center.publish(
            NowPlayingSnapshot(title: "T", artist: "A", album: nil, duration: 100, elapsed: 0, rate: 1),
            artwork: nil
        )
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)

        center.publish(
            NowPlayingSnapshot(title: "T", artist: "A", album: nil, duration: 100, elapsed: 10, rate: 0),
            artwork: nil
        )
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
    }

    func testClearingRemovesTheNowPlayingEntry() {
        let center = SystemNowPlayingCenter.shared
        center.publish(
            NowPlayingSnapshot(title: "T", artist: "A", album: nil, duration: nil, elapsed: 0, rate: 1),
            artwork: nil
        )
        center.clear()

        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }

    /// A track whose length isn't known yet must omit the key rather than publishing zero,
    /// which renders as a one-second scrubber.
    func testUnknownDurationIsOmittedRatherThanZero() {
        SystemNowPlayingCenter.shared.publish(
            NowPlayingSnapshot(title: "T", artist: "A", album: nil, duration: nil, elapsed: 0, rate: 1),
            artwork: nil
        )

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertNil(info?[MPMediaItemPropertyPlaybackDuration])
    }

    // MARK: - Audio session

    /// `.playback` is what keeps audio alive with the screen locked. `.allowBluetooth` is
    /// deliberately absent: on this category it opts into the HFP call profile, which drops
    /// AirPods to mono. A2DP is already the default.
    func testAudioSessionUsesPlaybackWithoutForcingTheCallProfile() {
        SystemAudioSession.shared.activate(casting: false)

        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playback)
        XCTAssertFalse(
            session.categoryOptions.contains(.allowBluetooth),
            "This would force mono HFP audio on AirPods"
        )
    }

    func testCastingUsesAMixingSessionSoTheRouteCanFollowTheMac() {
        SystemAudioSession.shared.activate(casting: true)

        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playback, "Still .playback, so background audio keeps working")
        XCTAssertTrue(
            session.categoryOptions.contains(.mixWithOthers),
            "Without mixing, the phone keeps claiming the route and AirPods stay stuck to it"
        )

        SystemAudioSession.shared.activate(casting: false)
    }
}
