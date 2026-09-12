import Foundation

/// Caches each radio's fetched track list locally, so revisiting a radio you've already
/// loaded before still shows something when offline instead of a blocked/blank screen.
@MainActor
final class RadioCacheStore: ObservableObject {
    static let shared = RadioCacheStore()

    // v1 entries hold years-as-durations; v2 entries were whatever length the background
    // fetch that got there first asked for (10, 15 or 25), and nothing re-fetches a radio
    // that already has a cached mix — so without a bump they'd stay short forever.
    private let key = "radio_track_cache_v3"
    private let limit = 20
    private var cache: [String: [Track]] = [:]
    private var order: [String] = []
    /// In-memory only (not persisted) — just needs to survive for the current app
    /// session, so revisiting the same radio screen repeatedly doesn't re-download its
    /// 50-track mix every time.
    private var lastFetched: [String: Date] = [:]
    /// When each station's mix was actually stored. Unlike `lastFetched` this *is* persisted:
    /// it is what decides whose copy wins when the two devices sync.
    private var storedAt: [String: Date] = [:]

    // MARK: - Refresh bookkeeping
    //
    // What makes a refresh actually refresh. `RadioRefreshPolicy` promises that half a
    // station's songs are new every time and that nothing survives three refreshes; it can
    // only keep that promise if it is told, per station, which refresh introduced each song
    // and which songs have already been shown and retired.

    /// station → videoId → the refresh that introduced it.
    private var generations: [String: [String: Int]] = [:]
    /// How many times each station has been refreshed.
    private var refreshes: [String: Int] = [:]
    /// Which refresh each station last showed a song on, so a retired one is not offered
    /// straight back as "new". Bounded — see `seenLimit`.
    private var seen: [String: [ShownSong]] = [:]
    /// How far each station has paged into its own radio, so successive refreshes go deeper
    /// rather than re-reading page two forever. See `RadioFreshener`.
    private var continuations: [String: String] = [:]

    /// A song a station has shown, and the refresh it was last shown on.
    private struct ShownSong: Codable {
        let videoId: String
        var generation: Int
    }

    /// Six refreshes' worth of a 50-track station, give or take. A ceiling on memory rather
    /// than a policy — what may be shown again is decided by refresh count, below.
    private let seenLimit = 300

    /// How many refreshes a song is off limits for once it leaves the list.
    ///
    /// Four, which is one more than the three the guarantee spans: a song dropped at the
    /// first refresh must not come back at the third, or "nothing you started with survives
    /// three refreshes" would be kept with songs from the list it promises to clear. From the
    /// fourth on it may return — and it has to be able to, because YouTube's supply for one
    /// seed runs out around the fifth refresh in a sitting, and a station with nothing left
    /// to offer and no way back to its older material would answer "nothing new" forever.
    private let offLimitsRefreshes = RadioRefreshPolicy.carryOverGenerations + 2

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
    func store(_ tracks: [Track], for seedVideoId: String, continuation: String? = nil) {
        // Never cache an empty mix. A successful-but-empty response used to be stored and
        // then served indefinitely, so the browser's radio screen for that seed stayed
        // blank permanently — the phone re-fetches on empty, the browser cannot.
        guard !tracks.isEmpty else { return }
        let changed = cache[seedVideoId] != tracks
        cache[seedVideoId] = tracks
        lastFetched[seedVideoId] = Date()
        storedAt[seedVideoId] = Date()
        // A first mix is generation zero and starts the history over. This path is the
        // station being *built*, not refreshed — carrying an older station's generations or
        // its paging position into it would have the first refresh retire songs that only
        // arrived a second ago.
        generations[seedVideoId] = [:]
        refreshes[seedVideoId] = 0
        seen[seedVideoId] = tracks.map { ShownSong(videoId: $0.videoId, generation: 0) }
        continuations[seedVideoId] = continuation
        order.removeAll { $0 == seedVideoId }
        order.append(seedVideoId)
        trimToLimit()
        save()
        // Only announce a real change — an identical refetch used to make every connected
        // browser rebuild the radio screen for nothing.
        if changed { onUpdate?(seedVideoId, tracks) }
    }

    /// Records a mix only if this radio has none yet.
    ///
    /// Background fetches — autoplay refilling the queue, a recommendation shelf being
    /// built — pull a radio of their own for a seed someone may already be looking at.
    /// YouTube returns a different selection on every call, so letting those write through
    /// meant a radio you had open could quietly swap songs around, which read as the list
    /// reordering or losing tracks on its own. They now defer to whatever is already there.
    ///
    /// They all fetch the full `InnerTubeClient.radioLength` mix, so whichever gets there
    /// first still leaves a complete radio behind for the screen to show.
    func storeIfAbsent(_ tracks: [Track], for seedVideoId: String) {
        guard cache[seedVideoId]?.isEmpty ?? true else { return }
        store(tracks, for: seedVideoId)
    }

    // MARK: - Refresh

    /// Everything a refresh needs to read, in one hop onto the main actor.
    ///
    /// One value rather than five accessors because the refresh itself runs off this actor —
    /// it spends most of its time waiting on YouTube — and reading the pieces separately
    /// would let a second refresh (the web remote's, say) interleave between them and hand
    /// the policy a generation number that no longer matches the list it goes with.
    struct RefreshState {
        let tracks: [Track]
        let generations: [String: Int]
        /// The refresh about to happen, numbered from one.
        let generation: Int
        /// Shown within the last few refreshes: never offered as new.
        let recentlyShown: Set<String>
        /// Shown longer ago than that: offered again only as a last resort.
        let recyclable: Set<String>
        let continuation: String?
    }

    func refreshState(for seedVideoId: String) -> RefreshState {
        let generation = (refreshes[seedVideoId] ?? 0) + 1
        let history = seen[seedVideoId] ?? []
        let stale = generation - offLimitsRefreshes
        return RefreshState(
            tracks: cache[seedVideoId] ?? [],
            generations: generations[seedVideoId] ?? [:],
            generation: generation,
            recentlyShown: Set(history.filter { $0.generation > stale }.map(\.videoId)),
            recyclable: Set(history.filter { $0.generation <= stale }.map(\.videoId)),
            continuation: continuations[seedVideoId]
        )
    }

    /// Writes a refreshed mix along with the bookkeeping that makes the *next* refresh work.
    ///
    /// Separate from `store` because the two mean opposite things about history: `store`
    /// builds a station and starts its history over, this one advances it. Calling `store`
    /// here — which is what a refresh used to do — is precisely why nothing was ever
    /// remembered about what a station had already shown.
    func applyRefresh(
        _ tracks: [Track],
        generations newGenerations: [String: Int],
        generation: Int,
        continuation: String?,
        for seedVideoId: String
    ) {
        guard !tracks.isEmpty else { return }
        let changed = cache[seedVideoId] != tracks
        cache[seedVideoId] = tracks
        lastFetched[seedVideoId] = Date()
        storedAt[seedVideoId] = Date()
        generations[seedVideoId] = newGenerations
        refreshes[seedVideoId] = generation
        continuations[seedVideoId] = continuation
        rememberShown(tracks, generation: generation, for: seedVideoId)
        order.removeAll { $0 == seedVideoId }
        order.append(seedVideoId)
        trimToLimit()
        save()
        if changed { onUpdate?(seedVideoId, tracks) }
    }

    /// Records how far a station's paging got when the refresh it was for did not land.
    ///
    /// Without this a refresh that fell short re-walks the same exhausted pages next time and
    /// falls short again, forever.
    func rememberPagingPosition(_ continuation: String?, for seedVideoId: String) {
        guard cache[seedVideoId] != nil else { return }
        continuations[seedVideoId] = continuation
        save()
    }

    /// Records that `tracks` are on screen as of `generation`.
    ///
    /// A song already in the history has its generation moved forward rather than being
    /// appended again: what matters is when it was *last* shown, so a survivor of several
    /// refreshes does not become eligible to be re-offered while it is still on the screen.
    private func rememberShown(_ tracks: [Track], generation: Int, for seedVideoId: String) {
        var history = seen[seedVideoId] ?? []
        var positions = Dictionary(history.enumerated().map { ($0.element.videoId, $0.offset) },
                                   uniquingKeysWith: { first, _ in first })
        for track in tracks {
            if let index = positions[track.videoId] {
                history[index].generation = generation
            } else {
                positions[track.videoId] = history.count
                history.append(ShownSong(videoId: track.videoId, generation: generation))
            }
        }
        if history.count > seenLimit {
            // Oldest generations go first, so the cap never evicts something still off
            // limits while keeping something that is not.
            history.sort { $0.generation < $1.generation }
            history.removeFirst(history.count - seenLimit)
        }
        seen[seedVideoId] = history
    }

    // MARK: - Sync

    /// One record per cached station.
    ///
    /// `radio_history_v2` syncs *which* stations exist; this is what is actually in them.
    /// Without it a station arriving from the phone opens empty on the Mac and costs a fresh
    /// InnerTube round trip to fill — and YouTube returns a different mix each call, so the two
    /// devices would then be looking at different songs under the same station name.
    func syncRecords() -> [GeneratedRecord] {
        cache.compactMap { seedVideoId, tracks in
            guard let data = try? JSONEncoder().encode(tracks) else { return nil }
            let when = storedAt[seedVideoId] ?? .distantPast
            return GeneratedRecord(
                id: Self.recordPrefix + seedVideoId,
                payload: data,
                generatedAt: when,
                stamp: EditStamp(editedAt: when, editedBy: PeerIdentityBox.currentPeerId)
            )
        }
    }

    @discardableResult
    func applySynced(_ record: GeneratedRecord) -> Bool {
        guard record.id.hasPrefix(Self.recordPrefix) else { return false }
        let seedVideoId = String(record.id.dropFirst(Self.recordPrefix.count))
        if let existing = storedAt[seedVideoId], record.generatedAt <= existing { return false }
        guard let tracks = try? JSONDecoder().decode([Track].self, from: record.payload),
              !tracks.isEmpty else { return false }
        let changed = cache[seedVideoId] != tracks
        cache[seedVideoId] = tracks
        storedAt[seedVideoId] = record.generatedAt
        // The other device's mix arrives with no provenance — the refresh bookkeeping is
        // deliberately not synced (it is about this device's paging position). Clearing it
        // leaves `RadioRefreshPolicy` to treat these songs as one refresh old, so the next
        // refresh here may keep half of them and the one after that keeps none.
        generations[seedVideoId] = [:]
        continuations[seedVideoId] = nil
        rememberShown(tracks, generation: refreshes[seedVideoId] ?? 0, for: seedVideoId)
        order.removeAll { $0 == seedVideoId }
        order.append(seedVideoId)
        trimToLimit()
        save()
        if changed { onUpdate?(seedVideoId, tracks) }
        return changed
    }

    private static let recordPrefix = "radio_tracks:"

    private func trimToLimit() {
        while order.count > limit {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
            storedAt.removeValue(forKey: oldest)
            // The refresh bookkeeping is per station and would otherwise outlive every
            // station it describes — a dictionary that only ever grows, persisted.
            generations.removeValue(forKey: oldest)
            refreshes.removeValue(forKey: oldest)
            seen.removeValue(forKey: oldest)
            continuations.removeValue(forKey: oldest)
        }
    }

    private struct Snapshot: Codable {
        let cache: [String: [Track]]
        let order: [String]
        /// When each station's mix was fetched. Previously in-memory only; it has to persist
        /// now because it is what decides whose copy is newer at merge time.
        var storedAt: [String: Date]?
        /// The refresh bookkeeping, all optional so that a snapshot written before any of it
        /// existed still decodes. A key bump would have been the alternative, and it would
        /// have thrown away every cached station on this device to gain nothing: an old
        /// snapshot missing its history is exactly a station that has never been refreshed.
        var generations: [String: [String: Int]]?
        var refreshes: [String: Int]?
        var seen: [String: [ShownSong]]?
        var continuations: [String: String]?
    }

    private func load() {
        guard let snapshot = DefaultsSnapshot.load(Snapshot.self, forKey: key) else { return }
        cache = snapshot.cache
        order = snapshot.order
        storedAt = snapshot.storedAt ?? [:]
        generations = snapshot.generations ?? [:]
        refreshes = snapshot.refreshes ?? [:]
        seen = snapshot.seen ?? [:]
        continuations = snapshot.continuations ?? [:]
    }

    private func save() {
        let snapshot = Snapshot(
            cache: cache,
            order: order,
            storedAt: storedAt,
            generations: generations,
            refreshes: refreshes,
            seen: seen,
            continuations: continuations
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
