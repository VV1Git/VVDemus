import SwiftUI

struct PlaylistDetailView: View {
    let playlistId: UUID
    @ObservedObject var player: PlayerService
    @ObservedObject private var store = PlaylistStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showRename = false
    @State private var renameText = ""
    @State private var searchText = ""
    @State private var sortOption: MixSortOption = .order

    private var playlist: Playlist? {
        store.playlists.first { $0.id == playlistId }
    }

    /// Reordering only makes sense against the playlist's real, unfiltered order.
    private var canReorder: Bool { searchText.isEmpty && sortOption == .order }

    private func visibleTracks(for playlist: Playlist) -> [Track] {
        sortOption.apply(to: filterTracks(playlist.tracks, matching: searchText))
    }

    var body: some View {
        Group {
            if let playlist {
                List {
                    MixDetailHeader(
                        title: playlist.name,
                        subtitle: "Playlist",
                        badge: nil,
                        imageURL: playlist.tracks.first?.thumbnailUrl,
                        trackCount: playlist.tracks.count,
                        totalDuration: totalDuration(of: playlist.tracks),
                        onPlay: { playAll(playlist, shuffled: false) },
                        onShuffle: { playAll(playlist, shuffled: true) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)

                    if playlist.tracks.isEmpty {
                        Text("No songs yet. Add some from Search or any track's \"Add to Playlist\" menu.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .listRowBackground(Theme.background)
                    } else {
                        ForEach(visibleTracks(for: playlist)) { track in
                            TrackRow(track: track, isActive: player.currentTrack?.id == track.id)
                                .listRowBackground(Theme.background)
                                .listRowSeparatorTint(Theme.card)
                                .onTapGesture {
                                    player.play(track: track, context: playlist.tracks, contextTitle: playlist.name)
                                }
                                .trackActions(track: track, player: player)
                                .swipeActions(edge: .leading) {
                                    Button(role: .destructive) {
                                        store.removeTrack(track, from: playlist)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                                .moveDisabled(!canReorder)
                        }
                        .onMove { source, destination in
                            guard canReorder else { return }
                            store.moveTrack(in: playlist, from: source, to: destination)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Theme.background)
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find on this page")
            } else {
                Text("Playlist deleted")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let playlist {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section {
                            ForEach(MixSortOption.allCases, id: \.self) { option in
                                Button(option.label(orderLabel: "Playlist order")) { sortOption = option }
                            }
                        }
                        Section {
                            Button {
                                renameText = playlist.name
                                showRename = true
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                store.delete(playlist)
                                dismiss()
                            } label: {
                                Label("Delete Playlist", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("Rename Playlist", isPresented: $showRename) {
            TextField("Playlist name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if let playlist, !trimmed.isEmpty {
                    store.rename(playlist, to: trimmed)
                }
            }
        }
    }

    private func playAll(_ playlist: Playlist, shuffled: Bool) {
        guard !playlist.tracks.isEmpty else { return }
        let ordered = shuffled ? playlist.tracks.shuffled() : playlist.tracks
        player.play(track: ordered[0], context: ordered, contextTitle: playlist.name)
    }
}
