import Foundation

struct Track: Identifiable, Codable, Equatable, Hashable {
    let videoId: String
    let title: String
    let artist: String
    let album: String?
    let thumbnailUrl: String?
    let durationSeconds: Int?

    var id: String { videoId }
}

struct StreamInfo: Codable {
    let videoId: String
    let url: String
    let expiresAt: Double
    let mimeType: String
}
