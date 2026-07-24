import Foundation

@MainActor
final class PlaylistStore: ObservableObject {
    static let shared = PlaylistStore()

    @Published private(set) var playlists: [Playlist] = []
    private let key = "playlists_v1"

    private init() { load() }

    @discardableResult
    func create(name: String) -> Playlist {
        let playlist = Playlist(name: name)
        playlists.insert(playlist, at: 0)
        save()
        return playlist
    }

    func delete(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
        save()
    }

    func rename(_ playlist: Playlist, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].name = name
        save()
    }

    func addTrack(_ track: Track, to playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        guard !playlists[index].tracks.contains(where: { $0.id == track.id }) else { return }
        playlists[index].tracks.append(track)
        save()
    }

    func removeTrack(_ track: Track, from playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].tracks.removeAll { $0.id == track.id }
        save()
    }

    func moveTrack(in playlist: Playlist, from source: IndexSet, to destination: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].tracks.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Playlist].self, from: data) else { return }
        playlists = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
