import XCTest
@testable import VVDemus

/// The one rule the download lyrics prefetch has: **a lyrics failure never fails, delays, or
/// alters the audio download.**
///
/// The spec calls this the regression test that matters most, and it is the reason
/// `DownloadManager.lyricsFetch` is a closure at all — without it the invariant is held only by
/// where one call happens to sit in `urlSession(_:downloadTask:didFinishDownloadingTo:)` and by
/// a comment saying so, neither of which can fail a build. The mutations it exists to catch:
/// counting the prefetch's bytes into `completedBytes` (which `collectionProgress` sums), letting
/// a throw escape onto `errorMessage` or the entry's state, or moving the call up among the
/// statements that publish the download.
///
/// The success branch of the delegate is only reachable with a response on the task, and
/// `URLSessionDownloadTask.response` cannot be set from outside a session — the reason
/// `DownloadProgressTests` stops at the rejected-response branch and defers the rest to
/// `DownloadIntegrationTests`, which needs a network. A subclass overriding the two properties
/// the delegate reads gets there in-process instead.
@MainActor
final class DownloadLyricsPrefetchTests: XCTestCase {
    private var manager: DownloadManager { .shared }
    private var track: Track!
    private var tempFiles: [URL] = []

    override func setUp() async throws {
        track = Fixtures.track("dllyrics-\(UUID().uuidString.prefix(8))")
        manager.errorMessage = nil
        // Same clamp `DownloadProgressTests` uses: `downloadAll` spawns a drain Task, and a
        // closed gate parks it rather than letting it resolve a stream against YouTube.
        RateLimitGate.shared.recordRateLimit(retryAfter: 5)
    }

    override func tearDown() async throws {
        // Process-global and never reset on its own, so a stub left in place would answer for
        // every later test in the suite.
        DownloadManager.lyricsFetch = { try await LyricsClient.lyrics(for: $0) }
        manager.remove(track)
        manager.cancelAll([track])
        manager.errorMessage = nil
        RateLimitGate.shared.clear()
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        track = nil
    }

    // MARK: - The regression test that matters most

    func testALyricsFailureLeavesTheDownloadSuccessfulAndTheCollectionTotalUntouched() async throws {
        let asked = Counter()
        DownloadManager.lyricsFetch = { _ in
            await asked.bump()
            throw LyricsSourceError.unreachable
        }

        manager.downloadAll([track], title: "Lyrics Mix")
        finishSuccessfully(track)

        // Published in the same main-actor turn the delegate ran in, before the prefetch has had
        // any chance to run at all: the download is complete and off the list first.
        let settled = manager.collectionProgress(for: [track])
        XCTAssertTrue(manager.isDownloaded(track))
        XCTAssertFalse(manager.isDownloading(track))
        XCTAssertNil(manager.state(for: track), "A finished download must leave no entry behind")
        XCTAssertEqual(settled.total, 1)
        XCTAssertEqual(settled.completed, 1)
        XCTAssertEqual(settled.failed, 0)
        XCTAssertEqual(settled.bytesReceived, Int64(Self.fileBytes))

        await manager.lyricsPrefetch?.value
        let asksMade = await asked.value
        XCTAssertEqual(asksMade, 1, "The prefetch never ran, so this test proves nothing")

        // The whole point: nothing about the download moved because the lyrics host was down.
        let after = manager.collectionProgress(for: [track])
        XCTAssertEqual(after.total, settled.total)
        XCTAssertEqual(after.completed, settled.completed)
        XCTAssertEqual(after.failed, 0)
        XCTAssertEqual(after.active, 0, "A prefetch is not a download and must never appear in \"N of M\"")
        XCTAssertEqual(after.bytesReceived, settled.bytesReceived, "Prefetch bytes must not be attributed to the transfer")
        XCTAssertTrue(manager.isDownloaded(track))
        XCTAssertNil(manager.state(for: track))
        XCTAssertNil(manager.errorMessage, "A lyrics host being down is not a download failure")
        XCTAssertNotNil(manager.localFileURL(for: track), "The audio has to still be on disk")
    }

    /// The other half of the same failure, and the reason it is worth telling `LyricsSourceError`
    /// apart from anything else that can be thrown here: an album downloaded in one burst is
    /// exactly what trips lrclib's rate limit, and recording every refusal as "nobody has typed
    /// these up" bought a week of silence — on the offline tracks the prefetch exists to serve,
    /// behind a placeholder with no Try Again on it.
    func testATransientLyricsFailureIsNotRecordedAsATrackWithNoLyrics() async throws {
        DownloadManager.lyricsFetch = { _ in throw LyricsSourceError.rateLimited(retryAfter: 30) }

        manager.downloadAll([track], title: "Lyrics Mix")
        finishSuccessfully(track)
        await manager.lyricsPrefetch?.value

        let cache = LyricsCacheStore.shared
        XCTAssertNil(cache.lyrics(for: track.videoId))
        XCTAssertFalse(
            cache.isMissFresh(track.videoId),
            "\"The host refused\" must not be cached as \"this track has no lyrics\""
        )
    }

    // MARK: - Helpers

    private static let fileBytes = 32 * 1024

    /// A transfer landing with a response `isAcceptableDownload` accepts — the success branch of
    /// the delegate, which is the only one that prefetches lyrics.
    private func finishSuccessfully(_ track: Track) {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? Data(count: Self.fileBytes).write(to: location)
        tempFiles.append(location)

        let response = HTTPURLResponse(
            url: URL(string: "https://stream.test/\(track.videoId).m4a")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "audio/mp4",
                "Content-Length": String(Self.fileBytes),
            ]
        )!
        manager.urlSession(
            URLSession.shared,
            downloadTask: StubDownloadTask(response: response, videoId: track.videoId),
            didFinishDownloadingTo: location
        )
    }
}

/// A finished download task carrying a response of our choosing.
///
/// `URLSessionDownloadTask.response` is read-only and only a session fills it in, so an
/// unresumed real task always looks like a rejected download. The delegate reads exactly two
/// things off the task — `taskDescription` and `response` — and overriding both is enough to
/// drive the success path without a network. `taskDescription` is overridden rather than
/// inherited because the storage behind it belongs to a task a session made.
private final class StubDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    private let stubResponse: URLResponse?
    private var stubDescription: String?

    init(response: URLResponse?, videoId: String) {
        self.stubResponse = response
        self.stubDescription = videoId
        // Deprecated, and warns, and is the point: a task with no session behind it is the only
        // way to hand the delegate a response. Nothing here is ever resumed.
        super.init()
    }

    override var response: URLResponse? { stubResponse }

    override var taskDescription: String? {
        get { stubDescription }
        set { stubDescription = newValue }
    }
}

/// Counts calls made from a closure that is not on any actor.
private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
