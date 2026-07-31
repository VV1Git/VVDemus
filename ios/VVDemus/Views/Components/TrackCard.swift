import SwiftUI

/// Square song card for Home's horizontal shelves.
struct TrackCard: View {
    let track: Track
    var isActive: Bool = false
    var width: CGFloat = Theme.ArtSize.shelfCard

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ZStack {
                RemoteImage(url: track.thumbnailUrl, size: width, cornerRadius: Theme.Radius.artMedium)
                if isActive {
                    // Same treatment as the list row: a green 12pt title was the only
                    // now-playing signal on a 150pt card, and it was easy to miss.
                    EqualizerBars(scale: 1.7)
                        .frame(width: width, height: width)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Theme.Radius.rect(Theme.Radius.artMedium))
                }
            }
            Text(track.title)
                .font(.cardTitle)
                .foregroundStyle(isActive ? Theme.accent : .primary)
                // Reserved so every subtitle in a shelf shares one baseline, whatever the
                // titles around it do.
                .lineLimit(2, reservesSpace: true)
            Text(track.artist)
                .font(.cardSubtitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }
}
