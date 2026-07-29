import Foundation

/// Local listening history, most-recently-played first. Powers "Because you listened to…"
/// recommendation shelves and lets autoplay avoid immediately repeating a track.
@MainActor
final class PlayHistoryStore: ObservableObject {
    static let shared = PlayHistoryStore()

    @Published private(set) var tracks: [Track] = []
    private let key = "play_history_v1"
    private let limit = 50

    private init() { load() }

    func record(_ track: Track) {
        tracks.removeAll { $0.id == track.id }
        tracks.insert(track, at: 0)
        if tracks.count > limit { tracks.removeLast(tracks.count - limit) }
        save()
    }

    /// Distinct recent tracks to seed recommendation shelves, most recent first.
    func recentSeeds(_ count: Int) -> [Track] {
        Array(tracks.prefix(count))
    }

    private func load() {
        guard let decoded = DefaultsSnapshot.load([Track].self, forKey: key) else { return }
        // Deduped on the way *out* as well as on the way in. `record` keeps the live array
        // unique, but a blob written by an older build (or restored from a backup) can
        // contain the same videoId twice — and `recentSeeds` feeds those straight into
        // `RecommendationsBuilder`, where a duplicate key used to trap and crash the app
        // on every visit to Home.
        var seen = Set<String>()
        tracks = decoded.filter { seen.insert($0.id).inserted }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
