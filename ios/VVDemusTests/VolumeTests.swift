import XCTest
@testable import VVDemus

/// The in-app volume trim: an attenuation under the system volume, kept per playback
/// device so the phone and a casting browser each keep the level they were left at.
///
/// The behaviour worth protecting here is mostly about *not* producing a surprise: a fresh
/// install must not start silent, a device switch must not carry the other device's level
/// across, and nothing that happens while casting may quietly change what the phone comes
/// back at.
@MainActor
final class VolumeTests: XCTestCase {
    // MARK: - Defaults and restoration

    func testFreshInstallPlaysAtFullVolume() {
        let harness = PlayerHarness()

        XCTAssertEqual(harness.player.volume, 1)
        XCTAssertEqual(harness.engine.volume, 1, "The engine must not start attenuated")
    }

    /// The bug this guards: reading an absent key with `double(forKey:)` returns 0.0, and
    /// 0.0 is silence — every fresh install would have started muted with a slider that
    /// looked as if it were at the bottom for a reason.
    func testAbsentStoredLevelIsFullVolumeAndNotSilence() {
        let harness = PlayerHarness()

        XCTAssertNotEqual(harness.player.volume, 0)
        XCTAssertEqual(harness.player.volume, 1)
    }

    func testRestoresTheStoredLevelForEachDeviceOnLaunch() {
        let harness = PlayerHarness(storedVolumes: [.iphone: 0.4, .computer: 0.75])

        XCTAssertEqual(harness.player.volume, 0.4, "The phone is the active device at launch")
        XCTAssertEqual(harness.engine.volume, 0.4)

        harness.player.setActiveDevice(.computer)
        XCTAssertEqual(harness.player.volume, 0.75)
    }

    /// A corrupt or hand-edited default is a reason to play normally, not to play silently.
    func testRepairsAnOutOfRangeStoredLevel() {
        XCTAssertEqual(PlayerHarness(storedVolumes: [.iphone: 4.2]).player.volume, 1)
        XCTAssertEqual(PlayerHarness(storedVolumes: [.iphone: -3]).player.volume, 0)
        XCTAssertEqual(PlayerHarness(storedVolumes: [.iphone: .nan]).player.volume, 1)
    }

    // MARK: - Setting

    func testSettingTheLevelAppliesItToTheEngineAndPersistsIt() {
        let harness = PlayerHarness()

        harness.player.setVolume(0.3)

        XCTAssertEqual(harness.player.volume, 0.3)
        XCTAssertEqual(harness.engine.volume, 0.3)
        XCTAssertEqual(
            harness.defaults.object(forKey: PlayerService.volumeDefaultsKey(for: .iphone)) as? Double,
            0.3
        )
    }

    func testClampsWhateverItIsGiven() {
        let harness = PlayerHarness()

        harness.player.setVolume(9)
        XCTAssertEqual(harness.player.volume, 1)

        harness.player.setVolume(-1)
        XCTAssertEqual(harness.player.volume, 0)

        harness.player.setVolume(.infinity)
        XCTAssertEqual(harness.player.volume, 1, "A non-finite value must not mute playback")
    }

    func testTheLevelSurvivesARelaunch() {
        let harness = PlayerHarness()
        harness.player.setVolume(0.25)

        let relaunched = PlayerService(
            engine: FakePlaybackEngine(),
            session: FakeAudioSession(),
            commandCenter: FakeRemoteCommandCenter(),
            nowPlaying: FakeNowPlayingCenter(),
            streams: FakeStreamResolver(),
            downloads: FakeDownloads(),
            sideEffects: FakeSideEffects(),
            radios: FakeRadioFetcher(),
            notifications: NotificationCenter(),
            defaults: harness.defaults
        )

        XCTAssertEqual(relaunched.volume, 0.25)
    }

    // MARK: - One level per device

    func testEachDeviceKeepsItsOwnLevel() {
        let harness = PlayerHarness()

        harness.player.setVolume(0.2)
        harness.player.setActiveDevice(.computer)
        XCTAssertEqual(harness.player.volume, 1, "The computer has its own level, not the phone's")

        harness.player.setVolume(0.9)
        harness.player.setActiveDevice(.iphone)
        XCTAssertEqual(harness.player.volume, 0.2, "and switching back restores the phone's")
        XCTAssertEqual(harness.engine.volume, 0.2)
    }

    /// Turning the computer down from either UI must leave the phone's own level alone —
    /// otherwise handing playback back produces a volume the user never chose for it.
    func testAdjustingTheComputerDoesNotTouchThePhonesLevel() {
        let harness = PlayerHarness()
        harness.player.setVolume(0.6)

        harness.player.setActiveDevice(.computer)
        harness.player.setVolume(0.1)

        XCTAssertEqual(harness.engine.volume, 0.6, "The paused AVPlayer keeps the level it will resume at")
        XCTAssertEqual(
            harness.defaults.object(forKey: PlayerService.volumeDefaultsKey(for: .iphone)) as? Double,
            0.6
        )
        XCTAssertEqual(
            harness.defaults.object(forKey: PlayerService.volumeDefaultsKey(for: .computer)) as? Double,
            0.1
        )

        harness.player.setActiveDevice(.iphone)
        XCTAssertEqual(harness.player.volume, 0.6)
        XCTAssertEqual(harness.engine.volume, 0.6)
    }

    // MARK: - Playback

    func testTheLevelIsUnaffectedByPlayingTracks() async {
        let harness = PlayerHarness()
        harness.player.setVolume(0.35)

        await harness.startPlaying(Fixtures.track("a"))
        await harness.startPlaying(Fixtures.track("b"))

        XCTAssertEqual(harness.engine.volume, 0.35, "A new item must not reset the level")
    }

    /// A media-services reset replaces the underlying player, which comes back at full
    /// volume. Nothing about that is the user asking to be blasted mid-song.
    func testTheLevelSurvivesAMediaServicesReset() async {
        let harness = PlayerHarness()
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setVolume(0.15)

        harness.resetMediaServices()
        await harness.settle { harness.engine.rebuildCount > 0 }

        XCTAssertEqual(harness.engine.volume, 0.15)
    }
}
