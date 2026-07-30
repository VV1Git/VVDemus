import SwiftUI

struct LikedSongsView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject private var liked = LikedSongsStore.shared

    var body: some View {
        Group {
            if liked.tracks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "heart")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.textSecondary)
                    Text("Songs you like will appear here")
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(liked.tracks) { track in
                        TrackRow(track: track, isActive: player.currentTrack?.id == track.id)
                            .listRowBackground(Theme.background)
                            .listRowSeparatorTint(Theme.card)
                            .onTapGesture { player.play(track: track, context: liked.tracks, contextTitle: "Liked Songs") }
                            .trackActions(track: track, player: player)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.background)
        .navigationTitle("Liked Songs")
        .navigationBarTitleDisplayMode(.inline)
    }
}
