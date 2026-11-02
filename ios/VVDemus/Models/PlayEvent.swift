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

/// The most-played songs or artists among some plays, in an order that holds still.
///
/// Counting goes through a `Dictionary`, whose order is different every time one is built, and
/// a sort on the count alone leaves ties in whatever order they arrived — so tied entries
/// swapped places on every redraw, and at a tie for tenth, which of them made the list did too.
/// Ties are broken by the more recently played, then by key, so the same plays always rank
/// the same way.
enum PlayRanking {
    struct Entry<Key: Hashable> {
        let key: Key
        let count: Int
        let lastPlayed: Date
    }

    static func top<Key: Hashable & Comparable>(
        _ events: [PlayEvent], by key: (PlayEvent) -> Key, limit: Int
    ) -> [Entry<Key>] {
        var counts: [Key: Int] = [:]
        var last: [Key: Date] = [:]
        for event in events {
            let k = key(event)
            counts[k, default: 0] += 1
            last[k] = max(last[k] ?? .distantPast, event.playedAt)
        }
        return counts
            .map { Entry(key: $0.key, count: $0.value, lastPlayed: last[$0.key] ?? .distantPast) }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                if a.lastPlayed != b.lastPlayed { return a.lastPlayed > b.lastPlayed }
                return a.key < b.key
            }
            .prefix(limit)
            .map { $0 }
    }
}
