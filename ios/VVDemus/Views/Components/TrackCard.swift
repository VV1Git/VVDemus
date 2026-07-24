import SwiftUI

struct TrackCard: View {
    let track: Track
    var isActive: Bool = false
    var width: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: track.thumbnailUrl, size: width, cornerRadius: 6)
            Text(track.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isActive ? Theme.accent : .white)
                .lineLimit(1)
            Text(track.artist)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }
}
