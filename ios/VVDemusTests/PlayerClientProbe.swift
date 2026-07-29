import XCTest
@testable import VVDemus

/// Finds a player client that still returns audio-only formats.
///
/// The app's ANDROID_VR client is currently refused with "Sign in to confirm you're not a
/// bot", so every track silently falls back to muxed 360p video — roughly 3-4x the bytes,
/// for video nobody watches. YouTube blocks these clients by version and by shape, and
/// which ones work changes over time, so this probes several and reports what each one
/// actually returns rather than assuming.
///
/// Run it again whenever playback data usage looks wrong; it is a diagnostic, not a test
/// of the app, so it asserts nothing about which client wins.
@MainActor
final class PlayerClientProbe: XCTestCase {

    private struct Candidate {
        let label: String
        let userAgent: String
        let context: [String: Any]
    }

    private static let candidates: [Candidate] = [
        Candidate(
            label: "ANDROID_VR 1.65.10 (current)",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; GB) gzip",
            context: [
                "clientName": "ANDROID_VR", "clientVersion": "1.65.10",
                "deviceMake": "Oculus", "deviceModel": "Quest 3",
                "androidSdkVersion": 32, "osName": "Android", "osVersion": "12L",
            ]
        ),
        Candidate(
            label: "ANDROID_VR 1.68.36 (newer)",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.68.36 (Linux; U; Android 12L; GB) gzip",
            context: [
                "clientName": "ANDROID_VR", "clientVersion": "1.68.36",
                "deviceMake": "Oculus", "deviceModel": "Quest 3",
                "androidSdkVersion": 32, "osName": "Android", "osVersion": "12L",
            ]
        ),
        Candidate(
            label: "IOS 20.10.4",
            userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X)",
            context: [
                "clientName": "IOS", "clientVersion": "20.10.4",
                "deviceMake": "Apple", "deviceModel": "iPhone16,2",
                "osName": "iPhone", "osVersion": "18.3.2.22D82",
            ]
        ),
        Candidate(
            label: "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
            userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
            context: [
                "clientName": "TVHTML5_SIMPLY_EMBEDDED_PLAYER", "clientVersion": "2.0",
            ]
        ),
        Candidate(
            label: "WEB_EMBEDDED_PLAYER",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
            context: [
                "clientName": "WEB_EMBEDDED_PLAYER", "clientVersion": "1.20240101.00.00",
            ]
        ),
        Candidate(
            label: "MWEB",
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            context: [
                "clientName": "MWEB", "clientVersion": "2.20240726.00.00",
            ]
        ),
    ]

    func testProbePlayerClientsForAudioOnlyFormats() async {
        let videoId = "5NV6Rdv1a3I"
        print("\n┌─ PLAYER CLIENT PROBE ────────────────────────────────────────────────")
        for candidate in Self.candidates {
            let outcome = await Self.probe(candidate, videoId: videoId)
            print("│ \(candidate.label)")
            print("│    \(outcome)")
        }
        print("└──────────────────────────────────────────────────────────────────────")
        print("A client is usable only if it reports OK *and* offers audio/mp4 with a URL —")
        print("AVPlayer cannot decode the WebM/Opus formats (itags 249/250/251).")
    }

    private static func probe(_ candidate: Candidate, videoId: String) async -> String {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue(candidate.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "context": ["client": candidate.context],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return "could not encode" }
        request.httpBody = payload

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSON.parse(data) else { return "request failed" }

        let status = json["playabilityStatus"]["status"].string ?? "?"
        guard status == "OK" else {
            return "REFUSED (\(status): \(json["playabilityStatus"]["reason"].string ?? "no reason"))"
        }

        let formats = json["streamingData"]["adaptiveFormats"].array ?? []
        let playable = formats.filter {
            $0["mimeType"].string?.hasPrefix("audio/mp4") == true && $0["url"].exists
        }
        guard !playable.isEmpty else {
            let anyAudio = formats.filter { $0["mimeType"].string?.hasPrefix("audio") == true }
            let ciphered = anyAudio.contains { !$0["url"].exists }
            let kinds = Set(anyAudio.compactMap { $0["mimeType"].string?.split(separator: ";").first.map(String.init) })
            return "OK but no usable audio/mp4 — \(anyAudio.count) audio formats \(kinds.sorted())\(ciphered ? ", URLs ciphered/SABR-gated" : "")"
        }

        let described = playable.compactMap { format -> String? in
            guard let itag = format["itag"].int else { return nil }
            let kbps = (format["bitrate"].int ?? 0) / 1000
            let mb = Int(format["contentLength"].string ?? "").map { String(format: "%.1fMB", Double($0) / 1024 / 1024) } ?? "?"
            return "itag \(itag) @\(kbps)kbps \(mb)"
        }
        return "USABLE — \(described.joined(separator: ", "))"
    }
}
