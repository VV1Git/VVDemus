import XCTest
@testable import VVDemus

/// Reports what the app *actually* gets from YouTube, so bitrate and Data Saver decisions
/// rest on observed responses rather than on what the itag tables say should be there.
/// Part of the benchmark scheme; hits the network.
@MainActor
final class StreamFormatDiagnostics: XCTestCase {

    /// Goes through the app's own resolution path rather than duplicating the player
    /// request — a hand-rolled copy drifts from production and reports on something the
    /// app never actually asks for. The chosen format is read back out of the signed URL,
    /// which carries its own `itag`.
    func testWhichAudioFormatDataSaverActuallyGets() async throws {
        var chosen: [(String, Int?, Int64?)] = []
        for (label, saver) in [("standard", false), ("Data Saver", true)] {
            UserDefaults.standard.set(saver, forKey: InnerTubeClient.dataSaverDefaultsKey)
            let stream = try await InnerTubeClient.stream(videoId: "5NV6Rdv1a3I")
            chosen.append((label, Self.itag(from: stream.url), try? await Self.resourceSize(stream.url)))
        }
        UserDefaults.standard.set(false, forKey: InnerTubeClient.dataSaverDefaultsKey)

        print("\n┌─ AUDIO FORMAT ACTUALLY SERVED ───────────────────────────────────────")
        for (label, itag, size) in chosen {
            let mb = size.map { String(format: "%.2f MB", Double($0) / 1024 / 1024) } ?? "?"
            print("│ \(label.padding(toLength: 12, withPad: " ", startingAt: 0)) itag \(itag.map(String.init) ?? "?")  \(mb)")
        }
        print("└──────────────────────────────────────────────────────────────────────")

        if chosen.count == 2, chosen[0].1 == chosen[1].1 {
            print("Data Saver selects the SAME format as standard — the low-bitrate path is not taking effect.")
        }
    }

    /// Thumbnail sources differ per endpoint, which is why one "resize to N" rule can be a
    /// large saving on one screen and a no-op on another.
    func testReportThumbnailSourceSizes() async throws {
        let search = try await InnerTubeClient.search(query: "daft punk", limit: 3)
        let radio = try await InnerTubeClient.radio(videoId: "5NV6Rdv1a3I", limit: 3)

        print("\n┌─ THUMBNAIL SOURCES ──────────────────────────────────────────────────")
        for (label, tracks) in [("search", search), ("radio", radio)] {
            guard let url = tracks.first(where: { $0.thumbnailUrl != nil })?.thumbnailUrl else { continue }
            let resized = RemoteImage.resizedThumbnailUrl(url, targetPixels: 900)
            print("│ \(label) source:  \(url)")
            print("│ \(label) rewritten: \(resized == url ? "UNCHANGED — resize rule does not match this URL shape" : resized)")
            if let bytes = try? await Self.resourceSize(url) {
                print("│ \(label) size: \(String(format: "%.1f KB", Double(bytes) / 1024))")
            }
        }
        print("└──────────────────────────────────────────────────────────────────────")
    }

    private static func itag(from urlString: String) -> Int? {
        URLComponents(string: urlString)?
            .queryItems?
            .first { $0.name == "itag" }
            .flatMap { $0.value.flatMap(Int.init) }
    }

    /// Size without downloading: ask for one byte, read the total from `Content-Range`.
    private static func resourceSize(_ urlString: String) async throws -> Int64? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last, let size = Int64(total) {
            return size
        }
        return http.expectedContentLength > 0 ? http.expectedContentLength : nil
    }
}
