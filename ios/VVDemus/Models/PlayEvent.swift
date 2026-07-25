import Foundation

/// One completed/started play, timestamped — the raw log behind listening stats.
struct PlayEvent: Codable {
    let track: Track
    let playedAt: Date
    let secondsPlayed: Int

    init(track: Track, playedAt: Date, secondsPlayed: Int) {
        self.track = track
        self.playedAt = playedAt
        self.secondsPlayed = secondsPlayed
    }

    /// Custom decoding so history logged before `secondsPlayed` existed still loads —
    /// those old entries fall back to the track's full nominal length.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        track = try container.decode(Track.self, forKey: .track)
        playedAt = try container.decode(Date.self, forKey: .playedAt)
        secondsPlayed = try container.decodeIfPresent(Int.self, forKey: .secondsPlayed) ?? (track.durationSeconds ?? 0)
    }
}
