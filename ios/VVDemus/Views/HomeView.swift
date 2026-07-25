import SwiftUI

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
    @ObservedObject private var daylist = DaylistStore.shared
    @ObservedObject private var network = NetworkMonitor.shared
    @State private var sections: [RecommendationsBuilder.Section] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        Text(greeting)
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                        Spacer()
                        if !network.isConnected {
                            Label("Offline", systemImage: "wifi.slash")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Theme.cardLight)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    NavigationLink(value: LibraryDestination.daylist) {
                        DaylistCard(
                            title: daylist.title.isEmpty ? "Your Daylist" : daylist.title,
                            imageURL: daylist.tracks.first?.thumbnailUrl
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)

                    if !shortcuts.isEmpty {
                        shortcutGrid
                    }

                    if !radioHistory.stations.isEmpty {
                        mixShelf(title: "Your Radio", badge: "Radio", stations: radioHistory.stations)
                    }

                    if !playlists.playlists.isEmpty {
                        mixShelf(title: "Your Playlists", playlists: playlists.playlists)
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
                case .radio(let seed):
                    RadioDetailView(seedTrack: seed, player: player)
                case .daylist:
                    DaylistDetailView(player: player)
                case .downloads:
                    DownloadsView(player: player)
                case .stats:
                    StatsView(player: player)
                }
            }
            .environment(\.openRadio) { track in path.append(LibraryDestination.radio(track)) }
        }
        .task { await load() }
        .task { await daylist.refreshIfNeeded() }
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
            NavigationLink(value: LibraryDestination.radio(station.seedTrack)) {
                ShortcutRow(title: station.title, imageURL: station.seedTrack.thumbnailUrl, systemImageFallback: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.plain)
        case .playlist(let playlist):
            NavigationLink(value: LibraryDestination.playlist(playlist.id)) {
                ShortcutRow(title: playlist.name, imageURL: playlist.tracks.first?.thumbnailUrl, systemImageFallback: "music.note.list")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Your Radio / Your Playlists shelves

    private func mixShelf(title: String, badge: String? = nil, stations: [RadioStation] = [], playlists: [Playlist] = []) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(stations) { station in
                        NavigationLink(value: LibraryDestination.radio(station.seedTrack)) {
                            JumpBackInCard(title: station.title, subtitle: "Radio", badge: "Radio", imageURL: station.seedTrack.thumbnailUrl)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(playlists) { playlist in
                        NavigationLink(value: LibraryDestination.playlist(playlist.id)) {
                            JumpBackInCard(title: playlist.name, subtitle: "Playlist", badge: nil, imageURL: playlist.tracks.first?.thumbnailUrl)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
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

            var built = try await RecommendationsBuilder.build(seeds: history.recentSeeds(3))

            let picks = try await quickPicks
            if !picks.isEmpty {
                built.append(RecommendationsBuilder.Section(title: "Quick Picks", tracks: picks))
            }
            sections = built
        } catch {
            if sections.isEmpty {
                errorMessage = "Couldn't load Home. Check your connection and try again."
            }
        }
        isLoading = false
    }
}
