import Foundation

/// Talks directly to YouTube Music's internal ("InnerTube") API — the same API the
/// music.youtube.com web client and the ytmusicapi/yt-dlp Python libraries use — so the
/// app needs no backend server of its own and works over any network, not just a LAN.
///
/// Search/browse (WEB_REMIX client) is stable, documented-by-convention JSON. Stream
/// resolution is the fragile part — both paths key off client contexts that aren't
/// officially supported, and YouTube tightens anti-bot measures over time. Unlike
/// yt-dlp there's no upstream project patching this when it eventually breaks; the fix
/// at that point is code, not a `pip install -U`.
enum InnerTubeClient {
    private static let webRemixAPIKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
    private static let webUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0"
    private static let androidUserAgent = "com.google.android.youtube/21.02.35 (Linux; U; Android 11) gzip"
    private static let androidVRUserAgent = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
    /// InnerTube "params" blob selecting the Songs filter — reverse-engineered value,
    /// stable in practice (it's what music.youtube.com itself sends for this filter).
    private static let songsFilterParams = "EgWKAQIIAWoMEA4QChADEAQQCRAF"

    static let dataSaverDefaultsKey = "data_saver_enabled"

    /// Halves batch-fetch sizes (recommendation shelves, Daylist, autoplay refill) under
    /// Data Saver — previously Data Saver only changed streaming bitrate and left these
    /// fixed constants untouched, even though a smaller radio/recommendation payload is a
    /// real, easy data saving with no audible quality cost.
    static func dataSaverLimit(default defaultLimit: Int) -> Int {
        UserDefaults.standard.bool(forKey: dataSaverDefaultsKey) ? max(1, defaultLimit / 2) : defaultLimit
    }

    private static var clientVersion: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return "1.\(formatter.string(from: Date())).01.00"
    }

    // MARK: - Search

    static func search(query: String, limit: Int) async throws -> [Track] {
        let body: [String: Any] = [
            "context": [
                "client": ["clientName": "WEB_REMIX", "clientVersion": clientVersion],
                "user": [String: Any](),
            ],
            "query": query,
            "params": songsFilterParams,
        ]
        let json = try await post(
            url: "https://music.youtube.com/youtubei/v1/search?alt=json&prettyPrint=false&key=\(webRemixAPIKey)",
            userAgent: webUserAgent,
            origin: "https://music.youtube.com",
            body: body
        )

        let shelves = json["contents"]["tabbedSearchResultsRenderer"]["tabs"][0]["tabRenderer"]["content"]["sectionListRenderer"]["contents"].array ?? []
        var tracks: [Track] = []
        for shelf in shelves {
            let items = shelf["musicShelfRenderer"]["contents"].array ?? []
            for item in items {
                if let track = parseSearchItem(item["musicResponsiveListItemRenderer"]) {
                    tracks.append(track)
                    if tracks.count >= limit { return tracks }
                }
            }
        }
        return tracks
    }

    /// No personalized "home" endpoint without signing in, so this mirrors what the
    /// old backend did: a handful of broad seed searches, deduplicated.
    ///
    /// The searches run concurrently — they're independent, and run one after another they
    /// made Home's first paint wait on three round trips in a row. Results are reassembled
    /// in seed order afterwards so the shelf doesn't reshuffle itself between loads.
    static func home() async throws -> [Track] {
        let seeds = ["top hits 2026", "chill mix", "trending music"]
        let perSeed = dataSaverLimit(default: 10)
        let lists = try await withThrowingTaskGroup(of: (Int, [Track]).self) { group -> [[Track]] in
            for (index, seed) in seeds.enumerated() {
                group.addTask { (index, try await search(query: seed, limit: perSeed)) }
            }
            var results = Array(repeating: [Track](), count: seeds.count)
            for try await (index, tracks) in group { results[index] = tracks }
            return results
        }

        var seen = Set<String>()
        var tracks: [Track] = []
        for list in lists {
            for track in list where !seen.contains(track.id) {
                seen.insert(track.id)
                tracks.append(track)
            }
        }
        return tracks
    }

    // MARK: - Radio

    static func radio(videoId: String, limit: Int) async throws -> [Track] {
        let body: [String: Any] = [
            "context": [
                "client": ["clientName": "WEB_REMIX", "clientVersion": clientVersion],
                "user": [String: Any](),
            ],
            "videoId": videoId,
            "playlistId": "RDAMVM" + videoId,
            "params": "wAEB",
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]
        let json = try await post(
            url: "https://music.youtube.com/youtubei/v1/next?alt=json&prettyPrint=false&key=\(webRemixAPIKey)",
            userAgent: webUserAgent,
            origin: "https://music.youtube.com",
            body: body
        )

        let items = json["contents"]["singleColumnMusicWatchNextResultsRenderer"]["tabbedRenderer"]["watchNextTabbedResultsRenderer"]["tabs"][0]["tabRenderer"]["content"]["musicQueueRenderer"]["content"]["playlistPanelRenderer"]["contents"].array ?? []
        var tracks: [Track] = []
        for item in items {
            if let track = parseWatchItem(item["playlistPanelVideoRenderer"]) {
                tracks.append(track)
                if tracks.count >= limit { break }
            }
        }
        return tracks
    }

    // MARK: - Stream resolution

    /// Audio-only first (a few MB instead of the ~3-4x heavier muxed video+audio file),
    /// falling back to the muxed path if the audio-only client ever stops cooperating.
    static func stream(videoId: String) async throws -> StreamInfo {
        if let audioOnly = try? await audioOnlyStream(videoId: videoId) {
            return audioOnly
        }
        return try await muxedStream(videoId: videoId)
    }

    /// ANDROID_VR's player response exposes adaptiveFormats with direct, un-ciphered
    /// audio-only URLs and no PO-token gate — unlike the ANDROID client's adaptiveFormats,
    /// which are gated behind the newer SABR streaming protocol we don't implement.
    /// This is the most fragile part of the whole client: it rides on a client context
    /// YouTube never intended third parties to use for this, and could stop working
    /// without notice. If it does, `stream(videoId:)` above transparently falls back to
    /// the muxed path, so playback keeps working — just at ~3-4x the data cost.
    private static func audioOnlyStream(videoId: String) async throws -> StreamInfo {
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "ANDROID_VR",
                    "clientVersion": "1.65.10",
                    "deviceMake": "Oculus",
                    "deviceModel": "Quest 3",
                    "androidSdkVersion": 32,
                    "userAgent": androidVRUserAgent,
                    "osName": "Android",
                    "osVersion": "12L",
                ],
            ],
            "videoId": videoId,
        ]
        let json = try await post(
            url: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
            userAgent: androidVRUserAgent,
            origin: nil,
            body: body
        )

        guard json["playabilityStatus"]["status"].string == "OK" else {
            throw APIError.server(json["playabilityStatus"]["reason"].string ?? "video unavailable")
        }

        // AAC-in-MP4 only (itags 139/140) — AVPlayer doesn't support WebM/Opus, which is
        // what the other adaptive audio formats (249/251) would otherwise offer.
        let audioFormats = (json["streamingData"]["adaptiveFormats"].array ?? [])
            .filter { $0["mimeType"].string?.hasPrefix("audio/mp4") == true && $0["url"].exists }

        // itag 140 (~128kbps) by default; itag 139 (~48kbps) under Data Saver — noticeably
        // smaller downloads at the cost of audible quality, so it's opt-in.
        let dataSaver = UserDefaults.standard.bool(forKey: dataSaverDefaultsKey)
        let preferredItag = dataSaver ? 139 : 140
        guard let chosen = audioFormats.first(where: { $0["itag"].int == preferredItag }) ?? audioFormats.first,
              let urlString = chosen["url"].string else {
            throw APIError.server("No audio-only format available")
        }
        let mime = chosen["mimeType"].string ?? "audio/mp4"
        let expiresAt = Date().addingTimeInterval(5 * 3600).timeIntervalSince1970
        return StreamInfo(videoId: videoId, url: urlString, expiresAt: expiresAt, mimeType: mime)
    }

    /// itag 18: a legacy muxed 360p video + AAC audio file. Works reliably (no PO-token
    /// gate) but costs roughly 3-4x the data of audio-only for the video you never see.
    private static func muxedStream(videoId: String) async throws -> StreamInfo {
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "ANDROID",
                    "clientVersion": "21.02.35",
                    "androidSdkVersion": 30,
                    "userAgent": androidUserAgent,
                    "osName": "Android",
                    "osVersion": "11",
                ],
            ],
            "videoId": videoId,
        ]
        let json = try await post(
            url: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
            userAgent: androidUserAgent,
            origin: nil,
            body: body
        )

        guard json["playabilityStatus"]["status"].string == "OK" else {
            let reason = json["playabilityStatus"]["reason"].string ?? "video unavailable"
            throw APIError.server(reason)
        }

        let formats = json["streamingData"]["formats"].array ?? []
        guard let playable = formats.first(where: { $0["url"].exists }),
              let urlString = playable["url"].string else {
            throw APIError.server("No playable format returned")
        }
        let mime = playable["mimeType"].string ?? "video/mp4"
        // These signed URLs are time-limited; treat as expiring in a few hours to be safe.
        let expiresAt = Date().addingTimeInterval(5 * 3600).timeIntervalSince1970
        return StreamInfo(videoId: videoId, url: urlString, expiresAt: expiresAt, mimeType: mime)
    }

    // MARK: - Shared parsing

    private static func parseSearchItem(_ item: JSON) -> Track? {
        guard let videoId = item["overlay"]["musicItemThumbnailOverlayRenderer"]["content"]["musicPlayButtonRenderer"]["playNavigationEndpoint"]["watchEndpoint"]["videoId"].string else {
            return nil
        }
        let title = item["flexColumns"][0]["musicResponsiveListItemFlexColumnRenderer"]["text"]["runs"][0]["text"].string ?? "Unknown Title"
        let runs = item["flexColumns"][1]["musicResponsiveListItemFlexColumnRenderer"]["text"]["runs"].array ?? []
        let parsed = parseRuns(runs)
        let thumbnails = item["thumbnail"]["musicThumbnailRenderer"]["thumbnail"]["thumbnails"].array ?? []

        return Track(
            videoId: videoId,
            title: title,
            artist: parsed.artists.isEmpty ? "Unknown Artist" : parsed.artists.joined(separator: ", "),
            album: parsed.album,
            thumbnailUrl: thumbnails.last?["url"].string,
            durationSeconds: parsed.durationSeconds
        )
    }

    private static func parseWatchItem(_ item: JSON) -> Track? {
        guard let videoId = item["videoId"].string else { return nil }
        let title = item["title"]["runs"][0]["text"].string ?? "Unknown Title"
        let runs = item["longBylineText"]["runs"].array ?? []
        let parsed = parseRuns(runs)
        let thumbnails = item["thumbnail"]["thumbnails"].array ?? []
        let lengthText = item["lengthText"]["runs"][0]["text"].string

        return Track(
            videoId: videoId,
            title: title,
            artist: parsed.artists.isEmpty ? "Unknown Artist" : parsed.artists.joined(separator: ", "),
            album: parsed.album,
            thumbnailUrl: thumbnails.last?["url"].string,
            durationSeconds: parsed.durationSeconds ?? lengthText.flatMap(parseDuration)
        )
    }

    private struct ParsedRuns {
        var artists: [String] = []
        var album: String?
        var durationSeconds: Int?
    }

    /// "Artist • Album • 3:45"-style runs: even indices are data, odd indices are
    /// separators. A data run with a navigationEndpoint is an artist or album (album
    /// browseIds start with "MPRE"); one without is plain text like a duration or year.
    private static func parseRuns(_ runs: [JSON]) -> ParsedRuns {
        var result = ParsedRuns()
        for (index, run) in runs.enumerated() where index % 2 == 0 {
            guard let text = run["text"].string else { continue }
            if let browseId = run["navigationEndpoint"]["browseEndpoint"]["browseId"].string {
                if browseId.hasPrefix("MPRE") {
                    result.album = text
                } else {
                    result.artists.append(text)
                }
            } else if let duration = parseDuration(text) {
                result.durationSeconds = duration
            }
        }
        return result
    }

    private static func parseDuration(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard !parts.isEmpty, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return parts.compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
    }

    // MARK: - HTTP

    private static func post(url: String, userAgent: String, origin: String?, body: [String: Any]) async throws -> JSON {
        guard let requestURL = URL(string: url) else { throw APIError.invalidURL }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await NetworkSessions.api.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server("YouTube request failed")
        }
        return try JSON.parse(data)
    }
}
