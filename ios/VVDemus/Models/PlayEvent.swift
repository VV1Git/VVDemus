import Foundation

/// One completed/started play, timestamped — the raw log behind listening stats.
struct PlayEvent: Codable {
    let track: Track
    let playedAt: Date
    let secondsPlayed: Int
    /// The peer id of the device the play happened on, or nil for one logged before devices
    /// could be linked in groups.
    ///
    /// What lets a sync round ask for "everything of yours after this" one device at a time —
    /// see `EventMarks`. A single date stops being enough as soon as plays can arrive by way of
    /// a third device.
    let origin: String?

    init(track: Track, playedAt: Date, secondsPlayed: Int, origin: String? = nil) {
        self.track = track
        self.playedAt = playedAt
        self.secondsPlayed = secondsPlayed
        self.origin = origin
    }

    /// Custom decoding so history logged before `secondsPlayed` existed still loads —
    /// those old entries fall back to the track's full nominal length.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        track = try container.decode(Track.self, forKey: .track)
        playedAt = try container.decode(Date.self, forKey: .playedAt)
        secondsPlayed = try container.decodeIfPresent(Int.self, forKey: .secondsPlayed) ?? (track.durationSeconds ?? 0)
        origin = try container.decodeIfPresent(String.self, forKey: .origin)
    }
}
