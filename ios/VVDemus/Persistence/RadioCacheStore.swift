import Foundation

/// Caches each radio's fetched track list locally, so revisiting a radio you've already
/// loaded before still shows something when offline instead of a blocked/blank screen.
@MainActor
final class RadioCacheStore: ObservableObject {
    static let shared = RadioCacheStore()

    private let key = "radio_track_cache_v2" // v1 entries hold years-as-durations
    private let limit = 20
    private var cache: [String: [Track]] = [:]
    private var order: [String] = []
    /// In-memory only (not persisted) — just needs to survive for the current app
    /// session, so revisiting the same radio screen repeatedly doesn't re-download its
    /// 50-track mix every time.
    private var lastFetched: [String: Date] = [:]

    /// Fired whenever a radio's track list changes (from either the phone's own refresh
    /// or one requested over the local control server) — lets LocalControlServer push the
    /// update to any connected browser so the two stay in sync instead of drifting apart.
    var onUpdate: ((_ seedVideoId: String, _ tracks: [Track]) -> Void)?

    private init() { load() }

    func tracks(for seedVideoId: String) -> [Track]? {
        cache[seedVideoId]
    }

    /// Whether `seedVideoId`'s cached mix was fetched recently enough to skip a re-fetch.
    func isFresh(_ seedVideoId: String, within interval: TimeInterval = 300) -> Bool {
        guard let fetchedAt = lastFetched[seedVideoId] else { return false }
        return Date().timeIntervalSince(fetchedAt) < interval
    }

    /// Replaces a radio's mix. This is the *deliberate* path — pulling to refresh, or the
    /// refresh button — and is the only thing that should ever change a list the user is
    /// looking at, since YouTube returns a different set of songs on every call.
    func store(_ tracks: [Track], for seedVideoId: String) {
        // Never cache an empty mix. A successful-but-empty response used to be stored and
        // then served indefinitely, so the browser's radio screen for that seed stayed
        // blank permanently — the phone re-fetches on empty, the browser cannot.
        guard !tracks.isEmpty else { return }
        let changed = cache[seedVideoId] != tracks
        cache[seedVideoId] = tracks
        lastFetched[seedVideoId] = Date()
        order.removeAll { $0 == seedVideoId }
        order.append(seedVideoId)
        while order.count > limit {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        save()
        // Only announce a real change — an identical refetch used to make every connected
        // browser rebuild the radio screen for nothing.
        if changed { onUpdate?(seedVideoId, tracks) }
    }

    /// Records a mix only if this radio has none yet.
    ///
    /// Background fetches — autoplay refilling the queue, a recommendation shelf being
    /// built — ask for their own, usually smaller, slice of a radio. Letting those write
    /// through meant a radio you had open could quietly swap its 50 songs for whatever 25
    /// autoplay happened to fetch, which read as the list reordering or losing tracks on
    /// its own. They now defer to whatever is already there.
    func storeIfAbsent(_ tracks: [Track], for seedVideoId: String) {
        guard cache[seedVideoId]?.isEmpty ?? true else { return }
        store(tracks, for: seedVideoId)
    }

    private struct Snapshot: Codable {
        let cache: [String: [Track]]
        let order: [String]
    }

    private func load() {
        guard let snapshot = DefaultsSnapshot.load(Snapshot.self, forKey: key) else { return }
        cache = snapshot.cache
        order = snapshot.order
    }

    private func save() {
        let snapshot = Snapshot(cache: cache, order: order)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
