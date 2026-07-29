import Foundation

@MainActor
final class LikedSongsStore: ObservableObject {
    static let shared = LikedSongsStore()

    @Published private(set) var tracks: [Track] = []
    private let key = "liked_songs_v1"
    /// Set-backed membership. `isLiked` is called several times per row body, for every
    /// visible row, on every published change — a linear scan over a few hundred liked
    /// songs became tens of thousands of string comparisons a second while scrolling.
    private(set) var likedIds: Set<String> = []

    private init() { load() }

    func toggle(_ track: Track) {
        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks.remove(at: index)
            likedIds.remove(track.videoId)
        } else {
            tracks.insert(track, at: 0)
            likedIds.insert(track.videoId)
        }
        save()
    }

    func isLiked(_ track: Track) -> Bool { likedIds.contains(track.videoId) }

    private func load() {
        guard let decoded = DefaultsSnapshot.load([Track].self, forKey: key) else { return }
        tracks = decoded
        likedIds = Set(decoded.map(\.videoId))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
