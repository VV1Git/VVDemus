import Foundation

@MainActor
final class PlaylistStore: ObservableObject {
    static let shared = PlaylistStore()

    /// What the UI reads. Projected from `records` — the playlists that are present, each with
    /// its present entries in merged order.
    @Published private(set) var playlists: [Playlist] = []

    /// The real storage. See `PlaylistRecord`: membership is per-track so that adding a
    /// different song on each device keeps both, which a whole-playlist merge cannot do.
    private(set) var records: [PlaylistRecord] = []

    private let key = "playlists_v2"
    private let legacyKey = "playlists_v1"

    private init() { load() }

    @discardableResult
    func create(name: String) -> Playlist {
        let now = Date()
        let record = PlaylistRecord(
            id: UUID(),
            name: name,
            nameStamp: .now(),
            createdAt: now,
            removedAt: nil,
            entries: []
        )
        records.append(record)
        rebuild()
        save()
        return Playlist(id: record.id, name: name, tracks: [], createdAt: now)
    }

    func delete(_ playlist: Playlist) {
        guard let index = records.firstIndex(where: { $0.id == playlist.id }) else { return }
        records[index].removedAt = Date()
        records[index].nameStamp = .now()
        rebuild()
        save()
    }

    func rename(_ playlist: Playlist, to name: String) {
        guard let index = records.firstIndex(where: { $0.id == playlist.id }) else { return }
        records[index].name = name
        records[index].nameStamp = .now()
        rebuild()
        save()
    }

    func addTrack(_ track: Track, to playlist: Playlist) {
        guard let index = records.firstIndex(where: { $0.id == playlist.id }) else { return }
        let now = Date()
        if let entry = records[index].entries.firstIndex(where: { $0.track.videoId == track.videoId }) {
            // Already there and still present — adding again is a no-op, as it was before.
            guard !records[index].entries[entry].isPresent else { return }
            records[index].entries[entry].removedAt = nil
            records[index].entries[entry].addedAt = now
            records[index].entries[entry].stamp = .now()
        } else {
            let last = records[index].entries.filter(\.isPresent).map(\.order).max()
            records[index].entries.append(
                PlaylistEntry(
                    track: track,
                    addedAt: now,
                    removedAt: nil,
                    order: OrderKey.between(last, nil),
                    stamp: .now()
                )
            )
        }
        rebuild()
        save()
    }

    func removeTrack(_ track: Track, from playlist: Playlist) {
        guard let index = records.firstIndex(where: { $0.id == playlist.id }),
              let entry = records[index].entries.firstIndex(where: { $0.track.videoId == track.videoId })
        else { return }
        records[index].entries[entry].removedAt = Date()
        records[index].entries[entry].stamp = .now()
        rebuild()
        save()
    }

    /// Rewrites only the moved rows' order keys, leaving every other entry untouched — which is
    /// what lets a reorder here and an add on the other device both survive the merge.
    func moveTrack(in playlist: Playlist, from source: IndexSet, to destination: Int) {
        guard let index = records.firstIndex(where: { $0.id == playlist.id }) else { return }
        var ordered = Self.sortedPresentEntries(records[index])
        // Captured before the move, while the offsets still mean what the caller meant.
        let movedIds = Set(source.compactMap {
            ordered.indices.contains($0) ? ordered[$0].track.videoId : nil
        })
        ordered.move(fromOffsets: source, toOffset: destination)

        for (position, entry) in ordered.enumerated() where movedIds.contains(entry.track.videoId) {
            // The lower bound is whatever now precedes this row — already rewritten if it moved
            // too, so it is final. The upper bound deliberately skips past any other moved row:
            // those still carry their *old* keys, which can sort below the one just assigned,
            // and asking for a key between a larger lower bound and a smaller upper bound has
            // no answer. The next unmoved row is the nearest bound that is certainly correct.
            let before = position > 0 ? ordered[position - 1].order : nil
            let after = ordered[(position + 1)...]
                .first { !movedIds.contains($0.track.videoId) }?.order
            let key = OrderKey.between(before, after)
            ordered[position].order = key
            guard let target = records[index].entries
                .firstIndex(where: { $0.track.videoId == entry.track.videoId }) else { continue }
            records[index].entries[target].order = key
            records[index].entries[target].stamp = .now()
        }
        rebuild()
        save()
    }

    private static func sortedPresentEntries(_ record: PlaylistRecord) -> [PlaylistEntry] {
        record.sortedPresentEntries
    }

    @discardableResult
    func merge(_ incoming: [PlaylistRecord]) -> Int {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        var changed = 0
        for record in incoming {
            guard let index = records.firstIndex(where: { $0.id == record.id }) else {
                records.append(record)
                changed += 1
                continue
            }
            let merged = PlaylistRecord.merging(records[index], record)
            records[index] = merged.record
            if merged.changed { changed += 1 }
        }
        if changed > 0 {
            rebuild()
            save()
        }
        return changed
    }

    private func rebuild() {
        playlists = records
            .filter(\.isPresent)
            .sorted { $0.createdAt > $1.createdAt }
            .map { Playlist(id: $0.id, name: $0.name, tracks: $0.orderedTracks, createdAt: $0.createdAt) }
    }

    private func load() {
        if let decoded = DefaultsSnapshot.load([PlaylistRecord].self, forKey: key) {
            records = decoded
            rebuild()
            return
        }
        // v1 was `[Playlist]` with a plain `tracks` array — position was the only ordering, and
        // there were no per-track times. Initial order keys reproduce the existing order
        // exactly; `createdAt` stands in for when each track was added, which is the closest
        // honest answer available. The v1 key is left untouched as a fallback.
        guard let legacy = DefaultsSnapshot.load([Playlist].self, forKey: legacyKey) else { return }
        records = legacy.map { playlist in
            let keys = OrderKey.initialKeys(count: playlist.tracks.count)
            let stamp = EditStamp(editedAt: playlist.createdAt, editedBy: PeerIdentityBox.currentPeerId)
            return PlaylistRecord(
                id: playlist.id,
                name: playlist.name,
                nameStamp: stamp,
                createdAt: playlist.createdAt,
                removedAt: nil,
                entries: zip(playlist.tracks, keys).map { track, order in
                    PlaylistEntry(
                        track: track,
                        addedAt: playlist.createdAt,
                        removedAt: nil,
                        order: order,
                        stamp: stamp
                    )
                }
            )
        }
        rebuild()
        save()
    }

    /// True while applying the peer's records, so the save that follows is not announced back.
    ///
    /// Without this the two devices ping-pong: a merge writes, the write announces, the peer
    /// merges what it already has, writes, announces back, and neither ever settles. The merges
    /// are idempotent so nothing would be corrupted — it would just never stop.
    private var isApplyingRemote = false

    private func save() {
        // Announced from here rather than from each mutation: every local edit already funnels
        // through `save`, so a new one cannot forget to tell the peer.
        if !isApplyingRemote { PeerLink.shared.libraryDidChange() }
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
