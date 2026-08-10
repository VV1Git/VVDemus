import Foundation

@MainActor
final class RadioHistoryStore: ObservableObject {
    static let shared = RadioHistoryStore()

    @Published private(set) var stations: [RadioStation] = []
    /// The real storage — with tombstones, so deleting a station on one device survives meeting
    /// a device that still has it.
    private(set) var records: [RadioRecord] = []

    private let key = "radio_history_v2"
    private let legacyKey = "radio_history_v1"
    private let limit = 20

    private init() { load() }

    func record(seed: Track) {
        if let index = records.firstIndex(where: { $0.seedTrack.videoId == seed.videoId }) {
            records[index].lastPlayedAt = Date()
            records[index].removedAt = nil
            records[index].stamp = .now()
        } else {
            records.append(RadioRecord(seedTrack: seed, lastPlayedAt: Date(), removedAt: nil, stamp: .now()))
        }
        rebuild()
        save()
    }

    func delete(_ station: RadioStation) {
        guard let index = records.firstIndex(where: { $0.seedTrack.videoId == station.id }) else { return }
        records[index].removedAt = Date()
        records[index].stamp = .now()
        rebuild()
        save()
    }

    /// For `List.onDelete`, which hands back positions in the array it rendered.
    func delete(at offsets: IndexSet) {
        for station in offsets.compactMap({ stations.indices.contains($0) ? stations[$0] : nil }) {
            delete(station)
        }
    }

    @discardableResult
    func merge(_ incoming: [RadioRecord]) -> Int {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        var changed = 0
        for record in incoming {
            if let index = records.firstIndex(where: { $0.seedTrack.videoId == record.seedTrack.videoId }) {
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

    /// The 20-station cap is applied to the *view*, not to storage. Trimming the records would
    /// make dropping off the end indistinguishable from a deletion, and the next sync would
    /// hand every trimmed station straight back.
    private func rebuild() {
        stations = records
            .filter(\.isPresent)
            .sorted { $0.lastPlayedAt > $1.lastPlayedAt }
            .prefix(limit)
            .map { RadioStation(seedTrack: $0.seedTrack, lastPlayedAt: $0.lastPlayedAt) }
    }

    private func load() {
        if let decoded = DefaultsSnapshot.load([RadioRecord].self, forKey: key) {
            records = decoded
            rebuild()
            return
        }
        guard let legacy = DefaultsSnapshot.load([RadioStation].self, forKey: legacyKey) else { return }
        records = legacy.map {
            RadioRecord(
                seedTrack: $0.seedTrack,
                lastPlayedAt: $0.lastPlayedAt,
                removedAt: nil,
                stamp: EditStamp(editedAt: $0.lastPlayedAt, editedBy: PeerIdentityBox.currentPeerId)
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
