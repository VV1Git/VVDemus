import AVFoundation
import XCTest
@testable import VVDemus

/// Downloading, end to end, against live YouTube: resolve a stream, transfer it through the
/// real background session, accept the response, and confirm what landed on disk is audio
/// AVPlayer will actually play for as long as the track lasts.
///
/// The unit tests around downloads only ever covered the decisions — `isAcceptableDownload`,
/// `fileExtension`, the metadata reconciliation — because everything else needs a network. So
/// the one question a person actually asks ("does downloading work?") had no test that could
/// answer it, and every part specific to the *background* session (a `taskDescription`
/// round-trip, a delegate arriving on a session the app didn't create in this process) was
/// only ever exercised by hand.
///
/// Kept out of the everyday suite for the same reason as the other network tests — it costs
/// real bytes and depends on YouTube being up — and listed in `project.yml`'s skip list
/// accordingly. Run it deliberately:
///
///     xcodebuild test -scheme VVDemus-Benchmarks \
///       -only-testing:VVDemusTests/DownloadIntegrationTests ...
///
/// It writes into the real download library and cleans up after itself in `tearDown`,
/// including on failure.
@MainActor
final class DownloadIntegrationTests: XCTestCase {
    /// Recorded so teardown can remove the file even when an assertion fails partway through.
    private var downloaded: Track?

    override func tearDown() async throws {
        if let downloaded {
            DownloadManager.shared.remove(downloaded)
        }
        downloaded = nil
        DownloadManager.shared.errorMessage = nil
    }

    func testDownloadingARealTrackLandsPlayableAudioOnDisk() async throws {
        let manager = DownloadManager.shared
        manager.errorMessage = nil

        // Found by search rather than a hardcoded videoId, which rots without warning and
        // fails as "downloading is broken".
        let results = try await APIClient.shared.search("Pumped Up Kicks Foster The People", limit: 5)
        let track = try XCTUnwrap(results.first, "Search returned nothing — is YouTube reachable?")
        downloaded = track

        // A leftover copy from a previous run would make every assertion below pass without
        // downloading anything at all.
        manager.remove(track)
        XCTAssertFalse(manager.isDownloaded(track), "Precondition: the track must not already be on disk")

        manager.download(track)
        XCTAssertTrue(manager.isDownloading(track), "The row has to show progress the moment it's tapped")

        let settled = await poll(timeout: 180) {
            manager.isDownloaded(track) || manager.errorMessage != nil
        }
        XCTAssertTrue(settled, "Download neither finished nor failed within 180s")
        XCTAssertNil(manager.errorMessage, "Download reported an error: \(manager.errorMessage ?? "")")
        XCTAssertTrue(manager.isDownloaded(track), "Finished download never made it into the library")
        // The spinner is what `download()` keys "already in flight" off, so a progress entry
        // left behind after completion means the track can never be re-downloaded.
        XCTAssertFalse(manager.isDownloading(track), "Progress entry must be cleared once finished")

        let fileURL = try XCTUnwrap(manager.localFileURL(for: track), "No file recorded for a finished download")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = try XCTUnwrap((attributes[.size] as? NSNumber)?.int64Value)
        XCTAssertGreaterThan(size, 16 * 1024, "Too small to be audio — an error document?")

        // What a size check cannot tell you: that the bytes are decodable audio rather than a
        // few hundred kilobytes of XML or a half-written file. This is the assertion that
        // makes the test worth having, and the failure it guards against is the nasty one —
        // a track that reports itself downloaded, plays from disk, and fails every time.
        let asset = AVURLAsset(url: fileURL)
        let isPlayable = try await asset.load(.isPlayable)
        XCTAssertTrue(isPlayable, "Downloaded file is not playable audio")

        // Deliberately *not* compared against the track's stated length. AVFoundation reports
        // exactly double for these files — the edit-list bug documented on
        // `PlayerService.reconciledDuration`, which this test is how we found — so asserting
        // equality here would be asserting the bug. What matters for "did the whole file
        // arrive" is the byte count above, which is checked against `expectedContentLength`.
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 60, "Suspiciously short for a song")

        // The scrubber's number, which is the one the user sees, must match the track.
        if let expected = track.durationSeconds {
            let reconciled = PlayerService.reconciledDuration(
                itemDuration: duration.seconds,
                metadataSeconds: expected
            )
            XCTAssertEqual(
                try XCTUnwrap(reconciled),
                Double(expected),
                accuracy: PlayerService.durationAgreementMargin,
                "A downloaded track would play with the wrong length on the scrubber"
            )
        }

        // The route Connect serves offline playback from, which only has a videoId to go on.
        XCTAssertNotNil(manager.localFileURL(forVideoId: track.videoId))
    }

    /// Deleting a download while it is still in flight has to both stop the transfer and
    /// leave nothing behind — the case where the file used to arrive minutes later and put
    /// the track back in a library the user had already removed it from.
    func testCancellingAnInFlightDownloadLeavesNothingBehind() async throws {
        let manager = DownloadManager.shared
        manager.errorMessage = nil

        let results = try await APIClient.shared.search("Digital Love Daft Punk", limit: 5)
        let track = try XCTUnwrap(results.first, "Search returned nothing — is YouTube reachable?")
        downloaded = track

        manager.download(track)
        XCTAssertTrue(manager.isDownloading(track))

        manager.cancel(track)
        XCTAssertFalse(manager.isDownloading(track), "Cancelling must clear the spinner")

        // Long enough that a transfer left running would have finished and written the file.
        let reappeared = await poll(timeout: 25) { manager.isDownloaded(track) }
        XCTAssertFalse(reappeared, "A cancelled download completed anyway and re-added the track")
        XCTAssertNil(manager.localFileURL(forVideoId: track.videoId), "Cancelled download left a file on disk")
        // A cancel is the user's own doing, not a failure to report at them.
        XCTAssertNil(manager.errorMessage, "Cancelling reported an error: \(manager.errorMessage ?? "")")
    }

    /// Polls rather than using an expectation: the conditions worth waiting on here are
    /// `@Published` properties on a main-actor singleton, and a KVO-free check keeps the test
    /// readable at the cost of a quarter-second of latency nobody is measuring.
    private func poll(timeout: TimeInterval, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return condition()
    }
}
