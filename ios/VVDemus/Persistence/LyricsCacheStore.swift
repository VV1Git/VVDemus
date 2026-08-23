import Foundation

/// The words to each track that has been looked up, plus the tracks that were looked up and
/// had none.
///
/// The misses are the part that matters. Without them, every open of an instrumental — or of
/// anything obscure enough that neither host knows it — pays an LRCLIB request and a YouTube
/// Music request, forever, and the screen spends a second on a spinner every time to arrive
/// at the same nothing. Cached, that costs one lookup instead.
///
/// But a miss must not be permanent the way a hit can be. Lyrics for a recording are a fixed
/// fact and never need re-fetching; "nobody has typed these up yet" is a statement about
/// LRCLIB's contributors on one particular day, and a track with nothing this month may have
/// synced lyrics the next. A cache that never re-asks turns a temporary gap into a permanent
/// one, which is a bug that never heals and that nobody can report because the app never
/// makes the request again. So misses expire and hits do not.
///
/// **Deliberately absent: `syncRecords()`/`applySynced(_:)`.** `RadioCacheStore` and
/// `AlbumCacheStore` both join `SyncEngine`, and this one does not. Every byte here is
/// regenerable from two public endpoints with no account behind them, so shipping it between
/// peers — and growing the `.vvdem` backup with it — would move data neither device is any
/// better off holding. This is a decision, not an oversight; do not "fix" it by adding the
/// two methods.
@MainActor
final class LyricsCacheStore: ObservableObject {
    static let shared = LyricsCacheStore()

    /// How long a "no lyrics" answer is trusted before the hosts are asked again.
    ///
    /// A week. Short enough that a lyric contributed to LRCLIB shows up on the next listen
    /// rather than next year, long enough that playing the same instrumental album on repeat
    /// all week costs one pair of requests rather than one per open. The exact number is
    /// arbitrary; that it is *finite* is not.
    static let missTTL: TimeInterval = 7 * 24 * 60 * 60

    /// Bumped only when `Snapshot`'s shape changes.
    ///
    /// The house convention is to bump the defaults *key* instead (`radio_track_cache_v3`),
    /// which works fine forwards — a new build sees a missing key. It does nothing backwards:
    /// an older build re-reading the same old key after a newer one has written a newer shape
    /// to it decodes garbage or throws. A version inside the blob is what lets the older build
    /// recognise "this was written by something after me" and start empty, which for a cache
    /// that regenerates itself costs one re-fetch and nothing else.
    static let schemaVersion = 1

    static let defaultsKey = "lyrics_cache_v1"

    /// Published so the screen re-renders when a fetch lands. `AlbumCacheStore` and
    /// `RadioCacheStore` are `ObservableObject`s with no `@Published` property at all, and the
    /// views that `@ObservedObject` them get no notification from a `store(...)` — they happen
    /// to work because the fetch that filled the cache also set some `@State`. `LyricsView` has
    /// no such second path, so the notification has to be real here.
    @Published private var cache: [String: Lyrics] = [:]
    private var order: [String] = []
    /// When each fruitless lookup happened. Not merged into `order`: a run of unknown tracks
    /// would otherwise evict the lyrics of a downloaded album, which are the ones that matter
    /// most because they are the ones needed with no network.
    private var misses: [String: Date] = [:]

    /// Generous next to the twenty of `AlbumCacheStore`, because the unit here is a track
    /// rather than a release and because downloads fetch lyrics too — a limit of twenty would
    /// evict most of a downloaded album's words before the plane took off. A few KB each.
    private let limit: Int
    private let defaults: UserDefaults
    private let now: () -> Date

    private convenience init() {
        self.init(defaults: .standard)
    }

    /// The seam the tests use. `shared` writes to the app's real defaults, and a test that
    /// exercised it would leave fixture lyrics in the actual app — the failure
    /// `TasteProfileTests` records having already happened once with the Home feed.
    init(
        defaults: UserDefaults,
        limit: Int = 200,
        now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.limit = limit
        self.now = now
        load()
    }

    func lyrics(for videoId: String) -> Lyrics? { cache[videoId] }

    func store(_ lyrics: Lyrics, for videoId: String) {
        // An empty body is a failed parse or an empty response, not a song with no words in
        // it — the trap `AlbumCacheStore` documents falling into with empty tracklists. Held
        // as a hit it would be served forever; held as a miss it is re-asked once the TTL is
        // up, which is what a parse bug fixed in a later build needs.
        guard !lyrics.isEmpty else {
            storeMiss(for: videoId)
            return
        }
        cache[videoId] = lyrics
        // Words in hand make any earlier "no lyrics" answer wrong, and leaving it recorded
        // would keep the screen fetching for something it is already showing.
        misses.removeValue(forKey: videoId)
        order.removeAll { $0 == videoId }
        order.append(videoId)
        trimToLimit()
        save()
    }

    func storeMiss(for videoId: String) {
        misses[videoId] = now()
        trimToLimit()
        save()
    }

    func isMissFresh(_ videoId: String) -> Bool {
        guard let recordedAt = misses[videoId] else { return false }
        return now().timeIntervalSince(recordedAt) < Self.missTTL
    }

    private func trimToLimit() {
        while order.count > limit {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        // Expired misses are dropped rather than kept until they are pushed out, so a stale
        // one can never be resurrected by a clock that moved backwards.
        let cutoff = now().addingTimeInterval(-Self.missTTL)
        misses = misses.filter { $0.value > cutoff }
        while misses.count > limit {
            guard let oldest = misses.min(by: { $0.value < $1.value })?.key else { break }
            misses.removeValue(forKey: oldest)
        }
    }

    private struct Snapshot: Codable {
        /// Read before anything else is trusted; see `schemaVersion`.
        var version: Int?
        let cache: [String: Lyrics]
        let order: [String]
        var misses: [String: Date]?
    }

    private func load() {
        guard let snapshot = DefaultsSnapshot.load(Snapshot.self, forKey: Self.defaultsKey, from: defaults) else {
            // Unreadable, or nothing written yet. `DefaultsSnapshot` has already preserved the
            // bytes if they were the former; there is nothing here worth recovering by hand,
            // but leaving state alone rather than half-filling it is still the rule.
            return
        }
        guard (snapshot.version ?? 1) <= Self.schemaVersion else {
            // Written by a build newer than this one. Starting empty costs a re-fetch. Note
            // that the next `save()` overwrites the newer blob — acceptable here precisely
            // because this store is regenerable and syncs nowhere, which is not true of the
            // stores `DefaultsSnapshot` was written to protect.
            return
        }
        cache = snapshot.cache
        order = snapshot.order
        misses = snapshot.misses ?? [:]
        trimToLimit()
    }

    private func save() {
        let snapshot = Snapshot(version: Self.schemaVersion, cache: cache, order: order, misses: misses)
        DefaultsSnapshot.save(snapshot, forKey: Self.defaultsKey, to: defaults)
    }
}

private extension Lyrics {
    var isEmpty: Bool {
        switch body {
        case .synced(let lines): return lines.isEmpty
        // `whitespacesAndNewlines`, because `.whitespaces` is space and tab only: a body of
        // nothing but stray carriage returns would read as words and be held as a hit forever,
        // where a miss would at least expire and be asked again.
        case .plain(let lines): return lines.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }
}
