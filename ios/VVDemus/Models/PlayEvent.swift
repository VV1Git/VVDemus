import Foundation

/// One completed/started play, timestamped — the raw log behind listening stats.
struct PlayEvent: Codable {
    let track: Track
    let playedAt: Date
}
