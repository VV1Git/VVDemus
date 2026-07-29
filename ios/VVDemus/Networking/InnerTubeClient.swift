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
    private static let iosUserAgent = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X)"
    /// InnerTube "params" blob selecting the Songs filter — reverse-engineered value,
    /// stable in practice (it's what music.youtube.com itself sends for this filter).
    private static let songsFilterParams = "EgWKAQIIAWoMEA4QChADEAQQCRAF"

    static let dataSaverDefaultsKey = "data_saver_enabled"

    /// Halves how many tracks are taken from a batch fetch (recommendation shelves,
    /// Daylist, autoplay refill) under Data Saver.
    ///
    /// Note this saves no bytes: InnerTube's search and `next` endpoints return a fixed
    /// page with no count parameter, so the limit is applied while parsing a response that
    /// has already been downloaded in full — measured at under 1% difference between
    /// limit 25 and limit 12 (VVDemusTests/DataUsageBenchmarks). It still bounds how much
    /// is held in memory and how far autoplay reaches ahead, which is why it stays.
    static func dataSaverLimit(default defaultLimit: Int) -> Int {
        UserDefaults.standard.bool(forKey: dataSaverDefaultsKey) ? max(1, defaultLimit / 2) : defaultLimit
    }

    /// Built from a fixed Gregorian calendar in UTC, not a locale-sensitive
    /// `DateFormatter`.
    ///
    /// `DateFormatter` defaults to `Locale.current`, so on a device set to a Thai
    /// Buddhist, Japanese Imperial or Islamic calendar `yyyy` rendered 2569 / 令和8 / 1448
    /// and every InnerTube request went out claiming to be client version "1.25690729.01.00".
    /// A formatter was also being allocated per request, which is one of the more
    /// expensive things in Foundation.
    static func clientVersion(for date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 2024
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        return String(format: "1.%04d%02d%02d.01.00", year, month, day)
    }

    private static var clientVersion: String { clientVersion(for: Date()) }

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
        // Each seed reports its own failure rather than throwing: `for try await`
        // rethrows the first error and cancels the siblings, so a single flaky search
        // wiped out the whole Quick Picks row on exactly the poor connection where a
        // partial row is better than none.
        let lists = await withTaskGroup(of: (Int, [Track]).self) { group -> [[Track]] in
            for (index, seed) in seeds.enumerated() {
                group.addTask { (index, (try? await search(query: seed, limit: perSeed)) ?? []) }
            }
            var results = Array(repeating: [Track](), count: seeds.count)
            for await (index, tracks) in group { results[index] = tracks }
            return results
        }
        guard lists.contains(where: { !$0.isEmpty }) else {
            throw APIError.server("Couldn't reach YouTube Music.")
        }

        var seen = Set<String>()
        var tracks: [Track] = []
        for list in lists {
            // "chill mix" in particular returns hour-long lounge compilations that read
            // as ordinary songs until they take over the queue.
            for track in list.excludingLongFormMixes() where !seen.contains(track.id) {
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
                // The seed (always first) is kept whatever its length — starting a radio
                // from a long mix is a deliberate choice. Everything after it is a
                // recommendation, and an hour-long one derails the rest of the queue.
                guard tracks.isEmpty || !track.isLongFormMix else { continue }
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
        do {
            return try await audioOnlyStream(videoId: videoId)
        } catch {
            // Logged rather than swallowed by a bare `try?`. This fallback silently
            // triples-to-quadruples the app's data usage — every track downloads a 360p
            // video nobody watches — and with no trace of it happening, the only symptom
            // is a data bill. If this line shows up for every track, the audio-only client
            // has stopped working and that is the thing to fix.
            NSLog("[InnerTubeClient] audio-only unavailable (%@) — falling back to muxed video at ~3-4x the data",
                  error.localizedDescription)
            lastStreamWasMuxedFallback = true
            return try await muxedStream(videoId: videoId)
        }
    }

    /// Whether the most recent resolution had to fall back to the heavy muxed format.
    /// Read by diagnostics; not used to make playback decisions.
    private(set) static var lastStreamWasMuxedFallback = false

    /// A player client that hands back direct, un-ciphered audio-only URLs.
    ///
    /// Tried in order, because YouTube blocks these clients individually and without
    /// notice — the whole reason this list exists rather than a single hard-coded client.
    ///
    /// ANDROID_VR spent a while looking permanently blocked ("Sign in to confirm you're
    /// not a bot"), and this comment used to say so. It was wrong: the client was fine and
    /// the requests were missing a `visitorData` token. Supplying one took resolution from
    /// 3/15 to 15/15 (see `VisitorDataProvider`). Diagnosing a *missing credential* as a
    /// *blocked client* is the trap to avoid here — the symptom is identical, and it cost
    /// this app ~3.9x its playback data for as long as the mistake stood.
    ///
    /// `VVDemusTests/PlayerClientProbe` re-runs this comparison against live YouTube; use
    /// it rather than guessing when playback data usage looks wrong again.
    struct PlayerClient {
        let name: String
        let version: String
        let userAgent: String
        let extraContext: [String: Any]
    }

    static let playerEndpoint = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"

    /// The fully-formed player request, credential included.
    static func playerRequest(
        videoId: String,
        client: PlayerClient,
        visitorData: String?
    ) throws -> URLRequest {
        var context: [String: Any] = [
            "clientName": client.name,
            "clientVersion": client.version,
            "userAgent": client.userAgent,
        ]
        context.merge(client.extraContext) { current, _ in current }
        if let visitorData {
            context["visitorData"] = visitorData
        }
        let body: [String: Any] = [
            "context": ["client": context],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        return try makeRequest(
            url: playerEndpoint,
            userAgent: client.userAgent,
            origin: nil,
            body: body,
            visitorData: visitorData
        )
    }

    /// Deliberately does **not** include the IOS client, which resolves perfectly well.
    ///
    /// A client has to clear **two** gates to belong here, and IOS clears only the first:
    ///
    /// 1. **Resolves** — answers with a direct, un-ciphered audio/mp4 URL.
    /// 2. **Serves a whole track** — byte ranges succeed all the way to the end.
    ///
    /// IOS reports both itag 139 and 140, then refuses every range past ~1 MB with a 403,
    /// while a range past the true end returns 416 — so the cap is deliberate throttling,
    /// not a size error. A track played for about a minute and died: strictly worse than
    /// paying for the muxed format, however good the byte figures looked at the start.
    /// Un-throttling those URLs needs the `n`-parameter descrambling that yt-dlp does by
    /// executing YouTube's player JavaScript, which this app does not do.
    ///
    /// ANDROID_VR clears both. Verified end to end: every range 206 across the whole file,
    /// 416 past the end, and complete tracks fetched in sequential ranges exactly matching
    /// `contentLength`. `VVDemusTests/PlayerClientProbe` re-checks gate 1 and
    /// `StreamUrlRangeTests` gate 2 — run both before ever adding a client here.
    static let audioOnlyClients: [PlayerClient] = [
        PlayerClient(
            name: "ANDROID_VR",
            version: "1.65.10",
            userAgent: androidVRUserAgent,
            extraContext: [
                "deviceMake": "Oculus",
                "deviceModel": "Quest 3",
                "androidSdkVersion": 32,
                "osName": "Android",
                "osVersion": "12L",
            ]
        ),
    ]

    private static func audioOnlyStream(videoId: String) async throws -> StreamInfo {
        var lastError: Error = APIError.server("No audio-only client available")
        for client in audioOnlyClients {
            do {
                return try await audioOnlyStream(videoId: videoId, using: client)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// A refusal that a fresh visitor token stands a chance of fixing, as opposed to a
    /// genuinely unavailable video. Distinguished so the retry below stays narrow — an
    /// age-restricted or region-blocked video must not send the app round again.
    struct TokenRefusal: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func isTokenRefusal(status: String?, reason: String) -> Bool {
        if status == "LOGIN_REQUIRED" { return true }
        let lowered = reason.lowercased()
        // Matched on "not a bot" rather than the full sentence: the apostrophe YouTube
        // sends is a curly U+2019, which is easy to get wrong in a literal.
        return lowered.contains("not a bot") || lowered.contains("sign in")
    }

    /// One resolve, with a single escalating retry if YouTube rejects the credential.
    ///
    /// Split out from the networking so the escalation itself is testable: which source is
    /// asked for, that a retry happens at all, and — just as important — that it happens
    /// **once** and only for a credential refusal. A retry loop around a genuinely
    /// unavailable video would hammer YouTube from a music app that looks stuck.
    static func resolveWithTokenRetry(
        token: (VisitorDataProvider.Source) async -> String?,
        attempt: (String?) async throws -> StreamInfo
    ) async throws -> StreamInfo {
        let first = await token(.cheap)
        do {
            return try await attempt(first)
        } catch let refusal as TokenRefusal {
            // Escalating rather than just refetching: it also rules out the cheap
            // endpoint's shape-match having quietly captured the wrong string.
            guard let fresh = await token(.authoritative), fresh != first else {
                throw APIError.server(refusal.reason)
            }
            do {
                return try await attempt(fresh)
            } catch let refusedAgain as TokenRefusal {
                // Stop. A fresh token was refused too, so this is not a stale credential.
                throw APIError.server(refusedAgain.reason)
            }
        }
    }

    private static func audioOnlyStream(videoId: String, using client: PlayerClient) async throws -> StreamInfo {
        try await resolveWithTokenRetry(
            token: { await VisitorDataProvider.shared.token(for: $0) },
            attempt: { try await audioOnlyStream(videoId: videoId, using: client, visitorData: $0) }
        )
    }

    private static func audioOnlyStream(
        videoId: String,
        using client: PlayerClient,
        visitorData: String?
    ) async throws -> StreamInfo {
        let request = try playerRequest(videoId: videoId, client: client, visitorData: visitorData)
        let json = try await send(request)

        let status = json["playabilityStatus"]["status"].string
        guard status == "OK" else {
            let reason = json["playabilityStatus"]["reason"].string ?? "video unavailable"
            throw isTokenRefusal(status: status, reason: reason)
                ? TokenRefusal(reason: reason) as Error
                : APIError.server(reason)
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
        lastStreamWasMuxedFallback = false
        return StreamInfo(videoId: videoId, url: urlString, expiresAt: expiry(for: urlString), mimeType: mime)
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
        return StreamInfo(videoId: videoId, url: urlString, expiresAt: expiry(for: urlString), mimeType: mime)
    }

    /// The URL's real deadline, read from its own `expire=` parameter.
    ///
    /// This used to be a flat "now + 5 hours", invented rather than read. YouTube's signed
    /// URLs are frequently shorter-lived than that, and `APIClient` caches on `expiresAt`
    /// — so a URL that had actually died was handed back out for hours. Playback then
    /// 403'd with no error surfaced anywhere, and pressing play again returned the same
    /// dead URL; only killing the app cleared it.
    static func expiry(for urlString: String) -> Double {
        guard let components = URLComponents(string: urlString),
              let expire = components.queryItems?.first(where: { $0.name == "expire" })?.value,
              let seconds = Double(expire), seconds > 0 else {
            return Date().addingTimeInterval(5 * 3600).timeIntervalSince1970
        }
        return seconds
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

    /// Requires an actual `m:ss` / `h:mm:ss` shape. Accepting a bare number meant the
    /// release year that appears in the same run of metadata ("Daft Punk • Discovery •
    /// 2001") was read as a duration — so Digital Love was a 33-minute track, and every
    /// seek bar, mix length and listening-stats cap derived from it was wrong.
    private static func parseDuration(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        // Capped: `reduce { $0 * 60 + $1 }` over many segments overflows and traps, and this
        // string comes straight from a YouTube metadata run that is not always a duration.
        guard parts.count <= 3 else { return nil }
        guard parts.count >= 2, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return parts.compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
    }

    // MARK: - HTTP

    /// Building the request is separated from sending it so the part that carries the
    /// anti-bot credential can be asserted on without a network round trip. The wiring
    /// being silently absent is precisely the bug this guards: nothing fails, playback
    /// still works, and the app just quietly uses ~3.9x the data.
    static func makeRequest(
        url: String,
        userAgent: String,
        origin: String?,
        body: [String: Any],
        visitorData: String?
    ) throws -> URLRequest {
        guard let requestURL = URL(string: url) else { throw APIError.invalidURL }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        // Sent as a header as well as in the client context — YouTube reads it from either,
        // and a browser sends both.
        if let visitorData {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func post(
        url: String,
        userAgent: String,
        origin: String?,
        body: [String: Any],
        visitorData: String? = nil
    ) async throws -> JSON {
        let request = try makeRequest(
            url: url, userAgent: userAgent, origin: origin, body: body, visitorData: visitorData
        )
        return try await send(request)
    }

    private static func send(_ request: URLRequest) async throws -> JSON {
        let (data, response) = try await NetworkSessions.api.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.server("YouTube request failed")
        }
        // The status code used to be discarded, so a 403 (anti-bot), a 429 (rate limit)
        // and a 500 were indistinguishable — which matters because only some of those are
        // worth retrying, and an expired stream URL is specifically a 403.
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode)
        }
        return try JSON.parse(data)
    }
}
