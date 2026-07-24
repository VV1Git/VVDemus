import SwiftUI

struct MiniPlayerBar: View {
    @ObservedObject var player: PlayerService

    var body: some View {
        if let track = player.currentTrack {
            HStack(spacing: 12) {
                RemoteImage(url: track.thumbnailUrl, size: 40)

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                if player.isLoading {
                    ProgressView().tint(.white)
                } else {
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.cardLight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 8)
        }
    }
}
