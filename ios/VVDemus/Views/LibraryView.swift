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
    @AppStorage(LocalControlServer.defaultsKey) private var connectEnabled = true
    @ObservedObject private var controlServer = LocalControlServer.shared
    @ObservedObject private var byteCounter = NetworkByteCounter.shared
    @State private var imageCacheBytes: Int64 = 0

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

                    NavigationLink(value: LibraryDestination.stats) {
                        ShortcutRow(title: "Your Stats", imageURL: nil, systemImageFallback: "chart.bar.fill")
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
                    HStack {
                        Text("Version")
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(AppVersion.summary)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                    }
                    .listRowBackground(Theme.background)
                }

                Section {
                    Toggle("Data Saver", isOn: $dataSaverEnabled)
                        .tint(Theme.accent)
                        .listRowBackground(Theme.background)
                } footer: {
                    // Deliberately modest, because the measurements say so
                    // (VVDemusTests/DataUsageBenchmarks):
                    //  · Bitrate: no effect today. The low-bitrate audio-only formats are
                    //    only reachable through a client YouTube currently refuses, so
                    //    every track comes from the one muxed format there is.
                    //  · Batch limits: no effect. They're applied to an already-downloaded
                    //    response; there is no count parameter to ask for less.
                    //  · Artwork and read-ahead: real, and measured.
                    Text("Requests smaller artwork and reads less far ahead, so skipping a track wastes less of what was already downloaded. Audio quality is unchanged — YouTube currently only offers this app one audio format, so the bitrate can't be lowered.")
                }

                Section {
                    ForEach(NetworkByteCounter.Category.allCases) { category in
                        HStack {
                            Text(category.rawValue)
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text(Self.formattedBytes(byteCounter.bytes[category] ?? 0))
                                .foregroundStyle(.white)
                                .font(.system(.footnote, design: .monospaced))
                        }
                        .listRowBackground(Theme.background)
                    }
                    // Worth showing next to the counters: the artwork cache is what stops
                    // those numbers climbing on every relaunch, so its size is the visible
                    // evidence that caching is working.
                    HStack {
                        Text("Artwork cache")
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(Self.formattedBytes(imageCacheBytes))
                            .foregroundStyle(.white)
                            .font(.system(.footnote, design: .monospaced))
                    }
                    .listRowBackground(Theme.background)
                    .task { imageCacheBytes = await DiskImageCache.shared.totalBytes() }

                    Button("Reset Counters") { byteCounter.reset() }
                        .listRowBackground(Theme.background)
                    Button("Clear Image Cache") {
                        Task {
                            await DiskImageCache.shared.clear()
                            imageCacheBytes = 0
                        }
                    }
                    .listRowBackground(Theme.background)
                } header: {
                    Text("Network Usage (this session)")
                } footer: {
                    Text("Doesn't include live-streaming playback bytes — AVPlayer manages that networking internally, so compare cellular usage in iOS Settings for a full before/after picture.")
                }

                Section {
                    Toggle(
                        "VVDemus Connect",
                        isOn: $connectEnabled
                    )
                    // `.onChange` rather than a side effect inside a Binding setter, which
                    // mutates an ObservableObject this view observes while it is rendering.
                    .onChange(of: connectEnabled) { _, enabled in
                        enabled ? controlServer.start() : controlServer.stop()
                    }
                    .tint(Theme.accent)
                    .listRowBackground(Theme.background)

                    if controlServer.isRunning {
                        HStack {
                            Text("Open on your computer")
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text(verbatim: controlServer.localAddress.map { "http://\($0):\(controlServer.port)" } ?? "Finding address…")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.white)
                                .textSelection(.enabled)
                        }
                        .listRowBackground(Theme.background)
                    }

                    // A toggle left switched on next to a blank address is
                    // indistinguishable from "still starting up"; say what went wrong.
                    if let startupError = controlServer.startupError {
                        Text(startupError)
                            .font(.footnote)
                            .foregroundStyle(Theme.accent)
                            .listRowBackground(Theme.background)
                    }
                } footer: {
                    Text("Lets a browser on the same WiFi network see what's playing and control it — or play it through the computer's own speakers instead. No account or pairing needed, so only turn this on when you're on a network you trust.")
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
                case .stats:
                    StatsView(player: player)
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

    private static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
