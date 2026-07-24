import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject private var liked = LikedSongsStore.shared
    @ObservedObject private var colorLoader = ArtworkColorLoader.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [colorLoader.color(for: player.currentTrack), Theme.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                header

                Spacer()

                RemoteImage(url: player.currentTrack?.thumbnailUrl, size: 300, cornerRadius: 12)
                    .shadow(color: .black.opacity(0.4), radius: 20, y: 10)

                titleRow

                if let errorMessage = player.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                progressSection
                transportControls

                Spacer()
            }
            .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .sheet(isPresented: $showQueue) {
            QueueView(player: player)
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            Spacer()
            VStack(spacing: 2) {
                Text("NOW PLAYING")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                if let contextTitle = player.queueContextTitle {
                    Text(contextTitle.uppercased())
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal)
    }

    private var titleRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.currentTrack?.title ?? "")
                    .font(.title2.bold())
                    .lineLimit(2)
                Text(player.currentTrack?.artist ?? "")
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if let track = player.currentTrack {
                Button { liked.toggle(track) } label: {
                    Image(systemName: liked.isLiked(track) ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(liked.isLiked(track) ? Theme.accent : .white)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal)
    }

    private var progressSection: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(get: { player.progress }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 1)
            )
            .tint(.white)

            HStack {
                Text(format(player.progress))
                Spacer()
                Text(format(player.duration))
            }
            .font(.caption2)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal)
    }

    private var transportControls: some View {
        HStack {
            Button { player.toggleShuffle() } label: {
                VStack(spacing: 4) {
                    Image(systemName: "shuffle")
                        .font(.title3)
                    Circle()
                        .fill(player.isShuffling ? Theme.accent : .clear)
                        .frame(width: 4, height: 4)
                }
                .foregroundStyle(player.isShuffling ? Theme.accent : .white)
            }
            .frame(width: 44)

            Spacer()

            HStack(spacing: 44) {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.title2)
                }

                Button { player.togglePlayPause() } label: {
                    ZStack {
                        Circle().fill(Color.white).frame(width: 64, height: 64)
                        if player.isLoading {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(.black)
                        }
                    }
                }

                Button { player.advance() } label: {
                    Image(systemName: "forward.fill").font(.title2)
                }
            }

            Spacer()

            Color.clear.frame(width: 44)
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
