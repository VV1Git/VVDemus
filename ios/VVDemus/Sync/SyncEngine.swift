import Foundation

/// Builds this device's half of a sync round, and folds in the other half.
///
/// Deliberately has no networking in it. `PeerClient` carries payloads over HTTP and the server
/// answers them; everything here is a pure function of the stores, which is what makes the merge
/// rules testable without two devices, a network, or any real audio.
@MainActor
enum SyncEngine {
    /// What this device is prepared to send, given what the peer says it already has.
    static func snapshot(eventsSince: Date?) -> SyncPayload {
        var generated: [GeneratedRecord] = []
        if let daylist = DaylistStore.shared.syncRecord() { generated.append(daylist) }
        if let feed = HomeFeedStore.shared.syncRecord() { generated.append(feed) }
        generated.append(contentsOf: RadioCacheStore.shared.syncRecords())
        generated.append(contentsOf: AlbumCacheStore.shared.syncRecords())

        let events = eventsSince
            .map { ListeningStatsStore.shared.events(since: $0) }
            ?? ListeningStatsStore.shared.events

        return SyncPayload(
            peerId: PeerIdentity.shared.peerId,
            likes: LikedSongsStore.shared.records,
            playlists: PlaylistStore.shared.records,
            radios: RadioHistoryStore.shared.records,
            albums: AlbumHistoryStore.shared.records,
            generated: generated,
            recentSearches: RecentSearchStore.shared.searches,
            events: events,
            // What the *sender* wants back, so one round trip carries both directions.
            eventsSince: ListeningStatsStore.shared.newestEventAt
        )
    }

    /// Folds `payload` into the local stores, reporting what actually moved.
    ///
    /// Counts rather than a bare "something changed": a sync that silently succeeds is
    /// indistinguishable from one that silently does nothing, and the whole point of the
    /// feature is that your library arrives.
    @discardableResult
    static func merge(_ payload: SyncPayload) -> SyncSummary {
        var summary = SyncSummary()

        summary.likes = LikedSongsStore.shared.merge(payload.likes)
        summary.playlists = PlaylistStore.shared.merge(payload.playlists)
        summary.radios = RadioHistoryStore.shared.merge(payload.radios)
        summary.albums = AlbumHistoryStore.shared.merge(payload.openedAlbums)
        summary.searches = RecentSearchStore.merge(payload.recentSearches) ? 1 : 0

        for record in payload.generated {
            let applied: Bool
            if record.id == "daylist_v4" {
                applied = DaylistStore.shared.applySynced(record)
            } else if record.id == "home_feed_v3" {
                applied = HomeFeedStore.shared.applySynced(record)
            } else if record.id.hasPrefix(AlbumCacheStore.recordPrefix) {
                applied = AlbumCacheStore.shared.applySynced(record)
            } else {
                applied = RadioCacheStore.shared.applySynced(record)
            }
            if applied { summary.generated += 1 }
        }

        if !payload.events.isEmpty {
            summary.plays = ListeningStatsStore.shared.merge(payload.events)
            // Recently-played is the same information at a different grain, so it is derived
            // from the events that just arrived rather than shipped separately.
            let played = payload.events.map { PlayedTrack(track: $0.track, playedAt: $0.playedAt) }
            PlayHistoryStore.shared.merge(played)
            if let newest = payload.events.map(\.playedAt).max() {
                SyncCursor.setEventsSince(newest, peerId: payload.peerId)
            }
        }

        return summary
    }
}

/// What a sync round actually brought over.
struct SyncSummary: Equatable {
    var likes = 0
    var playlists = 0
    var radios = 0
    var albums = 0
    var plays = 0
    var generated = 0
    var searches = 0

    var isEmpty: Bool {
        likes + playlists + radios + albums + plays + generated + searches == 0
    }

    /// Human phrasing for the Settings row — "3 liked songs, 1 playlist, 42 plays".
    var description: String {
        var parts: [String] = []
        func add(_ count: Int, _ singular: String, _ plural: String) {
            guard count > 0 else { return }
            parts.append("\(count) \(count == 1 ? singular : plural)")
        }
        add(likes, "liked song", "liked songs")
        add(playlists, "playlist", "playlists")
        add(radios, "radio", "radios")
        add(albums, "album", "albums")
        add(plays, "play", "plays")
        add(generated, "mix", "mixes")
        add(searches, "search list", "search lists")
        return parts.isEmpty ? "Already up to date" : parts.joined(separator: ", ")
    }
}

/// Recent search terms, which have no store of their own — `SearchView` reads and writes the
/// key directly through `@AppStorage`.
///
/// This reads and writes that same representation rather than a nicer one: `@AppStorage` cannot
/// hold an array, so the terms live as a **JSON string** under `recent_searches_v1`. Writing a
/// real string array there instead would leave `SearchView` decoding nothing and quietly show an
/// empty list forever.
@MainActor
enum RecentSearchStore {
    static let shared = RecentSearchStore.self

    private static let key = "recent_searches_v1"
    private static let limit = 20

    static var searches: [String] {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let decoded = try? JSONDecoder().decode([String].self, from: Data(raw.utf8))
        else { return [] }
        return decoded
    }

    /// Union. The peer's terms are appended rather than interleaved: there are no timestamps to
    /// interleave by, and inventing an order would be worse than admitting there isn't one.
    @discardableResult
    static func merge(_ incoming: [String]) -> Bool {
        var terms = searches
        var changed = false
        for term in incoming
        where !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            terms.append(term)
            changed = true
        }
        guard changed else { return false }
        if terms.count > limit { terms.removeLast(terms.count - limit) }
        guard let data = try? JSONEncoder().encode(terms),
              let json = String(data: data, encoding: .utf8) else { return false }
        UserDefaults.standard.set(json, forKey: key)
        return true
    }
}
