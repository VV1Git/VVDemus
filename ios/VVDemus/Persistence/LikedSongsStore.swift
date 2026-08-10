import Foundation

@MainActor
final class LikedSongsStore: ObservableObject {
    static let shared = LikedSongsStore()

    @Published private(set) var tracks: [Track] = []
    /// Set-backed membership. `isLiked` is called several times per row body, for every
    /// visible row, on every published change — a linear scan over a few hundred liked
    /// songs became tens of thousands of string comparisons a second while scrolling.
    private(set) var likedIds: Set<String> = []

    /// The real storage. `tracks` is the present subset of this, newest first.
    ///
    /// A bare `[Track]` could not be merged with another device's: unliking would have been
    /// indistinguishable from never having liked, so every sync would resurrect everything
    /// either device had ever removed.
    private(set) var records: [LikeRecord] = []

    private let key = "liked_songs_v2"
    private let legacyKey = "liked_songs_v1"

    private init() { load() }

    func toggle(_ track: Track) {
        let now = Date()
        if let index = records.firstIndex(where: { $0.track.videoId == track.videoId }) {
            if records[index].isPresent {
                records[index].removedAt = now
            } else {
                records[index].removedAt = nil
                records[index].likedAt = now
            }
            records[index].stamp = .now()
        } else {
            records.append(LikeRecord(track: track, likedAt: now, removedAt: nil, stamp: .now()))
        }
        rebuild()
        save()
    }

    func isLiked(_ track: Track) -> Bool { likedIds.contains(track.videoId) }

    /// Applies records that arrived from the paired device, returning how many actually
    /// changed — so a quiet round doesn't churn the UI, and the sync screen can say what moved
    /// rather than only that something did.
    @discardableResult
    func merge(_ incoming: [LikeRecord]) -> Int {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        var changed = 0
        for record in incoming {
            if let index = records.firstIndex(where: { $0.track.videoId == record.track.videoId }) {
                guard record.stamp.isNewerThan(records[index].stamp) else { continue }
                records[index] = record
                changed += 1
            } else {
                records.append(record)
                changed += 1
            }
        }
        if changed > 0 {
            rebuild()
            save()
        }
        return changed
    }

    private func rebuild() {
        let present = records.filter(\.isPresent).sorted { $0.likedAt > $1.likedAt }
        tracks = present.map(\.track)
        likedIds = Set(present.map(\.track.videoId))
    }

    private func load() {
        if let decoded = DefaultsSnapshot.load([LikeRecord].self, forKey: key) {
            records = decoded
            rebuild()
            return
        }
        // One-time migration. The v1 blob is a bare `[Track]`, newest first, with no times at
        // all — so the order is the only evidence of when anything was liked. Synthetic
        // descending timestamps preserve exactly that and nothing more. The v1 key is left in
        // place rather than deleted: if this migration is ever wrong, the original is still
        // there to look at.
        guard let legacy = DefaultsSnapshot.load([Track].self, forKey: legacyKey) else { return }
        let base = Date()
        records = legacy.enumerated().map { offset, track in
            let when = base.addingTimeInterval(-Double(offset))
            return LikeRecord(
                track: track,
                likedAt: when,
                removedAt: nil,
                stamp: EditStamp(editedAt: when, editedBy: PeerIdentityBox.currentPeerId)
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
