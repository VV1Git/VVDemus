import SwiftUI

/// Swipe-to-queue plus a long-press menu (radio, play next, like, add to playlist),
/// shared by every track list (Home shelves, Search, Library, Queue).
struct TrackRowActions<Extra: View>: ViewModifier {
    let track: Track
    @ObservedObject var player: PlayerService
    /// Screens that own the trailing edge themselves (Queue removes, Playlist deletes)
    /// pass `false`. Two `.swipeActions(edge: .trailing)` on one row stack into a single
    /// crammed set with an ambiguous full-swipe, so only one modifier may claim the edge.
    var includesTrailingSwipes: Bool = true
    /// A screen's own menu entries, folded into the one menu below. SwiftUI honours a single
    /// `.contextMenu` per view, so a screen that attached its own second one silently lost
    /// either its item or the whole shared menu — whichever the framework dropped.
    let extraMenuItems: Extra
    @ObservedObject private var liked = LikedSongsStore.shared
    @ObservedObject private var playlists = PlaylistStore.shared
    // No `DownloadManager` here: the download item lives in `TrackMenuItems`, which observes
    // it itself. Observing it on the modifier re-rendered every row on every progress tick.
    @Environment(\.openRadio) private var openRadio
    @Environment(\.openLyrics) private var openLyrics
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
                // `openRadio` and `openLyrics` are resolved out here, on the modifier, and
                // handed in: custom environment values do not reliably reach a
                // `contextMenu`'s content.
                TrackMenuItems(
                    track: track,
                    player: player,
                    onRadio: { openRadio(track) },
                    onLyrics: { openLyrics(track) },
                    showNewPlaylistAlert: $showNewPlaylistAlert
                )
                // Last, and in its own section: screen-specific items are the destructive ones
                // (Playlist's "Remove from Playlist"), which belong at the bottom for the same
                // reason `TrackMenuItems` groups its own that way. The type test keeps the
                // rows that pass nothing from carrying an empty section's divider.
                if Extra.self != EmptyView.self {
                    Section { extraMenuItems }
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
    /// Nil hides "Show Lyrics", for the same reason: Now Playing presents the lyrics itself,
    /// as a cover over its own sheet, because there is no stack under it to push onto.
    var onLyrics: (() -> Void)?
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
            // Only appears when the paired device is a phone, so it is absent on the phone
            // itself rather than needing a platform check here.
            DownloadToPhoneButton(tracks: [track])
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
            if let onLyrics {
                Button(action: onLyrics) {
                    Label("Show Lyrics", systemImage: "quote.bubble")
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
    /// The shared row actions, plus `menuItems`: entries only this screen can offer, appended
    /// to the single context menu the row is allowed. Reach for it instead of stacking a
    /// second `.contextMenu` on the row, which drops one of the two menus.
    func trackActions<Extra: View>(
        track: Track,
        player: PlayerService,
        includesTrailingSwipes: Bool = true,
        @ViewBuilder menuItems: () -> Extra
    ) -> some View {
        modifier(TrackRowActions(track: track, player: player,
                                 includesTrailingSwipes: includesTrailingSwipes,
                                 extraMenuItems: menuItems()))
    }

    /// A separate overload rather than a `menuItems` default, because Swift cannot infer a
    /// generic parameter from a default argument — the call sites with nothing to add would
    /// stop compiling.
    func trackActions(track: Track, player: PlayerService, includesTrailingSwipes: Bool = true) -> some View {
        trackActions(track: track, player: player,
                     includesTrailingSwipes: includesTrailingSwipes) { EmptyView() }
    }
}
