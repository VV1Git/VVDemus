import Foundation

/// Builds this device's half of a sync round, and folds in the other half.
///
/// Deliberately has no networking in it. `PeerClient` carries payloads over HTTP and the server
/// answers them; everything here is a pure function of the stores, which is what makes the merge
/// rules testable without two devices, a network, or any real audio.
@MainActor
enum SyncEngine {
    /// Which of this device's plays go into a payload, and what that choice claims.
    @MainActor
    struct EventSelection {
        var events: [PlayEvent]
        /// See `SyncPayload.eventBase`.
        var base: EventMarks.Marks?

        /// The whole log, claiming nothing is missing — a backup, or a first round with a peer.
        static var everything: EventSelection {
            EventSelection(events: ListeningStatsStore.shared.events, base: [:])
        }

        /// Everything a device holding `marks` lacks — a reply, or a push to a peer whose marks
        /// are known.
        static func after(_ marks: EventMarks.Marks, legacySince: Date?) -> EventSelection {
            EventSelection(
                events: EventMarks.select(ListeningStatsStore.shared.events, after: marks, legacySince: legacySince),
                base: marks
            )
        }

        /// By date alone, the way every round chose before marks existed. Still right for a
        /// peer on an older build; claims nothing, because a date can skip a play.
        static func since(_ date: Date?) -> EventSelection {
            guard let date else { return everything }
            return EventSelection(events: ListeningStatsStore.shared.events(since: date), base: nil)
        }

        /// What to push to `peerId` unasked, at the start of a round with it.
        static func push(to peerId: String) -> EventSelection {
            let since = SyncCursor.eventsSince(peerId: peerId)
            if let marks = SyncCursor.confirmedMarks(peerId: peerId) {
                return .after(marks, legacySince: since)
            }
            return .since(since)
        }

        /// What to answer `request` with: everything it says it lacks.
        static func reply(to request: SyncPayload) -> EventSelection {
            guard let marks = request.eventMarks else { return .since(request.eventsSince) }
            return .after(marks, legacySince: request.eventsSince)
        }
    }

    /// What this device sends to `recipient`: its whole library, the plays `selection` picked,
    /// and the devices it is linked to, signed for that recipient. No recipient means a file,
    /// which carries no devices at all.
    static func snapshot(events selection: EventSelection, for recipient: PairedPeer?) -> SyncPayload {
        var generated: [GeneratedRecord] = []
        if let daylist = DaylistStore.shared.syncRecord() { generated.append(daylist) }
        if let feed = HomeFeedStore.shared.syncRecord() { generated.append(feed) }
        generated.append(contentsOf: RadioCacheStore.shared.syncRecords())
        generated.append(contentsOf: AlbumCacheStore.shared.syncRecords())

        let stats = ListeningStatsStore.shared
        let devices = recipient.map { _ in PairedPeerStore.shared.deviceRecords() }
        return SyncPayload(
            peerId: PeerIdentity.shared.peerId,
            likes: LikedSongsStore.shared.records,
            playlists: PlaylistStore.shared.records,
            radios: RadioHistoryStore.shared.records,
            albums: AlbumHistoryStore.shared.records,
            generated: generated,
            recentSearches: RecentSearchStore.shared.searches,
            events: selection.events,
            // What the *sender* wants back, so one round trip carries both directions. A peer on
            // this build reads it only for plays with no origin; a peer on an older build reads
            // it for everything, and has to keep getting what it always got. Nil here would ask
            // that peer for its whole log every round.
            eventsSince: stats.newestEventAt,
            mixRadio: MixRadioSeedsStore.shared.record,
            devices: devices,
            devicesSignature: devices.flatMap { list in recipient.flatMap { PairedPeerStore.shared.signature(of: list, for: $0) } },
            eventMarks: stats.eventMarks,
            eventBase: selection.base
        )
    }

    /// The whole library and log, for a backup file.
    static func backupSnapshot() -> SyncPayload {
        snapshot(events: .everything, for: nil)
    }

    /// Folds `payload` into the local stores, reporting what actually moved.
    ///
    /// `sender` is the paired device the payload came from, already authenticated, or nil for a
    /// backup file. Only a peer moves the sync bookkeeping or introduces devices: a file is
    /// nobody's word about what anyone holds, nor about who belongs in the group.
    ///
    /// Counts rather than a bare "something changed": a sync that silently succeeds is
    /// indistinguishable from one that silently does nothing, and the whole point of the
    /// feature is that your library arrives.
    @discardableResult
    static func merge(_ payload: SyncPayload, from sender: String?) -> SyncSummary {
        var summary = SyncSummary()

        summary.likes = LikedSongsStore.shared.merge(payload.likes)
        summary.playlists = PlaylistStore.shared.merge(payload.playlists)
        summary.radios = RadioHistoryStore.shared.merge(payload.radios)
        summary.albums = AlbumHistoryStore.shared.merge(payload.openedAlbums)
        summary.searches = RecentSearchStore.merge(payload.recentSearches) ? 1 : 0
        if let mix = payload.mixRadio, MixRadioSeedsStore.shared.merge(mix) { summary.mixRadio = 1 }

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
        }

        guard let sender else { return summary }

        if let newest = payload.events.map(\.playedAt).max() {
            SyncCursor.setEventsSince(newest, peerId: sender)
        }
        // After the merge, so the plays the marks vouch for are already here.
        ListeningStatsStore.shared.advanceMarks(senderMarks: payload.eventMarks, base: payload.eventBase)
        if let marks = payload.eventMarks {
            SyncCursor.setConfirmedMarks(marks, peerId: sender)
        }
        if let devices = payload.devices, let member = PairedPeerStore.shared.peer(id: sender) {
            if PairedPeerStore.shared.verify(payload.devicesSignature, of: devices, from: member) {
                summary.devices = PairedPeerStore.shared.merge(devices, from: sender)
            } else {
                PairLog.error("\(member.name)'s list of devices did not verify — ignored")
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
    var mixRadio = 0
    /// Devices that joined or left the group by way of this round.
    var devices = 0

    var isEmpty: Bool {
        likes + playlists + radios + albums + plays + generated + searches + mixRadio + devices == 0
    }

    /// Folds in another member's round, for the one line that describes them all.
    mutating func add(_ other: SyncSummary) {
        likes += other.likes
        playlists += other.playlists
        radios += other.radios
        albums += other.albums
        plays += other.plays
        generated += other.generated
        searches += other.searches
        mixRadio += other.mixRadio
        devices += other.devices
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
        add(mixRadio, "mix radio", "mix radios")
        add(devices, "linked device", "linked devices")
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
