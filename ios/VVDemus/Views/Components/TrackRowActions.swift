import SwiftUI

/// Swipe-to-queue plus a long-press menu (radio, play next, like, add to playlist),
/// shared by every track list (Home shelves, Search, Library, Queue).
struct TrackRowActions: ViewModifier {
    let track: Track
    @ObservedObject var player: PlayerService
    @ObservedObject private var liked = LikedSongsStore.shared
    @ObservedObject private var playlists = PlaylistStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @Environment(\.openRadio) private var openRadio
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""

    func body(content: Content) -> some View {
        content
            // Swipe right (leading edge) to add to queue — matches Spotify's convention.
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    Haptics.impact()
                    player.addToQueue(track)
                } label: {
                    Label("Queue", systemImage: "text.badge.plus")
                }
                .tint(Theme.accent)
            }
            // Swiping the other way reaches the two actions otherwise buried in the
            // long-press menu. Like is full-swipeable because it's the one you reach for
            // mid-song without wanting to look at the screen.
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button {
                    Haptics.impact()
                    liked.toggle(track)
                } label: {
                    Label(
                        liked.isLiked(track) ? "Unlike" : "Like",
                        systemImage: liked.isLiked(track) ? "heart.slash.fill" : "heart.fill"
                    )
                }
                .tint(liked.isLiked(track) ? Theme.cardLight : .pink)

                Button {
                    Haptics.impact()
                    player.playNext(track)
                } label: {
                    Label("Play Next", systemImage: "text.insert")
                }
                .tint(Theme.cardLight)
            }
            .contextMenu {
                Button {
                    player.playNext(track)
                } label: {
                    Label("Play Next", systemImage: "text.insert")
                }
                Button {
                    player.addToQueue(track)
                } label: {
                    Label("Add to Queue", systemImage: "text.badge.plus")
                }
                Button {
                    openRadio(track)
                } label: {
                    Label("Go to Radio", systemImage: "dot.radiowaves.left.and.right")
                }
                if downloads.isDownloaded(track) {
                    Button(role: .destructive) {
                        downloads.remove(track)
                    } label: {
                        Label("Remove Download", systemImage: "trash")
                    }
                } else if !downloads.isDownloading(track) {
                    Button {
                        downloads.download(track)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
                Button {
                    liked.toggle(track)
                } label: {
                    Label(
                        liked.isLiked(track) ? "Unlike" : "Like",
                        systemImage: liked.isLiked(track) ? "heart.slash" : "heart"
                    )
                }
                Menu {
                    ForEach(playlists.playlists) { playlist in
                        Button(playlist.name) {
                            playlists.addTrack(track, to: playlist)
                        }
                    }
                    Button {
                        showNewPlaylistAlert = true
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                } label: {
                    Label("Add to Playlist", systemImage: "plus.circle")
                }
            }
            .alert("New Playlist", isPresented: $showNewPlaylistAlert) {
                TextField("Playlist name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) { newPlaylistName = "" }
                Button("Create") {
                    let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        let playlist = playlists.create(name: name)
                        playlists.addTrack(track, to: playlist)
                    }
                    newPlaylistName = ""
                }
            }
    }
}

extension View {
    func trackActions(track: Track, player: PlayerService) -> some View {
        modifier(TrackRowActions(track: track, player: player))
    }
}
