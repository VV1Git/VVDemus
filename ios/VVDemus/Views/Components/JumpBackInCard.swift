import SwiftUI

/// Big square card used in Home's Your Radio / Your Playlists shelves.
struct JumpBackInCard: View {
    let title: String
    let subtitle: String
    // No `badge`: the card used to print the collection kind twice ("Radio" as an overlay
    // capsule *and* as the subtitle). The subtitle is the one that survives.
    let imageURL: String?
    var width: CGFloat = Theme.ArtSize.shelfCard

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            RemoteImage(url: imageURL, size: width, cornerRadius: Theme.Radius.artMedium)
            Text(title)
                .font(.cardTitle)
                .foregroundStyle(.primary)
                // Reserved so every subtitle in a shelf shares one baseline, whatever the
                // titles around it do.
                .lineLimit(2, reservesSpace: true)
            Text(subtitle)
                .font(.cardSubtitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }
}
