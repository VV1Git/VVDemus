import Foundation

/// Caches each radio's fetched track list locally, so revisiting a radio you've already
/// loaded before still shows something when offline instead of a blocked/blank screen.
@MainActor
final class RadioCacheStore: ObservableObject {
    static let shared = RadioCacheStore()

    private let key = "radio_track_cache_v1"
    private let limit = 20
    private var cache: [String: [Track]] = [:]
    private var order: [String] = []

    /// Fired whenever a radio's track list changes (from either the phone's own refresh
    /// or one requested over the local control server) — lets LocalControlServer push the
    /// update to any connected browser so the two stay in sync instead of drifting apart.
    var onUpdate: ((_ seedVideoId: String, _ tracks: [Track]) -> Void)?

    private init() { load() }

    func tracks(for seedVideoId: String) -> [Track]? {
        cache[seedVideoId]
    }

    func store(_ tracks: [Track], for seedVideoId: String) {
        cache[seedVideoId] = tracks
        order.removeAll { $0 == seedVideoId }
        order.append(seedVideoId)
        while order.count > limit {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        save()
        onUpdate?(seedVideoId, tracks)
    }

    private struct Snapshot: Codable {
        let cache: [String: [Track]]
        let order: [String]
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        cache = snapshot.cache
        order = snapshot.order
    }

    private func save() {
        let snapshot = Snapshot(cache: cache, order: order)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
