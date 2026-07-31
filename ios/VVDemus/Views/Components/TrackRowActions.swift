import SwiftUI

/// Swipe-to-queue plus a long-press menu (radio, play next, like, add to playlist),
/// shared by every track list (Home shelves, Search, Library, Queue).
struct TrackRowActions: ViewModifier {
    let track: Track
    @ObservedObject var player: PlayerService
    /// Screens that own the trailing edge themselves (Queue removes, Playlist deletes)
    /// pass `false`. Two `.swipeActions(edge: .trailing)` on one row stack into a single
    /// crammed set with an ambiguous full-swipe, so only one modifier may claim the edge.
    var includesTrailingSwipes: Bool = true
    @ObservedObject private var liked = LikedSongsStore.shared
    @ObservedObject private var playlists = PlaylistStore.shared
    // No `DownloadManager` here: the download item lives in `TrackMenuItems`, which observes
    // it itself. Observing it on the modifier re-rendered every row on every progress tick.
    @Environment(\.openRadio) private var openRadio
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""

    @ViewBuilder
    func body(content: Content) -> some View {
        if includesTrailingSwipes {
            // Swiping the other way reaches the two actions otherwise buried in the
            // long-press menu. Like is full-swipeable because it's the one you reach for
            // mid-song without wanting to look at the screen.
            base(content: content)
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
                    // Green is "this is yours"; undoing it is neutral, not another success.
                    .tint(liked.isLiked(track) ? Color(.systemGray) : Theme.accent)

                    Button {
                        Haptics.impact()
                        player.playNext(track)
                    } label: {
                        Label("Play Next", systemImage: "text.insert")
                    }
                    .tint(.indigo)
                }
        } else {
            base(content: content)
        }
    }

    /// Everything that is safe to attach on every screen: the leading swipe, the menu and
    /// the new-playlist alert the menu can raise.
    private func base(content: Content) -> some View {
        content
            // Swipe right (leading edge) to add to queue — matches Spotify's convention.
            // Indigo, not green: queueing is a transient action, not "this is saved".
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    Haptics.impact()
                    player.addToQueue(track)
                } label: {
                    Label("Add to Queue", systemImage: "text.badge.plus")
                }
                .tint(.indigo)
            }
            .contextMenu {
                // `openRadio` is resolved out here, on the modifier, and handed in: custom
                // environment values do not reliably reach a `contextMenu`'s content.
                TrackMenuItems(
                    track: track,
                    player: player,
                    onRadio: { openRadio(track) },
                    showNewPlaylistAlert: $showNewPlaylistAlert
                )
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

/// The track action menu, shared by every row's long-press menu and by Now Playing's
/// ellipsis button so the two can't drift apart.
///
/// Grouped so the destructive item sits alone at the bottom, where the system expects it,
/// instead of fourth of six.
struct TrackMenuItems: View {
    let track: Track
    @ObservedObject var player: PlayerService
    /// Nil hides "Go to Radio". Now Playing is a full-screen cover presented above every
    /// NavigationStack, so it has nowhere to push a radio to.
    var onRadio: (() -> Void)?
    @Binding var showNewPlaylistAlert: Bool
    @ObservedObject private var liked = LikedSongsStore.shared
    @ObservedObject private var playlists = PlaylistStore.shared
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        Section {
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
        Section {
            if let onRadio {
                Button(action: onRadio) {
                    Label("Go to Radio", systemImage: "dot.radiowaves.left.and.right")
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
        }
        Section {
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
        }
    }
}

extension View {
    func trackActions(track: Track, player: PlayerService, includesTrailingSwipes: Bool = true) -> some View {
        modifier(TrackRowActions(track: track, player: player,
                                 includesTrailingSwipes: includesTrailingSwipes))
    }
}
