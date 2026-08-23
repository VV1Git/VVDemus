import Foundation

/// Why lyrics could not be fetched, as opposed to not existing.
///
/// The distinction is the whole error-handling contract of this file: a track with no lyrics
/// anywhere is `nil`, not a throw, because it is an ordinary and permanent answer that the
/// screen renders as "no lyrics" and the cache records as a miss. Only a failure that might
/// succeed on a second try — the host unreachable, a 500, a rate limit — comes back as an
/// error, because that is the only case where telling the user "no lyrics for this song" would
/// be a lie that then gets cached.
enum LyricsSourceError: LocalizedError, Equatable {
    case unreachable
    case rateLimited(retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .unreachable:
            return "Couldn't reach the lyrics service."
        case .rateLimited(let retryAfter):
            guard let retryAfter, retryAfter >= 1 else {
                return "The lyrics service is limiting requests. Try again in a moment."
            }
            return "The lyrics service is limiting requests. Try again in \(Int(retryAfter.rounded(.up)))s."
        }
    }
}

/// One row of an LRCLIB response, from either `/api/get` (an object) or `/api/search` (an array
/// of the same objects).
///
/// Everything is optional, including the names. LRCLIB is community-contributed and its rows
/// carry whatever the contributor typed; a row missing an album must not cost the whole search
/// the way a synthesised `Decodable` would make it.
struct LRCLIBRecord: Decodable, Equatable {
    let trackName: String?
    let artistName: String?
    let albumName: String?
    /// Seconds, sent as a JSON number that is sometimes fractional (`233.0`, `233.45`).
    let duration: Double?
    /// LRCLIB's own flag for a track that has no words at all. It arrives with both lyric
    /// fields empty or null, so without the flag it is indistinguishable from a broken row.
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    /// What `LyricsMatch` scores against, and what `Lyrics.matchedDuration` records.
    ///
    /// `Int(exactly:)` rather than `Int(_:)`: the field is a number a contributor submitted, and
    /// `Int(1e30)` is a trap, not a large number. One hostile or corrupt row in a search result
    /// would otherwise take the process down for everyone who opened that song's lyrics — a row
    /// we cannot make sense of has to be a row we ignore, which is what `nil` already means here.
    var durationSeconds: Int? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return Int(exactly: duration.rounded())
    }
}

/// Fetches the words to a track: LRCLIB first, YouTube Music second.
///
/// Split so that everything sharp is reachable from `VVDemusTests` without a network. The
/// network calls here are three lines of `URLSession` each and are not the interesting part —
/// the interesting part is which of several candidate rows is believed and what is done with a
/// row whose timing is not to be trusted, and that lives in `choose(track:among:)` and
/// `lyrics(from:verdict:)`, both pure and both fed fixture JSON by the tests.
enum LyricsClient {

    // MARK: - The whole request

    /// The words for `track`, or `nil` when neither source has any.
    ///
    /// Both sources are tried even if the first one fails outright, because they fail
    /// independently and a reader wanting the words does not care which host supplied them.
    /// An error is only surfaced when *nothing* was found *and* something went wrong, so a
    /// working YouTube fallback is never hidden behind an LRCLIB outage.
    static func lyrics(for track: Track) async throws -> Lyrics? {
        var failure: Error?

        do {
            if let found = try await lrclib(for: track) { return found }
        } catch {
            if isCancellation(error) { throw CancellationError() }
            failure = error
        }

        do {
            if let found = try await youTubeMusic(for: track) { return found }
        } catch {
            if isCancellation(error) { throw CancellationError() }
            failure = failure ?? error
        }

        if let failure { throw failure }
        return nil
    }

    /// Cancellation, whichever shape it arrives in.
    ///
    /// The LRCLIB leg converts a `URLError.cancelled` itself, but `InnerTubeClient` rethrows the
    /// `URLError` untouched — `RateLimit.isRetryable(urlError:)` excludes `.cancelled`, so it
    /// never reaches a `Task.sleep` that would raise a `CancellationError` instead. Without this
    /// a superseded fetch came back as an ordinary failure milliseconds after the next track's
    /// lyrics had already loaded, and wrote an error banner over words that were fine.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    // MARK: - LRCLIB

    /// The exact lookup first, then the search.
    ///
    /// `/api/get` is duration-matched on LRCLIB's side, so when it answers at all the answer is
    /// very likely right — but it answers 404 for anything it cannot match to the second, which
    /// is most tracks whose length we round differently from the contributor. `/api/search` is
    /// the fuzzy half, and it hands back rows for other recordings entirely, which is what
    /// `LyricsMatch` is for.
    private static func lrclib(for track: Track) async throws -> Lyrics? {
        if let data = try await get(makeGetRequest(for: track)),
           let record = decodeRecord(data),
           let found = choose(track: track, among: [record]) {
            return found
        }

        guard let data = try await get(makeSearchRequest(for: track)) else { return nil }
        return choose(track: track, among: decodeSearch(data))
    }

    /// `https://lrclib.net/api/get?artist_name=…&track_name=…&album_name=…&duration=…`
    ///
    /// Built apart from being sent, the way `InnerTubeClient.makeRequest` and
    /// `SpotifyImportClient.makeRequest` are, so the query can be asserted on without a host.
    static func makeGetRequest(for track: Track) -> URLRequest? {
        var items = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name", value: track.title),
        ]
        if let album = track.album, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        // Sent when we have it because it is what makes `/api/get` exact. Omitted rather than
        // faked when we do not: a zero here would match nothing forever.
        if let duration = track.durationSeconds {
            items.append(URLQueryItem(name: "duration", value: String(duration)))
        }
        return makeRequest(path: "/api/get", items: items)
    }

    /// The fuzzy fallback. Deliberately narrower than the exact lookup — no album, no duration —
    /// because those are the two fields most likely to be the reason the exact lookup missed,
    /// and repeating them here would reproduce the same miss.
    static func makeSearchRequest(for track: Track) -> URLRequest? {
        makeRequest(path: "/api/search", items: [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
        ])
    }

    private static func makeRequest(path: String, items: [URLQueryItem]) -> URLRequest? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = path
        // Every field here is user-supplied text — a title with a `&` or a `#` in it, an artist
        // with a `+`. `URLComponents` percent-encodes the values; string interpolation would
        // have silently truncated the query at the first one.
        components.queryItems = items.filter { !($0.value ?? "").isEmpty }
        // `URLComponents` escapes `&` and `=` in a value but leaves `+` alone, and a `+` in a
        // query string is a space to most servers — so "Me + You" would be looked up as
        // "Me   You" and miss, silently and only for songs with a plus in the title. Measured
        // against Foundation rather than assumed; the tests pin it.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Tighter than `NetworkSessions`' own 15s. Lyrics are decoration on top of a song that
        // is already playing; fifteen seconds of a spinner over the words costs more than
        // giving up and letting the reader tap again.
        request.timeoutInterval = 8
        return request
    }

    /// LRCLIB's documentation asks clients to identify themselves and link somewhere a human can
    /// be reached. Naming the app is also what lets them block us specifically rather than
    /// blocking whatever bracket of anonymous traffic we landed in.
    private static var userAgent: String {
        "VVDemus/\(AppVersion.marketing) (https://github.com/VV1Git/VVDemus)"
    }

    /// LRCLIB's politeness budget, deliberately **not** `RateLimitGate.shared`.
    ///
    /// That gate is what holds YouTube's searches back, and playback depends on it. Letting a
    /// 429 from a lyrics host close it would stall the thing that matters on behalf of the thing
    /// that does not; letting a successful lyrics fetch *clear* it would reopen YouTube's gate
    /// early on evidence from a host that knows nothing about YouTube's limits. Different host,
    /// different limits, separate budget.
    private static let lrclibGate = RateLimitGate()

    /// The same argument one host over. `music.youtube.com` is playback's host, so this leg
    /// still *waits* on `RateLimitGate.shared` — hammering past a limit playback discovered
    /// would be the original sin this whole mechanism exists to prevent — but a refusal earned
    /// by a lyrics request is recorded here instead of there. Otherwise a decorative prefetch
    /// during a bulk download parks every still-queued audio resolution in
    /// `DownloadManager.awaitRateLimitGate`, which is `collectionProgress` reporting the album
    /// "Paused" because of words, and a *successful* lyrics fetch clears a cool-down the media
    /// host's own 429 had just recorded.
    private static let youTubeGate = RateLimitGate()

    /// `nil` for a 404, which is LRCLIB saying it has never heard of this track — an answer, not
    /// a failure. Throws only for the failures a second attempt could fix.
    private static func get(_ request: URLRequest?) async throws -> Data? {
        guard let request else { return nil }

        var lastError: Error = LyricsSourceError.unreachable

        for attempt in 1...RateLimit.maximumAttempts {
            if let remaining = lrclibGate.remainingCooldown() {
                guard remaining <= RateLimit.maximumWait else {
                    throw LyricsSourceError.rateLimited(retryAfter: remaining)
                }
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }

            do {
                // `NetworkSessions.api` rather than `URLSession.shared`, for the reason the spec
                // gives: it is the only path whose bytes reach `NetworkByteCounter`, so lyrics
                // show up in the data-usage benchmarks instead of being traffic nothing measures.
                let (data, response) = try await NetworkSessions.api.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw LyricsSourceError.unreachable }

                if (200..<300).contains(http.statusCode) {
                    lrclibGate.clear()
                    return data
                }
                // 404 is the documented "no such track" for both endpoints. There is nothing to
                // retry and nothing to report — the caller falls through to YouTube Music.
                if http.statusCode == 404 { return nil }

                if http.statusCode == 429 {
                    let retryAfter = RateLimit.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
                    lrclibGate.recordRateLimit(retryAfter: retryAfter)
                    lastError = LyricsSourceError.rateLimited(retryAfter: retryAfter ?? RateLimit.defaultCooldown)
                    // No sleep here; the gate holds the wait and the next iteration honours it.
                    guard attempt < RateLimit.maximumAttempts else { throw lastError }
                    continue
                }

                lastError = LyricsSourceError.unreachable
                guard RateLimit.isRetryable(status: http.statusCode),
                      attempt < RateLimit.maximumAttempts else { throw lastError }
            } catch let urlError as URLError {
                // The reader closing the screen arrives here as `.cancelled`. Reporting that as
                // "couldn't reach the lyrics service" would blame the network for something they
                // did, and would put an error on a screen nobody is looking at any more.
                if urlError.code == .cancelled { throw CancellationError() }
                lastError = LyricsSourceError.unreachable
                guard RateLimit.isRetryable(urlError: urlError),
                      attempt < RateLimit.maximumAttempts else { throw lastError }
            }

            try await Task.sleep(nanoseconds: UInt64(RateLimit.backoffDelay(attempt: attempt) * 1_000_000_000))
        }

        throw lastError
    }

    // MARK: - Reading a response

    /// `/api/get`'s single object. `nil` for anything else, including the `{"code":404,…}` body
    /// LRCLIB sends with its 404s.
    ///
    /// A shape change is deliberately *not* an error. Lyrics are optional; a decoder that threw
    /// here would turn a field rename into an error banner over every song, when the honest
    /// behaviour is to have no lyrics until this file is updated.
    static func decodeRecord(_ data: Data) -> LRCLIBRecord? {
        guard let record = try? JSONDecoder().decode(LRCLIBRecord.self, from: data) else { return nil }
        // The 404 body decodes cleanly into a record of all-nils, since every field is optional.
        // Without this it would reach the scorer as a candidate with no title and be rejected —
        // the right answer by accident, which is not a thing to rely on.
        guard record.trackName != nil || record.syncedLyrics != nil || record.plainLyrics != nil else {
            return nil
        }
        return record
    }

    /// `/api/search`'s array. An empty array is a legitimate "no matches", so it and a malformed
    /// body are the same answer here.
    static func decodeSearch(_ data: Data) -> [LRCLIBRecord] {
        (try? JSONDecoder().decode([LRCLIBRecord].self, from: data)) ?? []
    }

    // MARK: - The decision

    /// The best believable row, turned into `Lyrics`. Pure: this is the half worth testing.
    ///
    /// Rows are ranked rather than filtered to one, because the first row LRCLIB returns for a
    /// popular song is routinely a duplicate upload with an empty `syncedLyrics`. Falling to the
    /// next believable row costs nothing and is the difference between scrolling lyrics and a
    /// blank screen.
    static func choose(track: Track, among records: [LRCLIBRecord]) -> Lyrics? {
        let scored: [(record: LRCLIBRecord, verdict: LyricsVerdict, delta: Int)] = records
            .compactMap { record in
                let verdict = LyricsMatch.score(track: track, candidate: candidate(from: record))
                guard verdict != .reject else { return nil }
                // How far apart the two lengths are, used only to order equally-believed rows.
                // Unknown on either side sorts last: it is the row we know least about.
                let delta: Int
                if let wanted = track.durationSeconds, let theirs = record.durationSeconds {
                    delta = abs(wanted - theirs)
                } else {
                    delta = Int.max
                }
                return (record, verdict, delta)
            }
            .sorted { left, right in
                // Timed before untimed, then closest in length, then a row that actually carries
                // timings before one that does not.
                if (left.verdict == .accept) != (right.verdict == .accept) {
                    return left.verdict == .accept
                }
                if left.delta != right.delta { return left.delta < right.delta }
                return hasSynced(left.record) && !hasSynced(right.record)
            }

        // Timed words win outright, wherever in the ranking they turn up. The sort cannot do
        // this on its own: `hasSynced` only says the field is non-empty, and it is the third
        // key, so a plain-only duplicate that happens to be a second closer in length sorts
        // above the row that actually carries the LRC. Returning the first believable row there
        // hands back static text for a song that had scrolling lyrics one row further down —
        // exactly the outcome ranking rather than filtering exists to avoid.
        var untimed: Lyrics?
        for row in scored {
            guard let lyrics = lyrics(from: row.record, verdict: row.verdict) else { continue }
            if case .synced = lyrics.body { return lyrics }
            // Held rather than returned, and the *first* such row, so the ranking still decides
            // which words are shown when nothing below carries timings.
            if untimed == nil { untimed = lyrics }
        }
        return untimed
    }

    static func candidate(from record: LRCLIBRecord) -> LyricsCandidate {
        LyricsCandidate(
            title: record.trackName ?? "",
            artist: record.artistName ?? "",
            album: record.albumName,
            durationSeconds: record.durationSeconds
        )
    }

    private static func hasSynced(_ record: LRCLIBRecord) -> Bool {
        !(record.syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One row turned into a body, or `nil` when it carries no words at all.
    static func lyrics(from record: LRCLIBRecord, verdict: LyricsVerdict) -> Lyrics? {
        guard verdict != .reject else { return nil }
        // An instrumental has no words and never will. Reported as "nothing found" so the cache
        // records a miss, rather than as an empty scroll that looks like a bug.
        guard record.instrumental != true else { return nil }

        let synced = record.syncedLyrics ?? ""

        if verdict == .accept {
            let lines = LRCParser.parse(synced)
            // A row whose `syncedLyrics` is present but timestamp-free — a contributor pasting
            // plain text into the wrong field — parses to nothing. Returning `.synced([])` there
            // would render an empty scroll for a song that has perfectly good plain words sitting
            // in the next field, so it degrades instead.
            if !lines.isEmpty {
                return Lyrics(
                    body: .synced(lines),
                    attribution: Self.timedAttribution,
                    matchedDuration: record.durationSeconds
                )
            }
        }

        let plain = plainLines(record.plainLyrics, or: synced)
        guard !plain.isEmpty else { return nil }
        // The warning is about a decision *we* made, so it is only honest when there were
        // timings to decline. A row whose `syncedLyrics` was never filled in — the ordinary
        // shape for a contributor who only typed the words — is a track with no LRC anywhere,
        // and captioning it "timing skipped, this version isn't the same length" reports a
        // judgement that was never exercised, under a warning triangle.
        let declinedTimings = verdict == .acceptUntimedOnly && !LRCParser.parse(synced).isEmpty
        return Lyrics(
            body: .plain(plain),
            attribution: declinedTimings ? Self.untrustedTimingAttribution : Self.plainAttribution,
            matchedDuration: record.durationSeconds
        )
    }

    /// Plain text as lines, keeping blank ones — a stanza break is part of how the words are
    /// meant to be read, and collapsing them turns a song into a paragraph.
    ///
    /// Falls back to stripping the timestamps off the synced text when the plain field is empty.
    /// It costs one parse and it is the difference between showing the words and showing nothing
    /// for a row that only ever had the timed version filled in.
    private static func plainLines(_ text: String?, or synced: String) -> [String] {
        // `whereSeparator: \.isNewline`, not `separator: "\n"`. In Swift a CRLF is a single
        // extended grapheme cluster and `Character("\r\n") != Character("\n")`, so splitting on
        // the literal newline matched nothing at all in a file pasted out of a Windows editor —
        // the whole song came back as one "line", stanza breaks gone, the trims below never
        // firing, `/api/lyrics` reporting `lineCount: 1`. The synced half has always defended
        // against this (`LRCParser` splits the same way); the plain half did not.
        var lines = (text ?? "")
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if lines.allSatisfy(\.isEmpty) {
            lines = LRCParser.parse(synced).map(\.text)
        }

        // Leading and trailing blanks are whitespace in the file, not silence in the song.
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Attribution is shown, never hidden — the spec is explicit about that, and it is also how
    /// LRCLIB asks to be credited.
    ///
    /// It carries the trust note as well, because it is the only field that reaches the screen:
    /// an `.acceptUntimedOnly` result and a row that simply had no timings both arrive as
    /// `.plain`, and the reader deserves to know which one they are looking at when the words
    /// are right but the app declined to scroll them.
    static let timedAttribution = "Lyrics from LRCLIB"
    static let plainAttribution = "Lyrics from LRCLIB — no timings for this track"
    static let untrustedTimingAttribution =
        "Lyrics from LRCLIB — timing skipped, this version isn't the same length"

    // MARK: - YouTube Music

    /// Untimed by definition: YouTube Music's lyrics panel is a block of text with no timestamps
    /// anywhere in the response, so this always renders plain.
    ///
    /// Two round trips, which is why it is second: `/next` for the tab, `/browse` for the words.
    private static func youTubeMusic(for track: Track) async throws -> Lyrics? {
        let next = try await InnerTubeClient.post(
            url: "https://music.youtube.com/youtubei/v1/next?alt=json&prettyPrint=false&key=\(InnerTubeClient.webRemixAPIKey)",
            userAgent: InnerTubeClient.webUserAgent,
            origin: "https://music.youtube.com",
            body: [
                "context": [
                    "client": ["clientName": "WEB_REMIX", "clientVersion": InnerTubeClient.clientVersion(for: Date())],
                    "user": [String: Any](),
                ],
                "videoId": track.videoId,
            ],
            recordingLimitsOn: youTubeGate
        )

        guard let browseId = lyricsBrowseId(in: next) else { return nil }

        let browse = try await InnerTubeClient.post(
            url: "https://music.youtube.com/youtubei/v1/browse?alt=json&prettyPrint=false&key=\(InnerTubeClient.webRemixAPIKey)",
            userAgent: InnerTubeClient.webUserAgent,
            origin: "https://music.youtube.com",
            body: [
                "context": [
                    "client": ["clientName": "WEB_REMIX", "clientVersion": InnerTubeClient.clientVersion(for: Date())],
                    "user": [String: Any](),
                ],
                "browseId": browseId,
            ],
            recordingLimitsOn: youTubeGate
        )

        // No matching to do: this came back for the videoId that is playing, so it is by
        // construction the right recording. Recorded anyway, so a cache entry says what it was
        // matched against rather than leaving that to be inferred from which field is nil.
        return youTubeLyrics(in: browse, matchedDuration: track.durationSeconds)
    }

    /// The browseId behind the "Lyrics" tab of a watch page, or `nil` when the track has none.
    ///
    /// Found rather than indexed. The tab is second on every response seen so far, but the tab
    /// list also carries "Up next" and "Related" and its order is YouTube's to change; an index
    /// would go on working and start browsing the related-tracks shelf for words. Matched on the
    /// browseId prefix as well as the title so a non-English UI does not lose the feature.
    ///
    /// A track with no lyrics still gets a tab — greyed out, with `unselectable: true` and no
    /// endpoint at all — so the absence of a browseId is the real signal, not the absence of a tab.
    static func lyricsBrowseId(in json: JSON) -> String? {
        let tabs = json["contents"]["singleColumnMusicWatchNextResultsRenderer"]["tabbedRenderer"]["watchNextTabbedResultsRenderer"]["tabs"].array ?? []

        for tab in tabs {
            let renderer = tab["tabRenderer"]
            let browseId = renderer["endpoint"]["browseEndpoint"]["browseId"].string
            guard let browseId, !browseId.isEmpty else { continue }
            if browseId.hasPrefix("MPLYt") { return browseId }
            if renderer["title"].string?.caseInsensitiveCompare("Lyrics") == .orderedSame {
                return browseId
            }
        }
        return nil
    }

    /// The words out of a lyrics `/browse`, with the footer YouTube requires be shown alongside
    /// them ("Source: Musixmatch"). The footer is not decoration — it is the licence under which
    /// the text may be displayed, so a missing one is still credited to somewhere.
    static func youTubeLyrics(in json: JSON, matchedDuration: Int?) -> Lyrics? {
        let shelf = json["contents"]["sectionListRenderer"]["contents"][0]["musicDescriptionShelfRenderer"]

        let text = (shelf["description"]["runs"].array ?? [])
            .compactMap { $0["text"].string }
            .joined()
        guard !text.isEmpty else { return nil }

        let lines = plainLines(text, or: "")
        guard !lines.isEmpty else { return nil }

        let footer = (shelf["footer"]["runs"].array ?? [])
            .compactMap { $0["text"].string }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Lyrics(
            body: .plain(lines),
            attribution: footer.isEmpty ? "Lyrics from YouTube Music" : "YouTube Music — \(footer)",
            matchedDuration: matchedDuration
        )
    }
}
