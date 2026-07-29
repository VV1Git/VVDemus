import Foundation

/// Supplies the anonymous `visitorData` session token that YouTube's player endpoint
/// expects. Without one, stream resolution is refused as bot traffic.
///
/// Measured against five videos, three attempts each: **3/15 requests succeeded with no
/// token, 15/15 with one.** The failures are the "Sign in to confirm you're not a bot"
/// refusal, and they are deterministic per video rather than random — retrying the same
/// request with the same (absent) token never once recovered, so this is not something a
/// retry loop can paper over. That refusal is what silently pushed every track onto the
/// muxed-video fallback at ~3.9x the data.
///
/// The token is anonymous. It identifies a browsing session, not a person, and no account,
/// login or cookie is involved — YouTube hands one to any unauthenticated visitor.
actor VisitorDataProvider {
    static let shared = VisitorDataProvider()

    static let defaultsKey = "innertube_visitor_data_v1"
    static let fetchedAtDefaultsKey = "innertube_visitor_data_fetched_at_v1"

    /// Refetched after this long even while it still appears to be working. Tokens embed
    /// their own issue time and YouTube expires them server-side on its own schedule;
    /// re-fetching daily is far cheaper than discovering staleness during playback.
    static let maxAge: TimeInterval = 24 * 3600

    /// Where a token comes from. Two sources, deliberately:
    ///
    /// - `sw.js_data` is **2.7 KB** and the token has to be picked out by shape, because
    ///   it sits at an unnamed position in an undocumented JSON array.
    /// - The homepage is **822 KB** — 300x more — but spells the token out under a
    ///   `"visitorData"` key, so extracting it can't silently grab the wrong string.
    ///
    /// Normal fetches take the cheap one. A refresh forced by a refusal escalates to the
    /// authoritative one, so a shape-match that quietly captured the wrong blob costs one
    /// bad resolve rather than wedging playback permanently.
    enum Source {
        case cheap
        case authoritative
    }

    typealias Fetcher = @Sendable (Source) async throws -> String

    private let defaults: UserDefaults
    private let fetch: Fetcher
    private let now: @Sendable () -> Date

    private var cached: String?
    private var fetchedAt: Date?
    private var inFlight: Task<String, Error>?

    init(
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init,
        fetch: @escaping Fetcher = VisitorDataProvider.fetchFromYouTube
    ) {
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
        cached = defaults.string(forKey: Self.defaultsKey)
        let stamp = defaults.double(forKey: Self.fetchedAtDefaultsKey)
        fetchedAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// The current token, fetching one only if there isn't a fresh one already.
    func current() async throws -> String {
        if let cached, let fetchedAt, now().timeIntervalSince(fetchedAt) < Self.maxAge {
            return cached
        }
        return try await refresh(from: .cheap)
    }

    /// Best-effort variant: resolution should still be *attempted* without a token when
    /// the network is flaky, since a few videos do answer bare.
    func currentIfAvailable() async -> String? {
        try? await current()
    }

    /// A token from the requested source, best-effort.
    ///
    /// Asking for the authoritative one is itself the signal that the last token was
    /// refused, so it discards the current one first — otherwise the cached bad token
    /// would just be handed straight back and the retry would be pointless.
    func token(for source: Source) async -> String? {
        switch source {
        case .cheap:
            return try? await current()
        case .authoritative:
            invalidate()
            return try? await refresh(from: .authoritative)
        }
    }

    /// Throws the token away after YouTube refused a request carrying it.
    func invalidate() {
        cached = nil
        fetchedAt = nil
        defaults.removeObject(forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.fetchedAtDefaultsKey)
    }

    @discardableResult
    func refresh(from source: Source) async throws -> String {
        // Coalesced. Starting a queue resolves several tracks at once, and each one
        // independently fetching a token would multiply both the requests and the bytes.
        if let inFlight {
            return try await inFlight.value
        }
        let fetch = self.fetch
        let task = Task { try await fetch(source) }
        inFlight = task
        defer { inFlight = nil }

        let token = try await task.value
        let stamp = now()
        cached = token
        fetchedAt = stamp
        defaults.set(token, forKey: Self.defaultsKey)
        defaults.set(stamp.timeIntervalSince1970, forKey: Self.fetchedAtDefaultsKey)
        return token
    }

    // MARK: - Fetching

    private static let webUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    static let fetchFromYouTube: Fetcher = { source in
        let urlString: String
        switch source {
        case .cheap: urlString = "https://www.youtube.com/sw.js_data"
        case .authoritative: urlString = "https://www.youtube.com/"
        }
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await NetworkSessions.api.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server("Could not reach YouTube for a visitor token")
        }
        guard let body = String(data: data, encoding: .utf8),
              let token = parseToken(from: body, source: source) else {
            throw APIError.server("No visitor token in YouTube's response")
        }
        return token
    }

    /// Pulls the token out of a response body. Separated from the networking so the
    /// parsing — the part that breaks when YouTube reshapes a page — is directly testable.
    static func parseToken(from body: String, source: Source) -> String? {
        let token: String?
        switch source {
        case .authoritative:
            token = firstCapture(in: body, pattern: #""visitorData":"([^"]+)""#)
                .flatMap(jsonUnescaped)
        case .cheap:
            // Matched by shape: base64url beginning "Cg". Deliberately `[^"]` rather than
            // a strict character class — these tokens carry `=` / `%3D` padding, and a
            // stricter class stopped short of the closing quote and matched nothing.
            token = firstCapture(in: body, pattern: #""(Cg[^"]{20,})""#)
        }
        guard let token, !token.isEmpty else { return nil }
        return token
    }

    private static func firstCapture(in body: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: body,
                range: NSRange(body.startIndex..., in: body)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: body)
        else { return nil }
        return String(body[range])
    }

    /// The homepage's value is JSON-escaped inside the page's own JSON (`=` and
    /// friends), so it has to be decoded rather than used literally.
    private static func jsonUnescaped(_ raw: String) -> String? {
        try? JSONDecoder().decode(String.self, from: Data("\"\(raw)\"".utf8))
    }
}
