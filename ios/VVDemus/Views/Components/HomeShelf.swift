import SwiftUI

/// A horizontally scrolling shelf: a header sitting on the screen gutter, and a row of
/// cards that scroll past it.
///
/// Generic over its cards so Home's recommendation, radio and playlist shelves can't
/// drift apart again — the hand-copied second version had already reached a different
/// card width and a different card spacing.
struct HomeShelf<Content: View>: View {
    let title: String
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title)
                .font(.shelfHeader)
                .foregroundStyle(.primary)
                .padding(.horizontal, Theme.Metrics.gutter)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Theme.Space.md) {
                    content
                }
                .padding(.horizontal, Theme.Metrics.gutter)
            }
        }
        // Each shelf owns the gap above its own header, so the page's outer stack runs at
        // spacing 0 and blocks that aren't shelves aren't forced into the same rhythm.
        .padding(.top, Theme.Space.xl)
    }
}

/// Home's recommendation shelves: tapping a card starts that track with the shelf as its
/// playback context.
struct TrackShelf: View {
    let title: String
    let tracks: [Track]
    @ObservedObject var player: PlayerService
    @ObservedObject private var peer = PeerPlayback.shared

    /// Marks the card the session is on, wherever that session lives.
    ///
    /// `player.currentTrack` is only the right answer on the device that owns the session; the
    /// mirroring one has a deliberately empty player, so testing it meant no card on Home was
    /// ever marked as playing there. `displayedTrack` resolves to this device's own player when
    /// it owns the session, so it is the whole test — the same rule the list rows use.
    private func isCurrent(_ track: Track) -> Bool {
        peer.displayedTrack?.id == track.id
    }

    var body: some View {
        HomeShelf(title: title) {
            ForEach(tracks) { track in
                // A Button rather than `.onTapGesture` purely so the card gets
                // press feedback — a bare tap gesture gives none.
                Button {
                    player.play(track: track, context: tracks, contextTitle: title)
                } label: {
                    TrackCard(track: track, isActive: isCurrent(track))
                }
                .buttonStyle(.pressableCard)
                .trackActions(track: track, player: player)
            }
        }
    }
}
