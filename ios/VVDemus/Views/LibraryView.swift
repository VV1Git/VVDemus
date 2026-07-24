import SwiftUI

struct LibraryView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject private var playlists = PlaylistStore.shared
    @ObservedObject private var radioHistory = RadioHistoryStore.shared
    @ObservedObject private var daylist = DaylistStore.shared
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var path = NavigationPath()
    @AppStorage(InnerTubeClient.dataSaverDefaultsKey) private var dataSaverEnabled = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: LibraryDestination.daylist) {
                        ShortcutRow(
                            title: daylist.title.isEmpty ? "Your Daylist" : daylist.title,
                            imageURL: daylist.tracks.first?.thumbnailUrl,
                            systemImageFallback: "sun.max.fill"
                        )
                    }
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)

                    NavigationLink(value: LibraryDestination.liked) {
                        ShortcutRow(title: "Liked Songs", imageURL: nil, systemImageFallback: "heart.fill")
                    }
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)

                    NavigationLink(value: LibraryDestination.downloads) {
                        ShortcutRow(title: "Downloads", imageURL: nil, systemImageFallback: "arrow.down.circle.fill")
                    }
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
                }

                if !radioHistory.stations.isEmpty {
                    Section("Radio") {
                        ForEach(radioHistory.stations) { station in
                            NavigationLink(value: LibraryDestination.radio(station.seedTrack)) {
                                HStack(spacing: 12) {
                                    RemoteImage(url: station.seedTrack.thumbnailUrl, size: 48)
                                    Text(station.title)
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                }
                            }
                            .listRowBackground(Theme.background)
                            .listRowSeparatorTint(Theme.card)
                        }
                    }
                }

                Section("Playlists") {
                    if playlists.playlists.isEmpty {
                        Text("Tap + to create your first playlist.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .listRowBackground(Theme.background)
                    } else {
                        ForEach(playlists.playlists) { playlist in
                            NavigationLink(value: LibraryDestination.playlist(playlist.id)) {
                                HStack(spacing: 12) {
                                    if let art = playlist.tracks.first?.thumbnailUrl {
                                        RemoteImage(url: art, size: 48)
                                    } else {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Theme.card)
                                            .frame(width: 48, height: 48)
                                            .overlay(
                                                Image(systemName: "music.note.list")
                                                    .foregroundStyle(Theme.textSecondary)
                                            )
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Text("\(playlist.tracks.count) songs")
                                            .font(.caption)
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                            }
                            .listRowBackground(Theme.background)
                            .listRowSeparatorTint(Theme.card)
                        }
                        .onDelete { offsets in
                            offsets.map { playlists.playlists[$0] }.forEach(playlists.delete)
                        }
                    }
                }

                Section {
                    Toggle("Data Saver", isOn: $dataSaverEnabled)
                        .tint(Theme.accent)
                        .listRowBackground(Theme.background)
                } footer: {
                    Text("Streams at a lower audio bitrate to use noticeably less cellular data, at the cost of some sound quality.")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Your Library")
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
                }
            }
            .environment(\.openRadio) { track in path.append(LibraryDestination.radio(track)) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewPlaylist = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New Playlist", isPresented: $showNewPlaylist) {
                TextField("Playlist name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) { newPlaylistName = "" }
                Button("Create") {
                    let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { playlists.create(name: name) }
                    newPlaylistName = ""
                }
            }
        }
    }
}
