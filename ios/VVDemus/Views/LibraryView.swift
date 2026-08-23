import SwiftUI

struct LibraryView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject private var playlists = PlaylistStore.shared
    @ObservedObject private var radioHistory = RadioHistoryStore.shared
    @ObservedObject private var albumHistory = AlbumHistoryStore.shared
    @ObservedObject private var daylist = DaylistStore.shared
    @State private var showNewPlaylist = false
    @State private var showSpotifyImport = false
    @State private var newPlaylistName = ""
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: LibraryDestination.daylist) {
                        LibraryRow(title: daylist.title.isEmpty ? "Your Daylist" : daylist.title) {
                            if let art = daylist.tracks.first?.thumbnailUrl {
                                RemoteImage(url: art, size: Theme.ArtSize.row)
                            } else {
                                LibraryRowIcon(systemImage: "sun.max.fill")
                            }
                        }
                    }
                    .trackRowMetrics()

                    NavigationLink(value: LibraryDestination.liked) {
                        LibraryRow(title: "Liked Songs") {
                            LibraryRowIcon(systemImage: "heart.fill")
                        }
                    }
                    .trackRowMetrics()

                    NavigationLink(value: LibraryDestination.downloads) {
                        LibraryRow(title: "Downloads") {
                            LibraryRowIcon(systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .trackRowMetrics()

                    NavigationLink(value: LibraryDestination.stats) {
                        LibraryRow(title: "Your Stats") {
                            LibraryRowIcon(systemImage: "chart.bar.fill")
                        }
                    }
                    .trackRowMetrics()
                }

                Section("Your Playlists") {
                    if playlists.playlists.isEmpty {
                        ContentUnavailableView {
                            Label("No Playlists", systemImage: "music.note.list")
                        } description: {
                            Text("Tap + to create your first playlist.")
                        }
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(playlists.playlists) { playlist in
                            NavigationLink(value: LibraryDestination.playlist(playlist.id)) {
                                LibraryRow(title: playlist.name,
                                           subtitle: "^[\(playlist.tracks.count) song](inflect: true)") {
                                    if let art = playlist.tracks.first?.thumbnailUrl {
                                        RemoteImage(url: art, size: Theme.ArtSize.row)
                                    } else {
                                        LibraryRowIcon(systemImage: "music.note.list",
                                                       fill: Theme.card,
                                                       glyph: .secondary)
                                    }
                                }
                            }
                            .trackRowMetrics()
                            // The same removal as a long press, because both gestures below want
                            // a finger: a mouse cannot swipe, and this screen has no Edit button,
                            // so on the Mac a playlist was here for good. The detail view's
                            // ellipsis menu offers it too, but only once the playlist is open.
                            .contextMenu {
                                Button(role: .destructive) {
                                    withAnimation { playlists.delete(playlist) }
                                } label: {
                                    Label("Delete Playlist", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { playlists.playlists[$0] }.forEach(playlists.delete)
                        }
                    }
                }

                if !albumHistory.albums.isEmpty {
                    Section("Albums") {
                        ForEach(albumHistory.albums) { album in
                            NavigationLink(value: LibraryDestination.album(album)) {
                                // No chevron of its own — the `NavigationLink` supplies the
                                // system one, and the two do not line up beside each other.
                                AlbumRow(album: album, showsChevron: false)
                            }
                            .trackRowMetrics()
                            // Mouse-reachable removal, for the reason the sections above give:
                            // a mouse cannot swipe, so without this an album is here for good
                            // on the Mac.
                            .contextMenu {
                                Button(role: .destructive) {
                                    withAnimation { albumHistory.delete(album) }
                                } label: {
                                    Label("Remove Album", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete { albumHistory.delete(at: $0) }
                    }
                }

                if !radioHistory.stations.isEmpty {
                    Section("Your Radio") {
                        ForEach(radioHistory.stations) { station in
                            NavigationLink(value: LibraryDestination.radio(station.seedTrack)) {
                                // Second line so a radio row is the same height as a
                                // playlist row, which now sits directly above it.
                                LibraryRow(title: station.title,
                                           subtitle: "Radio · \(station.seedTrack.artist)") {
                                    RemoteImage(url: station.seedTrack.thumbnailUrl, size: Theme.ArtSize.row)
                                }
                            }
                            .trackRowMetrics()
                            // Mouse-reachable removal, for the reason the playlist section above
                            // gives: without it a saved radio was here for good on the Mac.
                            .contextMenu {
                                Button(role: .destructive) {
                                    withAnimation { radioHistory.delete(station) }
                                } label: {
                                    Label("Remove Radio", systemImage: "trash")
                                }
                            }
                        }
                        // Swipe-to-delete and Edit-mode delete, the same two gestures the
                        // playlist section above already answers to.
                        .onDelete { radioHistory.delete(at: $0) }
                    }
                }

                TransportClearanceRow()
            }
            .listStyle(.plain)
            .navigationTitle("Your Library")
            .navigationDestination(for: LibraryDestination.self) { destination in
                destination.destination(player: player)
            }
            .toolbar {
                ToolbarItemGroup(placement: .trailingActions) {
                    Button {
                        path.append(LibraryDestination.settings)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .labelStyle(.iconOnly)
                    }

                    // Still a bare "+" glyph, now with two ways to fill a playlist behind it.
                    // `.iconOnly` belongs on the menu's own label and nowhere inside it: the
                    // items need their text, or the menu is two unlabelled icons.
                    Menu {
                        Button {
                            showNewPlaylist = true
                        } label: {
                            Label("New Playlist", systemImage: "plus")
                        }
                        Button {
                            showSpotifyImport = true
                        } label: {
                            Label("Import from Spotify…", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                            .labelStyle(.iconOnly)
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
            // Attached to the `List`, beside the alert, rather than to the toolbar content:
            // toolbar items are hoisted into the navigation bar and do not reliably inherit the
            // environment written onto the list below them (see the note in `QueueView`).
            .sheet(isPresented: $showSpotifyImport) {
                SpotifyImportSheet()
            }
        }
        // On the stack rather than on the list inside it, so the playlists, albums and radios
        // this screen pushes get it as well — see the note in `MacRootView.detail`.
        .environment(\.openRadio) { track in path.append(LibraryDestination.radio(track)) }
        .environment(\.openLyrics) { track in path.append(LibraryDestination.lyrics(track)) }
    }
}

// MARK: - Row primitives

/// One row shape for everything in the Library list — shortcuts, radios and playlists —
/// built to the same geometry as `TrackRow` (48pt artwork · 12pt gap · title/subtitle) so
/// every leading edge and every separator on this screen lines up with the track rows on
/// the screens it pushes to.
private struct LibraryRow<Leading: View>: View {
    let title: String
    /// A key, not a `String`, so the inflection markup in "^[n song](inflect: true)" is
    /// actually resolved instead of printed.
    var subtitle: LocalizedStringKey?
    let leading: Leading

    init(title: String, subtitle: LocalizedStringKey? = nil, @ViewBuilder leading: () -> Leading) {
        self.title = title
        self.subtitle = subtitle
        self.leading = leading()
    }

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            leading
                .frame(width: Theme.ArtSize.row, height: Theme.ArtSize.row)
            VStack(alignment: .leading, spacing: Theme.Metrics.labelSpacing) {
                Text(title)
                    .font(.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.rowSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.md)
        }
        .frame(minHeight: Theme.ArtSize.row)
    }
}

/// Stands in for artwork on rows that have none. Same size and same corner radius as
/// `RemoteImage` at row size, so an icon row and an artwork row can sit next to each other.
private struct LibraryRowIcon: View {
    let systemImage: String
    var fill: Color = Theme.accent
    var glyph: Color = .white

    var body: some View {
        Theme.Radius.rect(Theme.Radius.art(for: Theme.ArtSize.row))
            .fill(fill)
            .overlay {
                Image(systemName: systemImage)
                    .font(.title3)
                    // Drawn on top of a filled tile rather than the screen background, so
                    // the semantic colours don't apply.
                    .foregroundStyle(glyph)
            }
            .accessibilityHidden(true)
    }
}
