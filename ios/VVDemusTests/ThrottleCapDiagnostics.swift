import XCTest
@testable import VVDemus

/// How many bytes will a resolved URL actually serve, per player client?
///
/// `PlayerClientProbe` only checks that a client *resolves* — the first of the two gates
/// on `InnerTubeClient.audioOnlyClients`. This measures the second: whether the URL serves
/// the whole track, or plays the opening seconds and then refuses every further range.
///
/// **Run this on a device, not the simulator.** The simulator borrows the Mac's
/// networking, where these URLs are not capped — the whole reason the failure went
/// unnoticed. Measured on an iPhone (August 2026): every audio-only client that resolved
/// served exactly 1048576 bytes and then 403'd, from the same public IP where the Mac was
/// served whole files, while muxed itag 18 was uncapped on both.
///
/// Reach for it when playback dies partway through a track rather than failing to start.
/// Part of the benchmark scheme; hits the network.
@MainActor
final class ThrottleCapDiagnostics: XCTestCase {

    private let videoId = "5NV6Rdv1a3I"

    private static let clients: [InnerTubeClient.PlayerClient] = [
        InnerTubeClient.PlayerClient(
            name: "ANDROID_VR", version: "1.65.10",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            extraContext: [
                "deviceMake": "Oculus", "deviceModel": "Quest 3",
                "androidSdkVersion": 32, "osName": "Android", "osVersion": "12L",
            ]
        ),
        InnerTubeClient.PlayerClient(
            name: "ANDROID_VR", version: "1.68.36",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.68.36 (Linux; U; Android 12L; GB) gzip",
            extraContext: [
                "deviceMake": "Oculus", "deviceModel": "Quest 3",
                "androidSdkVersion": 32, "osName": "Android", "osVersion": "12L",
            ]
        ),
        InnerTubeClient.PlayerClient(
            name: "ANDROID_MUSIC", version: "7.27.52",
            userAgent: "com.google.android.apps.youtube.music/7.27.52 (Linux; U; Android 11) gzip",
            extraContext: [
                "androidSdkVersion": 30, "osName": "Android", "osVersion": "11",
            ]
        ),
        // The client behind the muxed fallback. If its *audio-only* formats are uncapped on
        // the phone, that is the fix — audio-only bytes without the 3-4x video penalty.
        InnerTubeClient.PlayerClient(
            name: "ANDROID", version: "21.02.35",
            userAgent: "com.google.android.youtube/21.02.35 (Linux; U; Android 11) gzip",
            extraContext: [
                "androidSdkVersion": 30, "osName": "Android", "osVersion": "11",
            ]
        ),
        InnerTubeClient.PlayerClient(
            name: "IOS", version: "20.10.4",
            userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X)",
            extraContext: [
                "deviceMake": "Apple", "deviceModel": "iPhone16,2",
                "osName": "iPhone", "osVersion": "18.3.2.22D82",
            ]
        ),
        InnerTubeClient.PlayerClient(
            name: "TVHTML5_SIMPLY_EMBEDDED_PLAYER", version: "2.0",
            userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
            extraContext: [:]
        ),
        InnerTubeClient.PlayerClient(
            name: "WEB_EMBEDDED_PLAYER", version: "1.20240101.00.00",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
            extraContext: [:]
        ),
    ]

    func testHowManyBytesEachClientWillActuallyServe() async throws {
        print("\n┌─ THROTTLE CAP ───────────────────────────────────────────────────────")
        // Same LAN or not? The phone and the Mac disagreeing about the same URL is only
        // explicable by the network path if the path is genuinely different.
        if let echo = URL(string: "https://api.ipify.org"),
           let (data, _) = try? await URLSession.shared.data(from: echo) {
            print("│ egress IP: \(String(data: data, encoding: .utf8) ?? "?")")
        }
        for client in Self.clients {
            let label = "\(client.name) \(client.version)"
            do {
                let resolved = try await Self.resolve(videoId: videoId, client: client)
                let walk = await Self.walk(resolved.url)
                let hasN = URLComponents(string: resolved.url)?
                    .queryItems?.contains { $0.name == "n" } ?? false
                print("│ \(label)")
                print("│    itag \(resolved.itag), total \(walk.total ?? -1) bytes, n-param: \(hasN)")
                print("│    \(walk.summary)")
            } catch {
                print("│ \(label)")
                print("│    resolve failed: \(error.localizedDescription)")
            }
        }
        print("└──────────────────────────────────────────────────────────────────────\n")
    }

    /// Does a *second*, freshly resolved URL get a fresh allowance? If it does, the cap is
    /// per-URL and re-resolving mid-track would recover playback.
    func testWhetherAFreshUrlResetsTheAllowance() async throws {
        let client = try XCTUnwrap(Self.clients.first)
        let first = try await Self.resolve(videoId: videoId, client: client)
        let firstWalk = await Self.walk(first.url)
        print("\n[fresh] first URL:  \(firstWalk.summary)")

        guard let stalledAt = firstWalk.failedAtOffset else {
            print("[fresh] first URL served the whole file — no cap to reset")
            return
        }

        let second = try await Self.resolve(videoId: videoId, client: client)
        XCTAssertNotEqual(second.url, first.url, "Expected a genuinely different URL")
        // Resume exactly where the first one died.
        let secondWalk = await Self.walk(second.url, from: stalledAt)
        print("[fresh] second URL from byte \(stalledAt): \(secondWalk.summary)")
    }

    /// Same client, same network — so what makes the phone's URL capped and the
    /// simulator's not? The credential is the only per-device input to the resolve.
    func testWhetherTheVisitorTokenDecidesTheCap() async throws {
        let client = try XCTUnwrap(Self.clients.first)

        let cheap = await VisitorDataProvider.shared.token(for: .cheap)
        let authoritative = await VisitorDataProvider.shared.token(for: .authoritative)
        print("\n[token] cheap:         \(cheap?.prefix(24) ?? "nil")…")
        print("[token] authoritative: \(authoritative?.prefix(24) ?? "nil")…")

        for (label, token) in [("cached/cheap", cheap), ("fresh authoritative", authoritative), ("none", nil)] {
            do {
                let resolved = try await Self.resolve(videoId: videoId, client: client, visitorData: token)
                let walk = await Self.walk(resolved.url)
                print("[token] \(label.padding(toLength: 20, withPad: " ", startingAt: 0)) -> \(walk.summary)")
            } catch {
                print("[token] \(label.padding(toLength: 20, withPad: " ", startingAt: 0)) -> resolve failed: \(error.localizedDescription)")
            }
        }
    }

    /// The muxed fallback the app already has. Before relying on it, check it can actually
    /// serve a whole track on the phone rather than being capped the same way.
    func testWhetherTheMuxedFallbackIsCappedToo() async throws {
        let android = try XCTUnwrap(Self.clients.first { $0.name == "ANDROID" })
        let resolved = try await Self.resolve(videoId: videoId, client: android, progressive: true)
        let walk = await Self.walk(resolved.url)
        print("\n[muxed] itag \(resolved.itag): \(walk.summary)")
        XCTAssertNil(
            walk.failedAtOffset,
            "The muxed fallback is capped too — there is no working path on this device"
        )
    }

    // MARK: - Helpers

    private struct Resolved {
        let url: String
        let itag: Int
    }

    private static func resolve(
        videoId: String,
        client: InnerTubeClient.PlayerClient,
        visitorData: String?? = nil,
        progressive: Bool = false
    ) async throws -> Resolved {
        let token: String?
        if let visitorData {
            token = visitorData
        } else {
            token = await VisitorDataProvider.shared.token(for: .cheap)
        }
        let request = try InnerTubeClient.playerRequest(videoId: videoId, client: client, visitorData: token)
        let (data, response) = try await NetworkSessions.api.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let json = try JSON.parse(data)
        guard json["playabilityStatus"]["status"].string == "OK" else {
            throw APIError.server(json["playabilityStatus"]["reason"].string ?? "not OK")
        }
        let formats: [JSON]
        if progressive {
            formats = (json["streamingData"]["formats"].array ?? []).filter { $0["url"].exists }
        } else {
            formats = (json["streamingData"]["adaptiveFormats"].array ?? [])
                .filter { $0["mimeType"].string?.hasPrefix("audio/mp4") == true && $0["url"].exists }
        }
        guard let chosen = formats.first(where: { $0["itag"].int == (progressive ? 18 : 140) }) ?? formats.first,
              let url = chosen["url"].string else {
            throw APIError.server(progressive ? "no progressive format" : "no audio/mp4 format")
        }
        return Resolved(url: url, itag: chosen["itag"].int ?? -1)
    }

    private struct Walk {
        var total: Int64?
        var servedBytes: Int64 = 0
        var failedAtOffset: Int64?
        var failureStatus: Int?
        var summary: String {
            if let failedAtOffset, let failureStatus {
                return "served \(servedBytes) bytes, then HTTP \(failureStatus) at byte \(failedAtOffset)"
                    + " (~\(servedBytes / 16_000)s of 128kbps audio)"
            }
            return "served \(servedBytes) bytes — whole file, no cap"
        }
    }

    /// Walks the URL in the same 512 KB chunks the loader now uses.
    private static func walk(_ urlString: String, from start: Int64 = 0) async -> Walk {
        var walk = Walk()
        guard let url = URL(string: urlString) else { return walk }
        let chunk = StreamingResourceLoader.maximumChunkSize
        var offset = start
        for _ in 0..<200 {
            var end = offset + chunk - 1
            if let total = walk.total { end = min(end, total - 1) }
            var request = URLRequest(url: url)
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else {
                walk.failedAtOffset = offset
                walk.failureStatus = -1
                return walk
            }
            if walk.total == nil,
               let range = http.value(forHTTPHeaderField: "Content-Range"),
               let parsed = range.split(separator: "/").last.flatMap({ Int64($0) }) {
                walk.total = parsed
            }
            guard (200..<300).contains(http.statusCode) else {
                walk.failedAtOffset = offset
                walk.failureStatus = http.statusCode
                return walk
            }
            walk.servedBytes += Int64(data.count)
            offset += Int64(data.count)
            if let total = walk.total, offset >= total { return walk }
            if data.isEmpty { return walk }
        }
        return walk
    }
}
