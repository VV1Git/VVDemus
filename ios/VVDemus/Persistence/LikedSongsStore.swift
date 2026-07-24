import Foundation

@MainActor
final class LikedSongsStore: ObservableObject {
    static let shared = LikedSongsStore()

    @Published private(set) var tracks: [Track] = []
    private let key = "liked_songs_v1"

    private init() { load() }

    func toggle(_ track: Track) {
        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks.remove(at: index)
        } else {
            tracks.insert(track, at: 0)
        }
        save()
    }

    func isLiked(_ track: Track) -> Bool {
        tracks.contains { $0.id == track.id }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Track].self, from: data) else { return }
        tracks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
