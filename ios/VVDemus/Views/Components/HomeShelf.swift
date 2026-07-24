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
                            }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
