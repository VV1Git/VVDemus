import SwiftUI

/// Swipe-to-queue plus a long-press menu (radio, play next, like), shared by every
/// track list (Home shelves, Search, Library, Queue).
struct TrackRowActions: ViewModifier {
    let track: Track
    @ObservedObject var player: PlayerService
    @ObservedObject private var liked = LikedSongsStore.shared

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button {
                    player.addToQueue(track)
                } label: {
                    Label("Queue", systemImage: "text.badge.plus")
                }
                .tint(Theme.accent)
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
                    player.playRadio(for: track)
                } label: {
                    Label("Go to Radio", systemImage: "dot.radiowaves.left.and.right")
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
    }
}

extension View {
    func trackActions(track: Track, player: PlayerService) -> some View {
        modifier(TrackRowActions(track: track, player: player))
    }
}
