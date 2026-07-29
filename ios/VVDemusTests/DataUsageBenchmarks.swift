import XCTest
@testable import VVDemus

/// Measures what the app actually costs in bytes over the wire.
///
/// Opt-in, because these hit the real network and cost real data. The scheme skips this
/// class by default, so the normal suite stays offline and fast; naming it explicitly
/// overrides that:
///
/// ```
/// xcodebuild test -scheme VVDemus \
///   -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
///   -only-testing:VVDemusTests/DataUsageBenchmarks
/// ```
///
/// Numbers are printed as a table rather than asserted on: the point is to know the real
/// figures before and after a change, and response sizes move around enough that a hard
/// threshold would just be a flaky test. The few assertions here check *relative* claims
/// ("data saver is smaller than standard"), which stay true regardless of absolute size.
@MainActor
final class DataUsageBenchmarks: XCTestCase {

    private static var results: [(label: String, bytes: Int64, note: String)] = []

    override class func tearDown() {
        guard !results.isEmpty else { return }
        print("\n┌─ DATA USAGE ─────────────────────────────────────────────────────────")
        for row in results {
            let kb = String(format: "%8.1f KB", Double(row.bytes) / 1024)
            print("│ \(kb)  \(row.label)\(row.note.isEmpty ? "" : "  — \(row.note)")")
        }
        print("└──────────────────────────────────────────────────────────────────────\n")
        results = []
        super.tearDown()
    }

    /// Runs `work` and reports how many bytes crossed the network while it ran, using the
    /// app's own counter — the same instrumentation the Library screen shows the user, so
    /// these numbers are the ones they'd see.
    private func measure(
        _ label: String,
        note: String = "",
        category: NetworkByteCounter.Category? = nil,
        _ work: () async throws -> Void
    ) async -> Int64 {
        NetworkByteCounter.shared.reset()
        do {
            try await work()
        } catch {
            print("  benchmark '\(label)' failed: \(error.localizedDescription)")
            return 0
        }
        // Byte accounting lands from a URLSession delegate callback, which can trail the
        // awaited response slightly.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let bytes = category.map { NetworkByteCounter.shared.bytes[$0] ?? 0 } ?? NetworkByteCounter.shared.total
        Self.results.append((label, bytes, note))
        return bytes
    }

    private func setDataSaver(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: InnerTubeClient.dataSaverDefaultsKey)
    }

    // MARK: - Metadata requests

    /// Documents a finding rather than a saving: `limit` is applied while *parsing* an
    /// already-downloaded response, and InnerTube's search endpoint has no count parameter
    /// to ask for less. So halving the limit under Data Saver costs nothing and saves
    /// nothing — which is why the Data Saver description no longer claims it does.
    func testSearchLimitDoesNotChangeBytesOnTheWire() async {
        setDataSaver(false)
        let standard = await measure("search (limit 25)") {
            _ = try await InnerTubeClient.search(query: "daft punk", limit: 25)
        }
        setDataSaver(true)
        let saver = await measure("search (limit 12, Data Saver)") {
            _ = try await InnerTubeClient.search(query: "daft punk", limit: 12)
        }
        setDataSaver(false)

        guard standard > 0, saver > 0 else { return }
        let difference = abs(Double(standard - saver)) / Double(standard)
        XCTAssertLessThan(difference, 0.2, "A client-side limit cannot change what was downloaded")
    }

    /// Same finding as search: the radio endpoint returns a fixed page and the limit is
    /// applied to the parsed result.
    func testRadioLimitDoesNotChangeBytesOnTheWire() async {
        let full = await measure("radio (limit 50)") {
            _ = try await InnerTubeClient.radio(videoId: "5NV6Rdv1a3I", limit: 50)
        }
        let half = await measure("radio (limit 25, Data Saver)") {
            _ = try await InnerTubeClient.radio(videoId: "5NV6Rdv1a3I", limit: 25)
        }

        guard full > 0, half > 0 else { return }
        let difference = abs(Double(full - half)) / Double(full)
        XCTAssertLessThan(difference, 0.2, "A client-side limit cannot change what was downloaded")
    }

    /// Three searches fanned out concurrently — the single most expensive screen in the app.
    func testHomeFeedCost() async {
        setDataSaver(false)
        _ = await measure("home feed (3 seed searches)") {
            _ = try await InnerTubeClient.home()
        }
    }

    // MARK: - Artwork

    /// The single biggest lever: YouTube serves whatever size you ask for in the URL, so
    /// requesting a display-sized image instead of the original is nearly free to do and
    /// saves most of the bytes.
    /// Uses a *radio* thumbnail on purpose: those arrive as full-size `i.ytimg.com` images,
    /// which is the shape that actually costs something. Search results already arrive at
    /// 120px and have nothing to give back.
    func testArtworkSizeScaling() async {
        guard let tracks = try? await InnerTubeClient.radio(videoId: "5NV6Rdv1a3I", limit: 2),
              let thumbnail = tracks.first?.thumbnailUrl else {
            print("  no thumbnail available to benchmark")
            return
        }

        let original = await measure("artwork: as served (radio)", category: .image) {
            _ = try await Self.fetch(thumbnail)
        }
        let row = await measure("artwork: 56pt row @3x (168px)", category: .image) {
            _ = try await Self.fetch(RemoteImage.resizedThumbnailUrl(thumbnail, targetPixels: 168))
        }
        let medium = await measure("artwork: 120pt @3x (360px)", category: .image) {
            _ = try await Self.fetch(RemoteImage.resizedThumbnailUrl(thumbnail, targetPixels: 360))
        }

        guard original > 0, row > 0 else { return }
        XCTAssertLessThan(row, original, "A row thumbnail must not cost what the full-size image does")
        XCTAssertLessThanOrEqual(row, medium, "Smaller request, smaller response")
    }

    /// Proves the disk cache actually eliminates the second fetch — the bug where
    /// per-process hash filenames meant it never did.
    func testArtworkIsFreeOnSecondFetch() async {
        guard let tracks = try? await InnerTubeClient.search(query: "daft punk", limit: 1),
              let thumbnail = tracks.first?.thumbnailUrl else { return }
        let key = RemoteImage.resizedThumbnailUrl(thumbnail, targetPixels: 300)
        await DiskImageCache.shared.clear()

        let cold = await measure("artwork: cold (cache miss)", category: .image) {
            let data = try await Self.fetch(key)
            await DiskImageCache.shared.store(data, for: key)
        }
        let warm = await measure("artwork: warm (cache hit)", note: "must be 0", category: .image) {
            let cached = await DiskImageCache.shared.data(for: key)
            XCTAssertNotNil(cached, "The cache should have kept it")
        }

        guard cold > 0 else { return }
        XCTAssertEqual(warm, 0, "A cache hit must cost nothing")
    }

    // MARK: - Audio, the dominant cost

    /// Audio dwarfs everything else — one three-minute track outweighs a whole browsing
    /// session. Measured by asking for a single byte and reading the total size out of the
    /// `Content-Range` header, so the benchmark itself downloads nothing.
    func testAudioBitratePerFormat() async {
        // Both rows are expected to be identical today: the low-bitrate audio-only format
        // is only reachable through a client YouTube refuses, so both settings resolve to
        // the same muxed stream. Kept as two rows so the day that changes is visible here.
        for (label, saver) in [("standard", false), ("Data Saver", true)] {
            setDataSaver(saver)
            guard let stream = try? await InnerTubeClient.stream(videoId: "5NV6Rdv1a3I"),
                  let size = try? await Self.resourceSize(stream.url) else {
                print("  could not size \(label)")
                continue
            }
            Self.results.append(("audio: \(label)", size, "one full track"))

            // Extrapolated, not measured: this one track's bytes scaled up to an hour of
            // continuous playback (~16 tracks of this length). It assumes every track sits
            // at the same bitrate, which VBR AAC does not quite honour, so read it as an
            // estimate. The saving is necessarily the same percentage as the per-track
            // figure above — scaling both numbers by the same factor can't change the ratio
            // between them; only the absolute difference grows.
            let trackSeconds = 224.0 // "One More Time", 3m44s
            let perHour = Int64(Double(size) / trackSeconds * 3600)
            Self.results.append((
                "  → 1 hour of continuous listening",
                perHour,
                "estimated, ~16 tracks, audio only"
            ))
        }
        setDataSaver(false)
    }

    /// `preferredForwardBufferDuration` caps how far ahead AVFoundation reads. Left
    /// uncapped it pulls the whole file as fast as the network allows, so skipping twenty
    /// seconds in has already paid for the entire track.
    func testSkipWasteIsBoundedByTheBufferCap() async {
        setDataSaver(false)
        let standard = PlayerService.forwardBufferDuration
        setDataSaver(true)
        let saver = PlayerService.forwardBufferDuration
        setDataSaver(false)

        // ~128kbps = 16 KB/s; ~48kbps = 6 KB/s.
        Self.results.append(("skip waste ceiling: standard", Int64(standard * 16 * 1024), "\(Int(standard))s buffer"))
        Self.results.append(("skip waste ceiling: Data Saver", Int64(saver * 6 * 1024), "\(Int(saver))s buffer"))

        XCTAssertLessThan(saver, standard, "Data Saver should read less far ahead")
    }

    // MARK: - Helpers

    private static func fetch(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        let (data, _) = try await NetworkSessions.image.data(from: url)
        return data
    }

    /// Total size of a resource without downloading it: request one byte and read the
    /// total out of `Content-Range`.
    private static func resourceSize(_ urlString: String) async throws -> Int64? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let range = http.value(forHTTPHeaderField: "Content-Range"),
              let total = range.split(separator: "/").last else { return nil }
        return Int64(total)
    }
}
