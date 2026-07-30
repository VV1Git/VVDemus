import XCTest
@testable import VVDemus

/// AVFoundation reports exactly double the real length for YouTube's audio-only MP4s, and the
/// app used to hand that straight to the scrubber.
///
/// Found by downloading a real track and comparing: a 4:00 song read as 7:59 once it was
/// played from disk. The file is not the problem — `mvhd`, `tkhd` and `mdhd` all say 239.6s,
/// as does ffprobe — but it carries a one-entry `elst` for the AAC encoder's 1600-sample
/// priming, and `AVAsset.duration` comes back having counted the whole thing twice
/// (21132208/44100 = 479.19s). It never showed while streaming, where the item's duration
/// stays indefinite behind `StreamingResourceLoader`, so it was specific to downloads.
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
}
