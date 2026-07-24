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

    func search(_ query: String, limit: Int = 25) async throws -> [Track] {
        try await InnerTubeClient.search(query: query, limit: limit)
    }

    func home() async throws -> [Track] {
        try await InnerTubeClient.home()
    }

    func stream(videoId: String) async throws -> StreamInfo {
        try await InnerTubeClient.stream(videoId: videoId)
    }

    /// YouTube Music's "radio" for a track: the seed track followed by similar songs.
    func radio(videoId: String, limit: Int = 30) async throws -> [Track] {
        try await InnerTubeClient.radio(videoId: videoId, limit: limit)
    }
}
