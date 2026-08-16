import Foundation

/// The releases you have opened, newest first — the album half of Home's shortcut grid and of
/// the Albums section in Library.
///
/// Deliberately the same shape as `RadioHistoryStore`, tombstones included: removing an album
/// on one device has to survive meeting a device that still has it, or the next sync hands it
/// straight back and "remove" looks broken rather than slow.
@MainActor
final class AlbumHistoryStore: ObservableObject {
    static let shared = AlbumHistoryStore()

    @Published private(set) var albums: [Album] = []
    /// The real storage. `albums` is the tombstone-free projection of this.
    private(set) var records: [AlbumRecord] = []

    private let key = "album_history_v1"
    private let limit = 20

    private init() { load() }

    /// Recorded on *open* rather than on play, unlike a radio — which is recorded when its
    /// seed starts playing, because a radio has no page you can reach without playing
    /// something. An album does: browsing to one and reading the tracklist is a real visit,
    /// and it is the visit Home's "recently opened" ordering is about.
    func record(_ album: Album) {
        if let index = records.firstIndex(where: { $0.album.browseId == album.browseId }) {
            // The album itself is overwritten, not just its timestamp: a release first seen
            // as a search row may have had no year, and the page it was opened from does.
            records[index].album = album
            records[index].lastOpenedAt = Date()
            records[index].removedAt = nil
            records[index].stamp = .now()
        } else {
            records.append(AlbumRecord(album: album, lastOpenedAt: Date(), removedAt: nil, stamp: .now()))
        }
        rebuild()
        save()
    }

    func delete(_ album: Album) {
        guard let index = records.firstIndex(where: { $0.album.browseId == album.browseId }) else { return }
        records[index].removedAt = Date()
        records[index].stamp = .now()
        rebuild()
        save()
    }

    /// For `List.onDelete`, which hands back positions in the array it rendered.
    func delete(at offsets: IndexSet) {
        for album in offsets.compactMap({ albums.indices.contains($0) ? albums[$0] : nil }) {
            delete(album)
        }
    }

    /// When this release was last opened, for Home's cross-kind recency ordering.
    func lastOpenedAt(_ browseId: String) -> Date? {
        records.first { $0.album.browseId == browseId && $0.isPresent }?.lastOpenedAt
    }

    /// The rule itself is `AlbumRecord.merging`, so it can be exercised without a singleton
    /// or a `UserDefaults` to write into. This is only the plumbing around it.
    @discardableResult
    func merge(_ incoming: [AlbumRecord]) -> Int {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        let merged = AlbumRecord.merging(records, incoming)
        guard merged.changed > 0 else { return 0 }
        records = merged.records
        rebuild()
        save()
        return merged.changed
    }

    private func rebuild() {
        albums = AlbumRecord.present(records, limit: limit)
    }

    private func load() {
        guard let decoded = DefaultsSnapshot.load([AlbumRecord].self, forKey: key) else { return }
        records = decoded
        rebuild()
    }

    /// True while applying the peer's records, so the save that follows is not announced back
    /// and the two devices do not ping-pong announcements forever.
    private var isApplyingRemote = false

    private func save() {
        if !isApplyingRemote { PeerLink.shared.libraryDidChange() }
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
