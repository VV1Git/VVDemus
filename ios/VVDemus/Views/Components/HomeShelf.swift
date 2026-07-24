import SwiftUI

struct HomeShelf: View {
    let title: String
    let tracks: [Track]
    @ObservedObject var player: PlayerService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(tracks) { track in
                        TrackCard(track: track, isActive: player.currentTrack?.id == track.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                player.play(track: track, context: tracks, contextTitle: title)
                            }
                            .trackActions(track: track, player: player)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
