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
    /// Reorder moved into the ellipsis menu, so the mode is owned here instead of by an
    /// `EditButton`: the menu item has to read it to label itself and to toggle it back off.
    @State private var editMode: PlatformEditMode = .inactive

    private var playlist: Playlist? {
        store.playlists.first { $0.id == playlistId }
    }

    /// Reordering only makes sense against the playlist's real, unfiltered order.
    private var canReorder: Bool { searchText.isEmpty && sortOption == .order }

    private func visibleTracks(for playlist: Playlist) -> [Track] {
        sortOption.apply(to: filterTracks(playlist.tracks, matching: searchText))
    }

    /// The order on screen, which is what a tapped row has to queue behind itself. See
    /// `AlbumDetailView.playbackContext`: queueing from the unsorted list put the wrong songs
    /// next, and tapping the row that was last in *that* order queued nothing — the one state
    /// that rolls `advance()` into a fresh autoplay radio partway down a visible list.
    ///
    /// Sorted but not filtered, so playing a search hit carries on through the whole playlist
    /// rather than through the handful of rows that matched what was typed.
    private func playbackContext(for playlist: Playlist) -> [Track] {
        sortOption.apply(to: playlist.tracks)
    }

    var body: some View {
        Group {
            if let playlist {
                if playlist.tracks.isEmpty {
                    ContentUnavailableView(
                        "No Songs",
                        systemImage: "music.note.list",
                        description: Text("Add songs from Search, or from any track's \"Add to Playlist\" menu.")
                    )
                } else {
                    trackList(playlist)
                }
            } else {
                ContentUnavailableView(
                    "Playlist Deleted",
                    systemImage: "trash",
                    description: Text("This playlist is no longer in your library.")
                )
            }
        }
        .background(Theme.screenBackground)
        .navigationTitle(playlist?.name ?? "Playlist")
        .compactNavigationTitle()
        .toolbar {
            if let playlist {
                ToolbarItem(placement: .trailingActions) {
                    Menu {
                        MixSortPicker(selection: $sortOption)
                        Section {
                            // No Mac equivalent, and none needed: a List row with `.onMove`
                            // is draggable there without switching into a mode first.
                            #if os(iOS)
                            if canReorder && !playlist.tracks.isEmpty {
                                Button {
                                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                                } label: {
                                    Label(editMode.isEditing ? "Done Reordering" : "Reorder",
                                          systemImage: "arrow.up.arrow.down")
                                }
                            }
                            #endif
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
                        Label("More", systemImage: "ellipsis")
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
        // Searching or re-sorting hides the Reorder item, which would otherwise strand the
        // list in edit mode with no way back out.
        .onChange(of: canReorder) { _, allowed in
            if !allowed { editMode = .inactive }
        }
        // Home's shortcut grid orders by when you last opened a thing, and a playlist's only
        // other timestamp is `createdAt` — so without this a playlist made a year ago and
        // opened a minute ago sorts to the bottom of a grid that is entirely about recency.
        .task { RecentOpensStore.shared.markOpened(RecentOpensStore.playlistKey(playlistId)) }
    }

    @ViewBuilder
    private func trackList(_ playlist: Playlist) -> some View {
        let visible = visibleTracks(for: playlist)
        List {
            MixDetailHeader(
                title: playlist.name,
                subtitle: "Playlist",
                imageURL: playlist.tracks.first?.thumbnailUrl,
                trackCount: playlist.tracks.count,
                totalDuration: totalDuration(of: playlist.tracks),
                tracks: playlist.tracks,
                onPlay: { playAll(playlist, shuffled: false) },
                onShuffle: { playAll(playlist, shuffled: true) }
            )
            .mixHeaderRowMetrics()

            if visible.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(visible) { track in
                    TrackRow(track: track, isActive: player.currentTrack?.id == track.id) {
                        player.play(track: track, context: playbackContext(for: playlist), contextTitle: playlist.name)
                    }
                    .trackRowMetrics()
                    .trackActions(track: track, player: player, includesTrailingSwipes: false) {
                        // Handed to the shared menu rather than attached as a second
                        // `.contextMenu`, which would have cost the row one of the two menus.
                        // The desktop has no other way to remove a song: a mouse cannot swipe.
                        Button(role: .destructive) {
                            store.removeTrack(track, from: playlist)
                        } label: {
                            Label("Remove from Playlist", systemImage: "trash")
                        }
                    }
                    // Remove lives on the trailing edge like every other destructive swipe in
                    // the app; leading-swipe-to-delete both contradicted "add to queue" and
                    // fought the interactive pop-back gesture.
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Haptics.impact()
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

            TransportClearanceRow()
        }
        .listStyle(.plain)
        .platformEditMode($editMode)
        .searchable(text: $searchText, prompt: "Find on this page")
    }

    private func playAll(_ playlist: Playlist, shuffled: Bool) {
        guard !playlist.tracks.isEmpty else { return }
        let ordered = shuffled ? playlist.tracks.shuffled() : playbackContext(for: playlist)
        player.play(track: ordered[0], context: ordered, contextTitle: playlist.name)
    }
}
