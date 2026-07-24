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

/// Talks to the local VVDemus FastAPI backend (see backend/app/main.py).
final class APIClient {
    static let shared = APIClient()

    static let baseURLDefaultsKey = "backend_base_url"
    /// Simulator reaches the Mac's own localhost via 127.0.0.1; a physical device can't, so it
    /// needs the Mac's LAN IP instead (set from Settings — see BackendSettingsView).
    static let defaultBaseURL = "http://127.0.0.1:8000"

    var baseURL: URL = {
        if let saved = UserDefaults.standard.string(forKey: APIClient.baseURLDefaultsKey),
           let url = URL(string: saved) {
            return url
        }
        return URL(string: APIClient.defaultBaseURL)!
    }()

    private let session: URLSession = .shared
    private let decoder = JSONDecoder()

    func search(_ query: String, limit: Int = 25) async throws -> [Track] {
        try await get("/search", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
    }

    func home() async throws -> [Track] {
        try await get("/home")
    }

    struct Health: Decodable { let ok: Bool }

    func healthCheck() async throws -> Bool {
        let health: Health = try await get("/health")
        return health.ok
    }

    func playlist(_ id: String) async throws -> [Track] {
        try await get("/playlist/\(id)")
    }

    func stream(videoId: String) async throws -> StreamInfo {
        try await get("/stream/\(videoId)")
    }

    /// YouTube Music's "radio" for a track: the seed track followed by similar songs.
    func radio(videoId: String, limit: Int = 30) async throws -> [Track] {
        try await get("/radio/\(videoId)", query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { throw APIError.invalidURL }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.invalidURL }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Request failed"
            throw APIError.server(message)
        }
        return try decoder.decode(T.self, from: data)
    }
}
