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

    /// Simulator reaches the Mac's own localhost via 127.0.0.1.
    /// For a physical device, point this at your Mac's LAN IP instead (e.g. "http://192.168.1.23:8000").
    var baseURL = URL(string: "http://127.0.0.1:8000")!

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

    func playlist(_ id: String) async throws -> [Track] {
        try await get("/playlist/\(id)")
    }

    func stream(videoId: String) async throws -> StreamInfo {
        try await get("/stream/\(videoId)")
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
