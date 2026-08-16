import Foundation

/// Each opened release's track list, kept locally so a revisit costs nothing and works
/// offline.
///
/// Simpler than `RadioCacheStore` in one way that matters: a radio is regenerated on every
/// call and two fetches disagree, which is the entire reason that store has a refresh path, a
/// `storeIfAbsent`, and a rule about who is allowed to overwrite whom. An album's tracklist
/// is a fixed fact about a record. Fetching it twice gives the same answer, so a cached album
/// is never stale and there is nothing to refresh — the only reason to fetch again is that
/// the first attempt failed, which leaves nothing cached and re-fetches on its own.
@MainActor
final class AlbumCacheStore: ObservableObject {
    static let shared = AlbumCacheStore()

    private let key = "album_track_cache_v1"
    private let limit = 20
    private var cache: [String: [Track]] = [:]
    private var order: [String] = []
    /// When each release's tracks were stored. Persisted, because it is what decides whose
    /// copy wins when two devices sync.
    private var storedAt: [String: Date] = [:]

    private init() { load() }

    func tracks(for browseId: String) -> [Track]? { cache[browseId] }

    func store(_ tracks: [Track], for browseId: String) {
        // An empty tracklist is a failed parse, not a record with no songs on it. Cached, it
        // would be served forever to a browser that cannot re-fetch on empty the way the app
        // can — the same trap `RadioCacheStore` fell into.
        guard !tracks.isEmpty else { return }
        cache[browseId] = tracks
        storedAt[browseId] = Date()
        order.removeAll { $0 == browseId }
        order.append(browseId)
        trimToLimit()
        save()
    }

    // MARK: - Sync

    /// One record per cached release, so an album opened on the phone opens instantly on the
    /// Mac instead of costing it its own InnerTube round trip.
    func syncRecords() -> [GeneratedRecord] {
        cache.compactMap { browseId, tracks in
            guard let data = try? JSONEncoder().encode(tracks) else { return nil }
            let when = storedAt[browseId] ?? .distantPast
            return GeneratedRecord(
                id: Self.recordPrefix + browseId,
                payload: data,
                generatedAt: when,
                stamp: EditStamp(editedAt: when, editedBy: PeerIdentityBox.currentPeerId)
            )
        }
    }

    @discardableResult
    func applySynced(_ record: GeneratedRecord) -> Bool {
        guard record.id.hasPrefix(Self.recordPrefix) else { return false }
        let browseId = String(record.id.dropFirst(Self.recordPrefix.count))
        if let existing = storedAt[browseId], record.generatedAt <= existing { return false }
        guard let tracks = try? JSONDecoder().decode([Track].self, from: record.payload),
              !tracks.isEmpty else { return false }
        let changed = cache[browseId] != tracks
        cache[browseId] = tracks
        storedAt[browseId] = record.generatedAt
        order.removeAll { $0 == browseId }
        order.append(browseId)
        trimToLimit()
        save()
        return changed
    }

    static let recordPrefix = "album_tracks:"

    private func trimToLimit() {
        while order.count > limit {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
            storedAt.removeValue(forKey: oldest)
        }
    }

    private struct Snapshot: Codable {
        let cache: [String: [Track]]
        let order: [String]
        var storedAt: [String: Date]?
    }

    private func load() {
        guard let snapshot = DefaultsSnapshot.load(Snapshot.self, forKey: key) else { return }
        cache = snapshot.cache
        order = snapshot.order
        storedAt = snapshot.storedAt ?? [:]
    }

    private func save() {
        let snapshot = Snapshot(cache: cache, order: order, storedAt: storedAt)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
