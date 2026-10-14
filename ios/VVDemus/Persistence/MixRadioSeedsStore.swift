import Foundation

/// The songs picked so far for a mix radio, gathered one at a time from any track menu.
///
/// A tray rather than a multi-select mode, because the songs worth mixing are rarely on one
/// screen: one from a search, one from a playlist, the one playing now. Kept across launches —
/// a pick that disappeared when the app was backgrounded would have to be made again from
/// scratch, from all the same places.
@MainActor
final class MixRadioSeedsStore: ObservableObject {
    static let shared = MixRadioSeedsStore()

    @Published private(set) var seeds: [Track] = []

    private let key = "mix_radio_seeds_v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Track].self, from: data) {
            seeds = saved
        }
    }

    var radio: MixRadio { MixRadio(seeds: seeds) }

    func contains(_ track: Track) -> Bool {
        seeds.contains { $0.videoId == track.videoId }
    }

    func toggle(_ track: Track) {
        if contains(track) {
            remove(track)
        } else {
            seeds.append(track)
            save()
        }
    }

    func remove(_ track: Track) {
        seeds.removeAll { $0.videoId == track.videoId }
        save()
    }

    func clear() {
        seeds = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(seeds) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
