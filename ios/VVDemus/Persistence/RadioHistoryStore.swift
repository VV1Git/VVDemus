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

    func delete(_ station: RadioStation) {
        stations.removeAll { $0.id == station.id }
        save()
    }

    /// For `List.onDelete`, which hands back positions in the array it rendered.
    func delete(at offsets: IndexSet) {
        stations.remove(atOffsets: offsets)
        save()
    }

    private func load() {
        guard let decoded = DefaultsSnapshot.load([RadioStation].self, forKey: key) else { return }
        stations = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(stations) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
