import SwiftUI

private struct RecommendationSection: Identifiable {
    let id = UUID()
    let title: String
    let tracks: [Track]
}

private enum ShortcutItem: Identifiable {
    case likedSongs
    case radio(RadioStation)
    case playlist(Playlist)

    var id: String {
        switch self {
        case .likedSongs: return "liked"
        case .radio(let station): return "radio-\(station.id)"
        case .playlist(let playlist): return "playlist-\(playlist.id)"
        }
    }
}

struct HomeView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject private var history = PlayHistoryStore.shared
    @ObservedObject private var liked = LikedSongsStore.shared
    @ObservedObject private var radioHistory = RadioHistoryStore.shared
    @ObservedObject private var playlists = PlaylistStore.shared
    @State private var sections: [RecommendationSection] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(greeting)
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    if !shortcuts.isEmpty {
                        shortcutGrid
                    }

                    if !jumpBackInItems.isEmpty {
                        jumpBackInShelf
                    }

                    if isLoading && sections.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if let errorMessage, sections.isEmpty {
                        ErrorRow(message: errorMessage) { Task { await load() } }
                    } else {
                        ForEach(sections) { section in
                            HomeShelf(title: section.title, tracks: section.tracks, player: player)
                        }
                    }
                }
                .padding(.bottom, 110)
            }
            .background(Theme.background)
            .navigationBarHidden(true)
            .navigationDestination(for: LibraryDestination.self) { destination in
                switch destination {
                case .liked:
                    LikedSongsView(player: player)
                case .playlist(let id):
                    PlaylistDetailView(playlistId: id, player: player)
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Shortcuts grid (Liked Songs, saved radios, playlists)

    private var shortcuts: [ShortcutItem] {
        var items: [ShortcutItem] = []
        if !liked.tracks.isEmpty { items.append(.likedSongs) }
        items.append(contentsOf: radioHistory.stations.prefix(6).map(ShortcutItem.radio))
        items.append(contentsOf: playlists.playlists.prefix(6).map(ShortcutItem.playlist))
        return Array(items.prefix(8))
    }

    private var shortcutGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
            ForEach(shortcuts) { item in
                shortcutTile(item)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func shortcutTile(_ item: ShortcutItem) -> some View {
        switch item {
        case .likedSongs:
            NavigationLink(value: LibraryDestination.liked) {
                ShortcutRow(title: "Liked Songs", imageURL: nil, systemImageFallback: "heart.fill")
            }
            .buttonStyle(.plain)
        case .radio(let station):
            ShortcutRow(title: station.title, imageURL: station.seedTrack.thumbnailUrl, systemImageFallback: "dot.radiowaves.left.and.right")
                .onTapGesture { player.playRadio(for: station.seedTrack) }
        case .playlist(let playlist):
            NavigationLink(value: LibraryDestination.playlist(playlist.id)) {
                ShortcutRow(title: playlist.name, imageURL: playlist.tracks.first?.thumbnailUrl, systemImageFallback: "music.note.list")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Jump back in (big radio/playlist cards)

    private var jumpBackInItems: [ShortcutItem] {
        let radios = radioHistory.stations.prefix(6).map(ShortcutItem.radio)
        let lists = playlists.playlists.prefix(6).map(ShortcutItem.playlist)
        return Array((radios + lists).prefix(10))
    }

    private var jumpBackInShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Jump back in")
                .font(.title3.bold())
                .foregroundStyle(.white)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(jumpBackInItems) { item in
                        jumpBackInCard(item)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private func jumpBackInCard(_ item: ShortcutItem) -> some View {
        switch item {
        case .likedSongs:
            EmptyView()
        case .radio(let station):
            JumpBackInCard(title: station.title, subtitle: "Radio", badge: "Radio", imageURL: station.seedTrack.thumbnailUrl)
                .contentShape(Rectangle())
                .onTapGesture { player.playRadio(for: station.seedTrack) }
        case .playlist(let playlist):
            NavigationLink(value: LibraryDestination.playlist(playlist.id)) {
                JumpBackInCard(title: playlist.name, subtitle: "Playlist", badge: "Playlist", imageURL: playlist.tracks.first?.thumbnailUrl)
            }
            .buttonStyle(.plain)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 0..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    /// Builds "Because you listened to…" shelves from recent local play history, plus a
    /// generic Quick Picks shelf, mirroring Spotify's mix of personalized and general rows.
    private func load() async {
        isLoading = sections.isEmpty
        errorMessage = nil
        do {
            async let quickPicks = APIClient.shared.home()

            let seeds = history.recentSeeds(3)
            var built: [RecommendationSection] = []

            if !seeds.isEmpty {
                let radios = try await withThrowingTaskGroup(of: (Int, [Track]).self) { group -> [[Track]] in
                    for (index, seed) in seeds.enumerated() {
                        group.addTask {
                            let mix = try await APIClient.shared.radio(videoId: seed.videoId, limit: 15)
                            return (index, Array(mix.dropFirst()))
                        }
                    }
                    var results = Array(repeating: [Track](), count: seeds.count)
                    for try await (index, tracks) in group { results[index] = tracks }
                    return results
                }
                for (seed, tracks) in zip(seeds, radios) where !tracks.isEmpty {
                    built.append(RecommendationSection(title: "Because you listened to \(seed.title)", tracks: tracks))
                }
            }

            let picks = try await quickPicks
            if !picks.isEmpty {
                built.append(RecommendationSection(title: "Quick Picks", tracks: picks))
            }
            sections = built
        } catch {
            if sections.isEmpty {
                errorMessage = "Couldn't load Home.\nIs the backend running at 127.0.0.1:8000?"
            }
        }
        isLoading = false
    }
}
