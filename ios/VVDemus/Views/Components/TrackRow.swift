import SwiftUI

struct TrackRow: View {
    let track: Track
    var isActive: Bool = false
    @ObservedObject private var liked = LikedSongsStore.shared

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

            Button {
                liked.toggle(track)
            } label: {
                Image(systemName: liked.isLiked(track) ? "heart.fill" : "heart")
                    .foregroundStyle(liked.isLiked(track) ? Theme.accent : Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
