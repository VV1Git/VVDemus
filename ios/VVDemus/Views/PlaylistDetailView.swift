import SwiftUI

struct PlaylistDetailView: View {
    let playlistId: UUID
    @ObservedObject var player: PlayerService
    @ObservedObject private var store = PlaylistStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showRename = false
    @State private var renameText = ""

    private var playlist: Playlist? {
        store.playlists.first { $0.id == playlistId }
    }

    var body: some View {
        Group {
            if let playlist {
                List {
                    if playlist.tracks.isEmpty {
                        Text("No songs yet. Add some from Search or any Radio's \"Add to Playlist\" menu.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .listRowBackground(Theme.background)
                    } else {
                        ForEach(playlist.tracks) { track in
                            TrackRow(track: track, isActive: player.currentTrack?.id == track.id)
                                .listRowBackground(Theme.background)
                                .listRowSeparatorTint(Theme.card)
                                .onTapGesture {
                                    player.play(track: track, context: playlist.tracks, contextTitle: playlist.name)
                                }
                                .trackActions(track: track, player: player)
                        }
                        .onDelete { offsets in store.removeTrack(at: offsets, from: playlist) }
                        .onMove { source, destination in store.moveTrack(in: playlist, from: source, to: destination) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                Text("Playlist deleted")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let playlist {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
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
}
