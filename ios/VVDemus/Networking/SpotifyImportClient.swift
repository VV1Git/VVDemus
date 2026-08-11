import Foundation

/// One song as Spotify's embed page describes it. `artist` is Spotify's `subtitle` verbatim,
/// which for several artists is comma-joined ("Shakira, Burna Boy") — the same shape
/// `InnerTubeClient.parseSearchItem` produces for a YouTube result, so the matcher can
/// compare the two sides symmetrically instead of guessing at one of them.
struct SpotifyTrack: Equatable {
    let title: String
    let artist: String
    /// Milliseconds, because that is the unit Spotify sends. Nil when Spotify didn't say —
    /// which includes the literal `0` it uses to mean "unknown", since a zero-length song
    /// would make any duration-aware scorer reject every candidate it is offered.
    let durationMs: Int?
}

struct SpotifyPlaylistPage: Equatable {
    let name: String
    let tracks: [SpotifyTrack]

    /// The embed hands back at most 100 tracks and never says how many it left behind —
    /// three playlists of 150-200 songs all came back with exactly 100 — and Spotify has
    /// closed the anonymous token endpoint, so there is no unauthenticated way to page past
    /// it. At exactly 100 the honest answer is "there may be more", which is what the
    /// summary tells the user; below 100 the playlist demonstrably ended.
    var isPossiblyTruncated: Bool { tracks.count >= SpotifyImportClient.embedTrackLimit }
}

/// Why an import couldn't start. Deliberately four cases and not one string: the sheet has to
/// say something different for "you pasted an album link" than for "Spotify reshaped their
/// page", and only the second is a bug report.
enum SpotifyImportError: LocalizedError, Equatable {
    case notAPlaylistLink
    /// Private, deleted, or otherwise not served to an anonymous visitor.
    case notAvailable
    /// The page arrived but could not be read — the `__NEXT_DATA__` tag is gone, its JSON is
    /// malformed, or the entity is no longer shaped the way it was. This is the one that
    /// means the parser needs updating.
    case unreadable
    /// Nothing usable came back from the network at all.
    case network

    var errorDescription: String? {
        switch self {
        case .notAPlaylistLink:
            return "That doesn't look like a Spotify playlist link."
        case .notAvailable:
            return "Spotify won't share that playlist. It may be private, or it may be gone."
        case .unreadable:
            return "Spotify changed how that page is built, so the playlist couldn't be read."
        case .network:
            return "Couldn't reach Spotify. Check your connection and try again."
        }
    }
}

/// Reads a public Spotify playlist out of the page Spotify serves to embed widgets.
///
/// There is no API key here on purpose. `open.spotify.com/embed/playlist/<id>` is a plain
/// server-rendered Next.js page whose entire state — playlist name, every track, every
/// duration — sits in a `<script id="__NEXT_DATA__">` tag, and it needs no token. That page
/// is Spotify's to change at any time, so fetching and parsing are split the way
/// `VisitorDataProvider` splits them: `parse(html:)` is pure and every shape failure it can
/// hit is asserted in `SpotifyEmbedParsingTests` without a network.
enum SpotifyImportClient {

    /// The ceiling the embed enforces. See `SpotifyPlaylistPage.isPossiblyTruncated`.
    static let embedTrackLimit = 100

    /// What a playlist is called when Spotify sends no name. Reaching this should be rare,
    /// but failing the whole import over a missing title would throw away fifty songs that
    /// parsed perfectly, and the sheet lets the user type their own name anyway.
    static let fallbackPlaylistName = "Spotify Playlist"

    // MARK: - Parsing

    /// Pulls the playlist out of an embed page. Pure: no network, no clock, no globals.
    static func parse(html: String) throws -> SpotifyPlaylistPage {
        guard let payload = nextDataPayload(in: html) else { throw SpotifyImportError.unreadable }

        let decoded: EmbedPayload
        do {
            decoded = try JSONDecoder().decode(EmbedPayload.self, from: Data(payload.utf8))
        } catch {
            throw SpotifyImportError.unreadable
        }

        // A playlist that is private or deleted answers **HTTP 200** with a complete, valid
        // page whose `data` object is simply `{}` (verified against
        // `/embed/playlist/0000000000000000000000`, which is a 200). So the status code can
        // never produce `.notAvailable` on its own — the absent entity is the only evidence
        // there is, and reporting it as `.unreadable` would send a user who pasted a private
        // playlist off to report a parser bug that doesn't exist.
        guard let entity = decoded.props.pageProps.state.data.entity else {
            throw SpotifyImportError.notAvailable
        }

        // An album embed carries a perfectly good `trackList` of its own — 18 tracks, in the
        // page checked while writing this — so without the type check an album link that got
        // past `SpotifyPlaylistLink` would import silently and look like it had worked.
        guard entity.type == "playlist" else { throw SpotifyImportError.unreadable }

        // `trackList` missing is a shape change; `trackList: []` is an empty playlist, which
        // is a thing a user can really paste. Collapsing the two would make a Spotify rename
        // of that key look like an unbroken run of empty imports.
        guard let rows = entity.trackList else { throw SpotifyImportError.unreadable }

        let name = [entity.name, entity.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? fallbackPlaylistName

        let tracks = rows.compactMap { row -> SpotifyTrack? in
            // A row with no title gives the matcher nothing to search for, and an empty query
            // returns whatever YouTube feels like — which would be a stranger's song added to
            // the user's playlist under a name they never saw.
            guard let title = normalized(row.title), !title.isEmpty else { return nil }
            // `isPlayable: false` is deliberately ignored rather than filtered on. It means
            // the track is region-blocked *on Spotify*, which says nothing at all about
            // YouTube Music; dropping those rows would silently lose songs the user can
            // actually have. If one turns out to be unfindable it is reported as a miss like
            // any other, which is the honest outcome instead of a quiet one.
            return SpotifyTrack(
                title: title,
                artist: normalized(row.subtitle) ?? "",
                durationMs: row.durationMs.flatMap { $0 > 0 ? $0 : nil }
            )
        }

        return SpotifyPlaylistPage(name: name, tracks: tracks)
    }

    /// Trimmed, with the spaces that only look like spaces turned into real ones.
    ///
    /// Spotify joins several artists with a comma and a **non-breaking** space: the captured
    /// page's "Shakira, Burna Boy" is `Shakira,\u{00A0}Burna Boy`. Left alone it defeats every
    /// obvious thing the next stage wants to do — the string never equals YouTube's
    /// comma-joined "Shakira, Burna Boy", and the search query carries a U+00A0 into a URL for
    /// no reason. It is invisible in a debugger and in test output, so it would have been
    /// found as "multi-artist songs just never match" months later. Folded here, once, where
    /// the page's quirks belong.
    private static func normalized(_ text: String?) -> String? {
        text?
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The contents of the `__NEXT_DATA__` script tag.
    ///
    /// Matched by attribute rather than by an exact opening tag: Spotify owns this markup and
    /// a build change that reorders `id` and `type`, adds a CSP nonce, or switches to single
    /// quotes must not cost the user their import. The capture is non-greedy so it stops at
    /// the first `</script>` — safe because Next.js escapes `<` as `\u003c` inside the
    /// payload precisely so that a song titled "</script>" cannot end the tag early.
    static func nextDataPayload(in html: String) -> String? {
        let pattern = #"<script\b[^>]*\bid\s*=\s*["']__NEXT_DATA__["'][^>]*>([\s\S]*?)</script\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let payload = html[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
    }

    // MARK: - Fetching

    /// A desktop Chrome UA, matching `VisitorDataProvider.webUserAgent`.
    ///
    /// Worth recording what was actually measured, because the received wisdom is wrong here:
    /// on 2026-08-10 this endpoint returned the byte-identical 84,487-byte page with a desktop
    /// UA, with curl's own UA, and with the header suppressed entirely — Spotify does *not*
    /// serve a reduced embed to an unidentified client today. The header is sent anyway
    /// because it costs one line, it is what the rest of this app already does, and a client
    /// that refuses to name itself is the first thing an anti-bot rule turns away when one
    /// eventually appears.
    private static let webUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/131.0.0.0 Safari/537.36"

    /// Built separately from being sent so the URL and headers can be asserted without a
    /// network, the way `InnerTubeClient.makeRequest` is.
    static func makeRequest(playlistId: String) throws -> URLRequest {
        let trimmed = playlistId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://open.spotify.com/embed/playlist/\(escaped)") else {
            throw SpotifyImportError.notAPlaylistLink
        }
        var request = URLRequest(url: url)
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        return request
    }

    static func fetch(playlistId: String) async throws -> SpotifyPlaylistPage {
        try parse(html: try await fetchHTML(makeRequest(playlistId: playlistId)))
    }

    /// Mirrors the retry shape of `InnerTubeClient.send` — same attempt count, same
    /// `RateLimit` decisions — but deliberately does **not** touch `RateLimitGate.shared`.
    /// That gate is process-wide and is what holds YouTube's searches back; letting a Spotify
    /// 429 close it would stall a service that never complained, and letting a successful
    /// Spotify fetch clear it would reopen YouTube's floodgate early on evidence from an
    /// entirely different host.
    private static func fetchHTML(_ request: URLRequest) async throws -> String {
        for attempt in 1...RateLimit.maximumAttempts {
            do {
                // `NetworkSessions.api` rather than `URLSession.shared`: it is the only path
                // whose bytes reach `NetworkByteCounter`, and it carries the bounded timeouts
                // that stop a captive portal turning an import into a minute of nothing.
                let (data, response) = try await NetworkSessions.api.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw SpotifyImportError.network }

                if (200..<300).contains(http.statusCode) {
                    guard let html = String(data: data, encoding: .utf8) else {
                        throw SpotifyImportError.unreadable
                    }
                    return html
                }
                // Spotify uses 404 for a deleted playlist and 401/403 for one that exists but
                // isn't ours to see. None of the three is worth a second attempt.
                if [401, 403, 404, 410].contains(http.statusCode) {
                    throw SpotifyImportError.notAvailable
                }
                // A 5xx from Spotify is reported as `.network` rather than `.unreadable`: the
                // page did not change, it did not arrive, and "Spotify changed their page"
                // would send whoever reads the report hunting a parser bug that isn't there.
                guard RateLimit.isRetryable(status: http.statusCode),
                      attempt < RateLimit.maximumAttempts else {
                    throw SpotifyImportError.network
                }
            } catch let error as SpotifyImportError {
                throw error
            } catch let urlError as URLError {
                // The user pressing Cancel arrives here as `.cancelled`. Surfacing that as
                // "couldn't reach Spotify" would blame the network for something they did.
                if urlError.code == .cancelled { throw CancellationError() }
                guard RateLimit.isRetryable(urlError: urlError),
                      attempt < RateLimit.maximumAttempts else {
                    throw SpotifyImportError.network
                }
            }
            try await Task.sleep(
                nanoseconds: UInt64(RateLimit.backoffDelay(attempt: attempt) * 1_000_000_000))
        }
        throw SpotifyImportError.network
    }

    // MARK: - The shape of the page

    /// Codable mirrors of only the four levels that matter. Everything Spotify sends
    /// alongside — cover art, visual identity, audio previews — is left undeclared so that
    /// adding to or removing from it cannot fail an import.
    private struct EmbedPayload: Decodable {
        let props: Props

        struct Props: Decodable {
            let pageProps: PageProps
        }

        struct PageProps: Decodable {
            let state: State
        }

        struct State: Decodable {
            let data: PageData
        }

        struct PageData: Decodable {
            let entity: Entity?
        }

        struct Entity: Decodable {
            let type: String?
            let name: String?
            let title: String?
            let trackList: [Row]?
        }

        struct Row: Decodable {
            let title: String?
            let subtitle: String?
            let durationMs: Int?

            private enum CodingKeys: String, CodingKey {
                case title, subtitle, duration
            }

            /// Hand-written rather than synthesised so that one field arriving in an
            /// unexpected type costs that field and not the whole playlist. `duration` is the
            /// one that has actually varied — an integer on the pages captured here, a
            /// quoted number on at least one other variant — and a hundred songs is far too
            /// much to lose over the difference between `223448` and `"223448"`.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
                subtitle = (try? container.decodeIfPresent(String.self, forKey: .subtitle)) ?? nil
                if let milliseconds = (try? container.decodeIfPresent(Int.self, forKey: .duration)) ?? nil {
                    durationMs = milliseconds
                } else {
                    let text = (try? container.decodeIfPresent(String.self, forKey: .duration)) ?? nil
                    durationMs = text.flatMap(Int.init)
                }
            }
        }
    }
}
