import Foundation

/// One entry in the recently-played list. The timestamp is what makes the list mergeable: a
/// bare `[Track]` carried its recency only as array position, which two devices cannot reconcile.
struct PlayedTrack: Codable, Equatable {
    var track: Track
    var playedAt: Date
}

/// Local listening history, most-recently-played first. Powers "Because you listened to…"
/// recommendation shelves and lets autoplay avoid immediately repeating a track.
@MainActor
final class PlayHistoryStore: ObservableObject {
    static let shared = PlayHistoryStore()

    @Published private(set) var tracks: [Track] = []
    private(set) var entries: [PlayedTrack] = []

    private let key = "play_history_v2"
    private let legacyKey = "play_history_v1"
    private let limit = 50

    private init() { load() }

    func record(_ track: Track) {
        entries.removeAll { $0.track.id == track.id }
        entries.append(PlayedTrack(track: track, playedAt: Date()))
        trim()
        rebuild()
        save()
    }

    /// Distinct recent tracks to seed recommendation shelves, most recent first.
    func recentSeeds(_ count: Int) -> [Track] {
        Array(tracks.prefix(count))
    }

    /// Folds in the peer's recently-played. Union by `videoId`, keeping whichever device played
    /// it more recently — so Home's "jump back in" reflects listening on both.
    @discardableResult
    func merge(_ incoming: [PlayedTrack]) -> Int {
        var changed = 0
        for entry in incoming {
            if let index = entries.firstIndex(where: { $0.track.id == entry.track.id }) {
                guard entry.playedAt > entries[index].playedAt else { continue }
                entries[index].playedAt = entry.playedAt
                changed += 1
            } else {
                entries.append(entry)
                changed += 1
            }
        }
        guard changed > 0 else { return 0 }
        trim()
        rebuild()
        save()
        return changed
    }

    private func trim() {
        entries.sort { $0.playedAt > $1.playedAt }
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    private func rebuild() {
        // Deduped on the way out as well as in. `record` keeps the array unique, but a blob
        // written by an older build (or restored from a backup) can contain the same videoId
        // twice — and `recentSeeds` feeds those straight into `RecommendationsBuilder`, where a
        // duplicate key used to trap and crash the app on every visit to Home.
        var seen = Set<String>()
        tracks = entries.filter { seen.insert($0.track.id).inserted }.map(\.track)
    }

    private func load() {
        if let decoded = DefaultsSnapshot.load([PlayedTrack].self, forKey: key) {
            entries = decoded
            trim()
            rebuild()
            return
        }
        guard let legacy = DefaultsSnapshot.load([Track].self, forKey: legacyKey) else { return }
        // Position was the only recency information v1 carried; synthetic descending times
        // preserve exactly that ordering and claim nothing more precise.
        let base = Date()
        entries = legacy.enumerated().map { offset, track in
            PlayedTrack(track: track, playedAt: base.addingTimeInterval(-Double(offset)))
        }
        trim()
        rebuild()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
