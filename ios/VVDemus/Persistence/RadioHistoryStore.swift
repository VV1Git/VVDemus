import Foundation

@MainActor
final class RadioHistoryStore: ObservableObject {
    static let shared = RadioHistoryStore()

    @Published private(set) var stations: [RadioStation] = []
    private let key = "radio_history_v1"
    private let limit = 20

    private init() { load() }

    func record(seed: Track) {
        stations.removeAll { $0.seedTrack.id == seed.id }
        stations.insert(RadioStation(seedTrack: seed, lastPlayedAt: Date()), at: 0)
        if stations.count > limit { stations.removeLast(stations.count - limit) }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RadioStation].self, from: data) else { return }
        stations = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(stations) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
