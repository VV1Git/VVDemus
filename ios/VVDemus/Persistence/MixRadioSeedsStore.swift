import Foundation

/// The songs picked so far for a mix radio, gathered one at a time from any track menu.
///
/// A tray rather than a multi-select mode, because the songs worth mixing are rarely on one
/// screen: one from a search, one from a playlist, the one playing now. Kept across launches —
/// a pick that disappeared when the app was backgrounded would have to be made again from
/// scratch, from all the same places.
///
/// Synced with the paired device as one `MixRadioRecord`, so picking on the phone and opening
/// the station on the Mac is the same tray. See that type for why it merges newest-wins.
@MainActor
final class MixRadioSeedsStore: ObservableObject {
    static let shared = MixRadioSeedsStore()

    @Published private(set) var seeds: [Track] = []
    /// When `seeds` last changed, and where — what a sync compares.
    private var stamp: EditStamp

    private let key = "mix_radio_v2"
    /// The unstamped list the first build stored. Read once, so picks made before syncing
    /// existed are not lost.
    private let legacyKey = "mix_radio_seeds_v1"

    private init() {
        // Older than any real edit, so a device that has never touched its tray takes the
        // peer's picks rather than overwriting them with an empty list.
        stamp = EditStamp(editedAt: .distantPast, editedBy: PeerIdentityBox.currentPeerId)
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(MixRadioRecord.self, from: data) {
            seeds = saved.seeds
            stamp = saved.stamp
        } else if let data = UserDefaults.standard.data(forKey: legacyKey),
                  let saved = try? JSONDecoder().decode([Track].self, from: data) {
            seeds = saved
            // Picks someone actually made are a real edit. Left at `.distantPast` they would
            // tie with an untouched empty tray on the other device, and the device-id
            // tiebreak could hand this one the empty list.
            if !saved.isEmpty { stamp = .now() }
            save()
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }

    var radio: MixRadio { MixRadio(seeds: seeds) }

    var record: MixRadioRecord { MixRadioRecord(seeds: seeds, stamp: stamp) }

    func contains(_ track: Track) -> Bool {
        seeds.contains { $0.videoId == track.videoId }
    }

    func toggle(_ track: Track) {
        if contains(track) {
            remove(track)
        } else {
            seeds.append(track)
            edited()
        }
    }

    func remove(_ track: Track) {
        seeds.removeAll { $0.videoId == track.videoId }
        edited()
    }

    func clear() {
        seeds = []
        edited()
    }

    /// The rule is `MixRadioRecord.merging`; this is the plumbing around it. Not announced
    /// back to the peer — it is where the record came from.
    @discardableResult
    func merge(_ incoming: MixRadioRecord) -> Bool {
        let merged = MixRadioRecord.merging(record, incoming)
        guard merged.changed else { return false }
        seeds = merged.record.seeds
        stamp = merged.record.stamp
        save()
        return true
    }

    private func edited() {
        stamp = .now()
        save()
        PeerLink.shared.libraryDidChange()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(record) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
