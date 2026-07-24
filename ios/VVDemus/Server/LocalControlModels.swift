import Foundation

/// JSON snapshot of PlayerService's state, sent to the web UI both as a plain GET
/// response and periodically over the WebSocket for live sync.
struct StateSnapshot: Codable {
    let isPlaying: Bool
    let isLoading: Bool
    let progress: Double
    let duration: Double
    let isShuffling: Bool
    let hasPrevious: Bool
    let queueContextTitle: String?
    let currentTrack: Track?
    let manualQueue: [Track]
    let contextQueue: [Track]
    let likedVideoIds: [String]
}

struct DaylistSnapshot: Codable {
    let title: String
    let tracks: [Track]
}

// MARK: - Request bodies

struct PlayRequestBody: Decodable {
    let track: Track
    let context: [Track]?
    let contextTitle: String?
}

struct SeekRequestBody: Decodable {
    let seconds: Double
}

struct TrackOnlyBody: Decodable {
    let track: Track
}

struct VideoIdBody: Decodable {
    let videoId: String
}

struct RadioPlayBody: Decodable {
    let seedTrack: Track
    let shuffled: Bool?
}

struct CreatePlaylistBody: Decodable {
    let name: String
}

struct AddToPlaylistBody: Decodable {
    let track: Track
}
