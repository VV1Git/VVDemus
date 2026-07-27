import SwiftUI

struct TrackRow: View {
    let track: Track
    var isActive: Bool = false
    @ObservedObject private var liked = LikedSongsStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    /// Observed directly rather than passed in, so every existing call site keeps working.
    @ObservedObject private var player = PlayerService.shared

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RemoteImage(url: track.thumbnailUrl, size: 48)
                if isActive {
                    // A green title on its own was easy to miss halfway down a radio.
                    EqualizerBars(isAnimating: player.isPlaying)
                        .frame(width: 48, height: 48)
                        .background(Color.black.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isActive ? Theme.accent : .white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            downloadIndicator

            Button {
                liked.toggle(track)
            } label: {
                Image(systemName: liked.isLiked(track) ? "heart.fill" : "heart")
                    .foregroundStyle(liked.isLiked(track) ? Theme.accent : Theme.textSecondary)
            }
            .buttonStyle(.pressable)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var downloadIndicator: some View {
        if let value = downloads.progress[track.id] {
            ProgressView(value: value)
                .progressViewStyle(.circular)
                .frame(width: 16, height: 16)
        } else if downloads.isDownloaded(track) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
        } else {
            Button {
                downloads.download(track)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.pressable)
        }
    }
}


/// Three bars that rise and fall while something is playing, and hold still when paused.
private struct EqualizerBars: View {
    let isAnimating: Bool
    @State private var raised = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.accent)
                    .frame(width: 3, height: raised ? 16 : 6)
                    .animation(
                        isAnimating
                            ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(index) * 0.15)
                            : .default,
                        value: raised
                    )
            }
        }
        .frame(height: 18)
        .onAppear { raised = true }
    }
}
