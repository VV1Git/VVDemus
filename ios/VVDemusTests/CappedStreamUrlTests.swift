import XCTest
@testable import VVDemus

/// The runtime check that a resolved audio-only URL will serve the *whole* track.
///
/// The bug: on some devices every audio-only player client returns a URL capped to its
/// first 1 MiB. It resolves cleanly, plays about 65 seconds of itag-140 audio, and then
/// 403s — so the app played exactly one minute of every undownloaded song and broke.
/// Re-resolving cannot recover it; a freshly resolved URL is refused at the same offset.
///
/// Nothing here touches the network. `ThrottleCapDiagnostics` measures the real thing on a
/// device (and must be run on a device — the simulator borrows the Mac's networking, where
/// the cap does not happen).
final class CappedStreamUrlTests: XCTestCase {

    func testATrackLargerThanTheCapIsWorthVerifying() {
        XCTAssertTrue(
            InnerTubeClient.shouldVerifyServesWholeResource(
                contentLength: InnerTubeClient.cappedURLProbeThreshold + 1
            )
        )
    }

    func testATrackThatFitsInsideTheCapIsNotProbed() {
        // It plays to the end even on a capped URL, so a probe would spend a request to
        // learn nothing.
        XCTAssertFalse(
            InnerTubeClient.shouldVerifyServesWholeResource(
                contentLength: InnerTubeClient.cappedURLProbeThreshold - 1
            )
        )
        XCTAssertFalse(
            InnerTubeClient.shouldVerifyServesWholeResource(
                contentLength: InnerTubeClient.cappedURLProbeThreshold
            )
        )
    }

    func testAnUnknownLengthIsNotCondemnedOnAGuess() {
        // The probe needs a byte offset to aim at. Without one, play it and let the loader
        // report a real failure rather than pre-emptively paying 3-4x for muxed video.
        XCTAssertFalse(InnerTubeClient.shouldVerifyServesWholeResource(contentLength: nil))
    }

    func testTheCapThresholdMatchesTheObservedOneMebibyte() {
        // Measured on device: served 1048576 bytes, then HTTP 403 at byte 1048576.
        XCTAssertEqual(InnerTubeClient.cappedURLProbeThreshold, 1_048_576)
    }

    func testTheErrorSaysHowMuchWasActuallyServed() {
        let error = InnerTubeClient.CappedStreamURL(servedBytes: 1_048_576)
        XCTAssertEqual(error.errorDescription, "stream URL serves only its first 1048576 bytes")
    }

    /// The whole point of a distinct error type: `stream()` falls back to muxed for it,
    /// and it must not be mistaken for the credential refusal, which *is* worth retrying.
    func testACappedUrlIsNotTreatedAsATokenRefusal() {
        XCTAssertFalse(InnerTubeClient.isTokenRefusal(
            status: "OK",
            reason: InnerTubeClient.CappedStreamURL(servedBytes: 1_048_576).errorDescription ?? ""
        ))
    }
}
