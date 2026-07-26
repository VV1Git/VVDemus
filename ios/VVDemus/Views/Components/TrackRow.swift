import SwiftUI

struct TrackRow: View {
    let track: Track
    var isActive: Bool = false
    @ObservedObject private var liked = LikedSongsStore.shared
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: track.thumbnailUrl, size: 48)

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
