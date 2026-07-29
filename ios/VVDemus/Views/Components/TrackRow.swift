import SwiftUI

struct TrackRow: View {
    let track: Track
    var isActive: Bool = false
    @ObservedObject private var liked = LikedSongsStore.shared
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RemoteImage(url: track.thumbnailUrl, size: 48)
                if isActive {
                    // A green title on its own was easy to miss halfway down a radio.
                    EqualizerBars()
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
                    // Sized to the minimum comfortable target: this sits 12pt from the
                    // download button, and at the icon's intrinsic ~20pt the two were easy
                    // to hit by mistake.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(liked.isLiked(track) ? "Unlike" : "Like")
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
                .accessibilityLabel("Downloading")
        } else if downloads.isDownloaded(track) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
                .accessibilityLabel("Downloaded")
        } else {
            Button {
                downloads.download(track)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Download")
        }
    }
}


/// Three bars that rise and fall while something is playing, and hold still when paused.
///
/// Animated on `isAnimating` rather than on a private `@State` flag. `.animation(_:value:)`
/// only starts a transaction when `value` changes, and that flag went false→true once in
/// `onAppear` and never moved again — so play/pause did nothing to the bars. Depending on
/// when the row happened to be created you got bars frozen at full height while playing, or
/// bars still bouncing after pausing. It was the same stale-transport-state bug as the play
/// button, one component over.
private struct EqualizerBars: View {
    /// Observed here rather than in `TrackRow` so that only the *active* row re-renders on
    /// the twice-a-second progress tick, instead of every visible row in the list.
    @ObservedObject private var player = PlayerService.shared

    var body: some View {
        let isAnimating = player.isPlaying
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.accent)
                    .frame(width: 3, height: 16)
                    .scaleEffect(y: isAnimating ? 1 : 0.375, anchor: .bottom)
                    .animation(
                        isAnimating
                            ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(index) * 0.15)
                            : .default,
                        value: isAnimating
                    )
            }
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }
}
