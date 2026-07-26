import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid request URL"
        case .server(let message): return message
        }
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

    func home() async throws -> [Track] {
        try await InnerTubeClient.home()
    }

    func stream(videoId: String) async throws -> StreamInfo {
        let safetyMargin: TimeInterval = 300
        streamCacheLock.lock()
        let cached = streamCache[videoId]
        streamCacheLock.unlock()
        if let cached, cached.expiresAt - safetyMargin > Date().timeIntervalSince1970 {
            return cached
        }
        let fresh = try await InnerTubeClient.stream(videoId: videoId)
        streamCacheLock.lock()
        streamCache[videoId] = fresh
        streamCacheLock.unlock()
        return fresh
    }

    /// YouTube Music's "radio" for a track: the seed track followed by similar songs.
    func radio(videoId: String, limit: Int = 50) async throws -> [Track] {
        try await InnerTubeClient.radio(videoId: videoId, limit: limit)
    }
}
