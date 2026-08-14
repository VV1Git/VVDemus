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

    /// How many songs a radio holds, everywhere one is fetched.
    ///
    /// The `next` endpoint hands back a fixed 50-item page, so asking for fewer downloads
    /// exactly the same bytes and throws the rest away while parsing. Background fetches
    /// used to each ask for their own smaller slice — 10 for the Daylist, 15 for a
    /// recommendation shelf, 25 for autoplay — and whichever landed first became the
    /// cached mix, so a radio opened afterwards showed 15 songs rather than 50. They all
    /// take the whole page now and slice it locally for their own use.
    static let radioLength = 50

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
        //
        // The error is now carried alongside the tracks rather than swallowed by a `try?`.
        // It used to be discarded, so every empty Home said "Couldn't reach YouTube Music"
        // — including a rate limit, where that message sends the user to go and check a
        // connection that is working fine.
        typealias Outcome = (index: Int, tracks: [Track], error: Error?)
        let outcomes = await withTaskGroup(of: Outcome.self) { group -> [Outcome] in
            for (index, seed) in seeds.enumerated() {
                group.addTask {
                    do {
                        return (index, try await search(query: seed, limit: perSeed), nil)
                    } catch {
                        return (index, [], error)
                    }
                }
            }
            var collected: [Outcome] = []
            for await outcome in group { collected.append(outcome) }
            // Reassembled in seed order so the shelf doesn't reshuffle itself between loads.
            return collected.sorted { $0.index < $1.index }
        }

        let lists = outcomes.map(\.tracks)
        guard lists.contains(where: { !$0.isEmpty }) else {
            if let rateLimited = outcomes.compactMap({ $0.error as? APIError }).first(where: \.isRateLimit) {
                throw rateLimited
            }
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

    static func radio(videoId: String, limit: Int = radioLength) async throws -> [Track] {
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
            //
            // A `CappedStreamURL` here means audio-only resolved but would have stopped a
            // minute into every song, so the heavier format is the only one that plays.
            // Measured on an iPhone where every audio-only client was capped while the same
            // code on a Mac, from the same public IP, was not — so this cannot be decided
            // once and hard-coded, it has to be checked per resolve.
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
    ///
    /// **Gate 2 is not a property of the client alone.** On one iPhone every client that
    /// resolved — ANDROID_VR 1.65.10, ANDROID_VR 1.68.36 and IOS alike — served exactly
    /// 1 MiB and then 403'd, while the same code on a Mac from the same public IP served
    /// whole files. Re-resolving does not help: a fresh URL is refused at the same offset.
    /// So the gate is checked at runtime on every resolve (`servesWholeResource`) and the
    /// muxed fallback carries whatever fails it. `VVDemusTests/ThrottleCapDiagnostics`
    /// measures the cap per client — run it on the *device*, not the simulator, because
    /// the simulator borrows the Mac's networking and never sees this.
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

    /// The URL resolved, and then refused to serve the track past its first megabyte.
    ///
    /// This is the **second gate** described on `audioOnlyClients`, finally checked at
    /// runtime instead of only by a test. It is a distinct error because the response is
    /// specific: nothing about the credential or the video is wrong, so retrying or
    /// re-resolving is pointless (a freshly resolved URL is refused at the very same
    /// offset) — the only way to hear the whole song is the muxed format.
    struct CappedStreamURL: LocalizedError {
        let servedBytes: Int64
        var errorDescription: String? { "stream URL serves only its first \(servedBytes) bytes" }
    }

    /// Below this, a track fits inside the cap and plays to the end even on a capped URL,
    /// so there is nothing to check and no reason to spend a request checking it.
    static let cappedURLProbeThreshold: Int64 = 1 << 20

    /// Whether a resolved URL is worth verifying before playing it.
    ///
    /// An unknown length can't be verified — the probe needs a byte offset to aim at — so
    /// it goes ahead unchecked rather than being condemned on a guess.
    static func shouldVerifyServesWholeResource(contentLength: Int64?) -> Bool {
        guard let contentLength else { return false }
        return contentLength > cappedURLProbeThreshold
    }

    /// Asks for the last two bytes of the resource. A capped URL answers 403 there while
    /// still serving its opening megabyte perfectly, which is exactly why this cannot be
    /// detected by checking that playback starts.
    static func servesWholeResource(urlString: String, contentLength: Int64) async -> Bool {
        guard let url = URL(string: urlString), contentLength >= 2 else { return true }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(contentLength - 2)-\(contentLength - 1)", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await NetworkSessions.api.data(for: request),
              let http = response as? HTTPURLResponse else {
            // Unreachable rather than refused: don't condemn the URL for a flaky moment.
            return true
        }
        return (200..<300).contains(http.statusCode)
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

        // Gate 2: it resolved, but will it serve the whole song? On some devices every
        // audio-only client hands back a URL capped to its first 1 MiB — about 65 seconds
        // of itag 140 — which plays perfectly and then dies mid-track with a 403. Checked
        // here rather than discovered by the user a minute into a song.
        let contentLength = chosen["contentLength"].string.flatMap(Int64.init)
        if shouldVerifyServesWholeResource(contentLength: contentLength), let contentLength,
           await !servesWholeResource(urlString: urlString, contentLength: contentLength) {
            throw CappedStreamURL(servedBytes: cappedURLProbeThreshold)
        }

        lastStreamWasMuxedFallback = false
        return StreamInfo(videoId: videoId, url: urlString, expiresAt: expiry(for: urlString), mimeType: mime)
    }

    /// itag 18: a legacy muxed 360p video + AAC audio file. Works reliably (no PO-token
    /// gate) but costs extra data for the video you never see.
    ///
    /// How much extra depends entirely on the upload, and it is no longer only an
    /// emergency path — a device whose audio-only URLs are capped takes it for every
    /// track, so the real figure is worth knowing. Measured on "Get Lucky (Official
    /// Audio)", a static-image upload whose video track compresses to nearly nothing:
    /// itag 18 is 4,445,542 bytes against itag 140's 4,025,466 — about **1.1x**, and the
    /// same 248.7s of audio. A genuine music video is where the 3-4x figure comes from.
    /// Both formats carry the full track; the fallback never shortens a song.
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

    /// One logical request, retried a bounded number of times for the failures that a retry
    /// can actually fix.
    ///
    /// The status code was already being preserved rather than discarded — so a 403
    /// (anti-bot), a 429 (rate limit) and a 500 were distinguishable — but nothing used the
    /// distinction, and every one of them failed instantly and finally. A search that hit a
    /// momentary 503 showed "No results", and the user's next keystroke sent another request.
    ///
    /// The waiting is deliberately bounded by `RateLimit.maximumWait`: a longer cool-down is
    /// handed back as `APIError.rateLimited` so the UI can say when to try again, rather than
    /// holding a spinner for a minute. Sleeps use `Task.sleep`, so a search superseded by the
    /// next keystroke stops waiting the moment it's cancelled.
    private static func send(_ request: URLRequest) async throws -> JSON {
        var lastError: Error = APIError.server("YouTube request failed")

        for attempt in 1...RateLimit.maximumAttempts {
            // A cool-down another request already discovered. Checked before sending, so
            // concurrent callers (Home fans out into three searches) back off together
            // instead of each earning their own 429.
            if let remaining = RateLimitGate.shared.remainingCooldown() {
                guard remaining <= RateLimit.maximumWait else {
                    throw APIError.rateLimited(retryAfter: remaining)
                }
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }

            do {
                let (data, response) = try await NetworkSessions.api.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw APIError.server("YouTube request failed")
                }

                if (200..<300).contains(http.statusCode) {
                    // Something got through, so whatever limit was in force has lifted.
                    RateLimitGate.shared.clear()
                    return try JSON.parse(data)
                }

                if http.statusCode == 429 {
                    let retryAfter = RateLimit.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
                    RateLimitGate.shared.recordRateLimit(retryAfter: retryAfter)
                    lastError = APIError.rateLimited(retryAfter: retryAfter ?? RateLimit.defaultCooldown)
                    // No backoff sleep here: the gate now holds the wait, and the top of the
                    // next iteration honours it. Sleeping in both places would double it.
                    guard attempt < RateLimit.maximumAttempts else { throw lastError }
                    continue
                }

                lastError = APIError.http(status: http.statusCode)
                guard RateLimit.isRetryable(status: http.statusCode),
                      attempt < RateLimit.maximumAttempts else { throw lastError }
            } catch let urlError as URLError {
                lastError = urlError
                guard RateLimit.isRetryable(urlError: urlError),
                      attempt < RateLimit.maximumAttempts else { throw urlError }
            }

            let delay = RateLimit.backoffDelay(attempt: attempt)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        throw lastError
    }
}
