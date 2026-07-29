import XCTest
@testable import VVDemus

/// Checks that a resolved stream URL can serve the *whole* track, not just the beginning.
///
/// This is the test that was missing when playback broke. A throttled URL resolves
/// normally, returns a correct `Content-Range` with the full size, and plays the opening
/// seconds perfectly — then refuses every byte past its cap. Anything that only samples
/// the start of a file reports it as healthy. Part of the benchmark scheme; hits the
/// network.
@MainActor
final class StreamUrlRangeTests: XCTestCase {

    private let videoId = "5NV6Rdv1a3I"

    /// The whole point: a track is minutes long, so a URL that dies after the first
    /// megabyte is unusable no matter how small its nominal bitrate is.
    func testResolvedStreamServesBytesNearTheEndOfTheTrack() async throws {
        let stream = try await APIClient.shared.stream(videoId: videoId)
        let url = try XCTUnwrap(URL(string: stream.url))

        let measured = await Self.totalSize(url)
        let total = try XCTUnwrap(measured, "could not determine the resource size")
        print("\n[range] total size: \(total) bytes")
        XCTAssertGreaterThan(total, 2 * 1024 * 1024, "Track is unexpectedly small to test range access")

        // Sample across the file, including a chunk from the last 256 KB.
        for fraction in [0.0, 0.25, 0.5, 0.9] {
            let start = Int64(Double(total) * fraction)
            let end = min(start + 262_143, total - 1)
            let status = await Self.status(url, range: "bytes=\(start)-\(end)")
            print("[range] \(Int(fraction * 100))% (bytes \(start)-\(end)): HTTP \(status)")
            XCTAssertTrue(
                (200...299).contains(status),
                "Byte range at \(Int(fraction * 100))% of the track was refused (HTTP \(status)) — "
                + "this URL is throttled and cannot play a whole song"
            )
        }
    }

    /// A range beyond the end should be a clean 416, not a 403. Distinguishing the two is
    /// what tells a throttled URL apart from an ordinary end-of-file condition.
    func testRangePastTheEndIsNotSatisfiableRatherThanForbidden() async throws {
        let stream = try await APIClient.shared.stream(videoId: videoId)
        let url = try XCTUnwrap(URL(string: stream.url))
        let measured = await Self.totalSize(url)
        let total = try XCTUnwrap(measured)

        let status = await Self.status(url, range: "bytes=\(total + 1024)-\(total + 2048)")
        print("[range] past EOF: HTTP \(status)")
        XCTAssertEqual(status, 416, "Expected range-not-satisfiable past the end")
    }

    private static func totalSize(_ url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              let range = http.value(forHTTPHeaderField: "Content-Range"),
              let total = range.split(separator: "/").last else { return nil }
        return Int64(total)
    }

    private static func status(_ url: URL, range: String) async -> Int {
        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return -1 }
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }
}
