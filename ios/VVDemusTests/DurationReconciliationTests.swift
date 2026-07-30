import XCTest
@testable import VVDemus

/// AVFoundation reports exactly double the real length for YouTube's audio-only MP4s, and the
/// app used to hand that straight to the scrubber.
///
/// Found by downloading a real track and comparing: a 4:00 song read as 7:59 once it was
/// played from disk. The file is not the problem — `mvhd`, `tkhd` and `mdhd` all say 239.6s,
/// as does ffprobe — but it carries a one-entry `elst` for the AAC encoder's 1600-sample
/// priming, and `AVAsset.duration` comes back having counted the whole thing twice
/// (21132208/44100 = 479.19s).
///
/// It was believed to be specific to downloads, on the grounds that a streamed item's duration
/// stayed indefinite behind `StreamingResourceLoader`. That is no longer true, and the comment
/// saying so hid the more serious half of this bug for months: the loader has to report a real
/// `contentLength` from `Content-Range` or the asset never opens, so streamed items now inherit
/// the doubled duration too. Correcting the scrubber was never enough — the player kept running
/// on the doubled timeline and the queue advances only when the engine says the item finished,
/// so every streamed track sat in silence for its own length again before moving on. Measured
/// on a real device: a 321s track advanced at 640.7s.
final class DurationReconciliationTests: XCTestCase {

    /// The bug, in the numbers it was actually found with.
    func testDoubledItemDurationLosesToTheStatedLength() {
        XCTAssertEqual(
            PlayerService.reconciledDuration(itemDuration: 479.1883900226757, metadataSeconds: 240),
            240
        )
    }

    /// The item's figure is the more precise of the two when they agree, and is what kept the
    /// scrubber smooth before any of this — so agreement must not be "downgraded" to an
    /// integer.
    func testCorroboratingItemDurationIsPreferred() throws {
        let reconciled = try XCTUnwrap(
            PlayerService.reconciledDuration(itemDuration: 239.6, metadataSeconds: 240)
        )
        XCTAssertEqual(reconciled, 239.6, accuracy: 0.0001)
    }

    /// Rejecting a measurement that cannot be true is not the same as assuming YouTube is
    /// always right: with nothing to check against, the measurement stands.
    func testItemDurationIsUsedWhenThereIsNoMetadata() throws {
        let reconciled = try XCTUnwrap(
            PlayerService.reconciledDuration(itemDuration: 300, metadataSeconds: nil)
        )
        XCTAssertEqual(reconciled, 300, accuracy: 0.0001)
        // A zero or negative stated length is no metadata at all, not a zero-length track.
        XCTAssertEqual(PlayerService.reconciledDuration(itemDuration: 300, metadataSeconds: 0), 300)
    }

    /// Nil rather than 0: the caller only assigns when it gets a value, so an unusable
    /// measurement has to leave the seeded metadata duration in place rather than blanking the
    /// scrubber to 0:00.
    func testUnusableItemDurationIsRejectedOutright() {
        XCTAssertNil(PlayerService.reconciledDuration(itemDuration: .nan, metadataSeconds: 240))
        XCTAssertNil(PlayerService.reconciledDuration(itemDuration: .infinity, metadataSeconds: 240))
        XCTAssertNil(PlayerService.reconciledDuration(itemDuration: 0, metadataSeconds: 240))
        XCTAssertNil(PlayerService.reconciledDuration(itemDuration: -5, metadataSeconds: 240))
    }

    /// Just inside and just outside the margin, so the threshold can't drift unnoticed.
    func testMarginBoundary() {
        let margin = PlayerService.durationAgreementMargin
        XCTAssertEqual(
            PlayerService.reconciledDuration(itemDuration: 240 + margin - 0.1, metadataSeconds: 240),
            240 + margin - 0.1
        )
        XCTAssertEqual(
            PlayerService.reconciledDuration(itemDuration: 240 + margin + 0.1, metadataSeconds: 240),
            240
        )
    }

    /// The scrubber, end to end: a doubled item duration must not reach `duration`, because
    /// that is what `clampToTrack` bounds a seek with — a seek to what the user sees as the
    /// middle of the song landed at the end.
    @MainActor
    func testPlayerKeepsTheStatedLengthWhenTheItemReportsDouble() async {
        let harness = PlayerHarness()
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 240))

        harness.engine.itemDurationSeconds = 479.1883900226757
        harness.engine.tick(to: 1)

        XCTAssertEqual(harness.player.duration, 240, accuracy: 0.001,
                       "A doubled item duration reached the scrubber")
    }

    /// The other half of the same guard: this must not become "always ignore the engine",
    /// which would leave the scrubber pinned to YouTube's whole-second figure forever.
    @MainActor
    func testPlayerStillAdoptsAnItemDurationThatAgrees() async {
        let harness = PlayerHarness()
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 240))

        harness.engine.itemDurationSeconds = 239.6
        harness.engine.tick(to: 1)

        XCTAssertEqual(harness.player.duration, 239.6, accuracy: 0.001)
    }

    // MARK: - Ending the track when the track ends

    /// The bug in the numbers it was reproduced with: a 5:21 track whose item claimed 10:41.
    func testADoubledItemDurationIsCutBackToTheRealOne() throws {
        let end = try XCTUnwrap(
            PlayerService.trimmedPlaybackEnd(itemDuration: 640.7, metadataSeconds: 321)
        )
        XCTAssertEqual(end, 320.35, accuracy: 0.001, "The halved measurement, not the metadata")
    }

    /// A well-formed file must be played to its own end. Trimming one of these would cut every
    /// song in half, which is the one outcome worse than advancing late.
    func testAnItemThatAgreesWithItsMetadataIsNotTrimmed() {
        XCTAssertNil(PlayerService.trimmedPlaybackEnd(itemDuration: 239.6, metadataSeconds: 240))
        XCTAssertNil(PlayerService.trimmedPlaybackEnd(itemDuration: 321, metadataSeconds: 321))
    }

    /// Halving is only ever applied when halving is what reconciles the two figures. A track
    /// that genuinely runs to 10:41 and says so must not be cut to 5:20.
    func testOnlyTheDoublingIsTrimmed() {
        XCTAssertNil(PlayerService.trimmedPlaybackEnd(itemDuration: 640.7, metadataSeconds: 641))
        XCTAssertNil(PlayerService.trimmedPlaybackEnd(itemDuration: 640.7, metadataSeconds: 500))
        XCTAssertNil(PlayerService.trimmedPlaybackEnd(itemDuration: 640.7, metadataSeconds: 200))
    }

    /// With nothing to corroborate the measurement, it stands — the same principle as
    /// `reconciledDuration`, and the reason this cannot fix a track with no stated length.
    func testNothingIsTrimmedWithoutMetadataToCorroborateIt() {
        XCTAssertNil(PlayerService.trimmedPlaybackEnd(itemDuration: 640.7, metadataSeconds: nil))
        XCTAssertNil(PlayerService.trimmedPlaybackEnd(itemDuration: 640.7, metadataSeconds: 0))
        XCTAssertNil(PlayerService.trimmedPlaybackEnd(itemDuration: .nan, metadataSeconds: 321))
        XCTAssertNil(PlayerService.trimmedPlaybackEnd(itemDuration: .infinity, metadataSeconds: 321))
    }

    /// End to end: the engine must be *told* to end the item early, because that is what makes
    /// the queue advance at the real end of the audio.
    @MainActor
    func testTheEngineIsToldToEndADoubledItemAtItsRealEnd() async throws {
        let harness = PlayerHarness()
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 321))

        harness.engine.itemDurationSeconds = 640.7
        harness.engine.tick(to: 1)

        let end = try XCTUnwrap(harness.engine.forwardPlaybackEndTime,
                                "Nothing ended the item early, so the queue waits out 5 minutes of silence")
        XCTAssertEqual(end, 320.35, accuracy: 0.001)
    }

    @MainActor
    func testAWellFormedItemIsLeftToPlayToItsOwnEnd() async {
        let harness = PlayerHarness()
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 240))

        harness.engine.itemDurationSeconds = 239.6
        harness.engine.tick(to: 1)

        XCTAssertNil(harness.engine.forwardPlaybackEndTime)
    }

    /// The limit belongs to the item, not to the player: the next track gets its own decision.
    @MainActor
    func testTheLimitIsRecalculatedForEachTrack() async {
        let list = [
            Fixtures.track("doubled", durationSeconds: 321),
            Fixtures.track("honest", durationSeconds: 200),
        ]
        let harness = PlayerHarness()
        await harness.startPlaying(list[0], context: list)
        harness.engine.itemDurationSeconds = 640.7
        harness.engine.tick(to: 1)
        XCTAssertNotNil(harness.engine.forwardPlaybackEndTime)

        harness.engine.finishTrack()
        await harness.settle { harness.player.currentTrack?.videoId == "honest" && !harness.player.isLoading }
        harness.engine.itemDurationSeconds = 199.8
        harness.engine.tick(to: 1)

        XCTAssertNil(harness.engine.forwardPlaybackEndTime,
                     "The previous track's limit was left on a track that did not need one")
    }

    /// The safety net, which exists because this whole bug was one end-of-track trigger failing
    /// to fire: if playback runs past the real end regardless, that is the end of the track.
    @MainActor
    func testRunningPastTheRealEndAdvancesEvenIfTheEngineNeverReportsIt() async {
        let list = Fixtures.tracks(["a", "b"])
        let harness = PlayerHarness()
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 321), context: list)
        harness.engine.itemDurationSeconds = 640.7
        harness.engine.tick(to: 1)

        // No `finishTrack()`: the engine says nothing, exactly as it did for 320 seconds of
        // silence on the device.
        harness.engine.tick(to: 320.35 + PlayerService.playedPastEndMargin + 0.5)
        await harness.settle { (harness.player.currentTrack?.videoId ?? "a") != "a" }

        XCTAssertEqual(harness.player.currentTrack?.videoId, "b")
    }

    /// ...and it must not fire early. An ordinary overshoot between two ticks is not a missed
    /// trigger, and treating it as one would clip the last moment off every track.
    @MainActor
    func testTheSafetyNetDoesNotFireOnAnOrdinaryOvershoot() async {
        let list = Fixtures.tracks(["a", "b"])
        let harness = PlayerHarness()
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 321), context: list)
        harness.engine.itemDurationSeconds = 640.7
        harness.engine.tick(to: 1)

        harness.engine.tick(to: 320.35 + PlayerService.playedPastEndMargin - 0.2)
        await harness.drain()

        XCTAssertEqual(harness.player.currentTrack?.videoId, "a")
    }
}
