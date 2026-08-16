import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case server(String)
    /// Carries the status code so callers can tell a transient failure from a permanent
    /// one — a 403 on a stream URL means "expired, re-resolve", which is not something a
    /// generic error message can express.
    case http(status: Int)
    /// YouTube asked us to slow down (HTTP 429), after the request layer had already retried
    /// and waited as long as it usefully could. Distinct from `.http(status: 429)` because
    /// this is the one failure where the honest thing to tell the user is *when* to try
    /// again, and "check your connection" is actively misleading.
    case rateLimited(retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid request URL"
        case .server(let message): return message
        case .http(let status): return "YouTube request failed (HTTP \(status))"
        case .rateLimited(let retryAfter):
            guard let retryAfter, retryAfter >= 1 else {
                return "YouTube Music is limiting requests. Try again in a moment."
            }
            return "YouTube Music is limiting requests. Try again in \(Int(retryAfter.rounded(.up)))s."
        }
    }

    /// Whether this is the rate limit, without every call site having to write out the
    /// pattern match. Used to pick the message Home and Search show.
    var isRateLimit: Bool {
        if case .rateLimited = self { return true }
        if case .http(let status) = self, status == 429 { return true }
        return false
    }
}

/// Talks directly to YouTube Music (see InnerTubeClient) — no local backend server needed,
/// so the app works over any network the phone is on.
final class APIClient {
    static let shared = APIClient()

    /// Avoids re-resolving a stream URL that was just fetched moments ago (e.g. pressing
    /// "previous" back onto a track played earlier this session, or switching the active
    /// playback device back and forth) — `StreamInfo.expiresAt` already existed but was
    /// never actually checked anywhere before this. Guarded by a plain lock rather than an
    /// actor since this is called from both the main actor (PlayerService) and
    /// LocalControlServer's background Swifter threads via its synchronous bridge.
    private let streamCacheLock = NSLock()
    private var streamCache: [String: StreamInfo] = [:]

    func search(_ query: String, limit: Int = 25) async throws -> [Track] {
        try await InnerTubeClient.search(query: query, limit: limit)
    }

    /// The releases matching a query. Run concurrently with `search` — see the note on
    /// `InnerTubeClient.searchAlbums` for why it is a second request rather than one
    /// unfiltered one.
    func searchAlbums(_ query: String, limit: Int = 4) async throws -> [Album] {
        try await InnerTubeClient.searchAlbums(query: query, limit: limit)
    }

    /// One release's page: its tracks, plus the fuller metadata the album page carries.
    func album(browseId: String) async throws -> InnerTubeClient.AlbumPage {
        try await InnerTubeClient.album(browseId: browseId)
    }

    func home() async throws -> [Track] {
        try await InnerTubeClient.home()
    }

    func stream(videoId: String) async throws -> StreamInfo {
        if let cached = cachedStream(videoId: videoId) { return cached }
        let fresh = try await InnerTubeClient.stream(videoId: videoId)
        streamCacheLock.lock()
        streamCache[videoId] = fresh
        // Bounded: entries were only ever added, including long-dead ones, so this grew
        // for the whole session.
        if streamCache.count > 128 {
            let expired = streamCache.filter { $0.value.expiresAt <= Date().timeIntervalSince1970 }
            for key in expired.keys { streamCache.removeValue(forKey: key) }
        }
        streamCacheLock.unlock()
        return fresh
    }

    static let streamExpirySafetyMargin: TimeInterval = 300

    private func cachedStream(videoId: String) -> StreamInfo? {
        streamCacheLock.lock()
        defer { streamCacheLock.unlock() }
        guard let cached = streamCache[videoId] else { return nil }
        guard cached.expiresAt - Self.streamExpirySafetyMargin > Date().timeIntervalSince1970 else {
            streamCache.removeValue(forKey: videoId)
            return nil
        }
        return cached
    }

    /// Drops a URL that turned out not to work. Without this, a stream that 403'd was
    /// re-served from the cache on every retry until it expired on paper — so "press play
    /// again" could not possibly fix it.
    func invalidateStream(videoId: String) {
        streamCacheLock.lock()
        streamCache.removeValue(forKey: videoId)
        streamCacheLock.unlock()
    }

    /// YouTube Music's "radio" for a track: the seed track followed by similar songs.
    func radio(videoId: String, limit: Int = InnerTubeClient.radioLength) async throws -> [Track] {
        try await InnerTubeClient.radio(videoId: videoId, limit: limit)
    }
}
