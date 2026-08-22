import SwiftUI

/// A release in a list — search results and Library's Albums section.
///
/// Built to `TrackRow`'s geometry (48pt artwork · 12pt gap · title/subtitle) so an album and a
/// song sitting next to each other in the same search list share a leading edge and a
/// separator inset. What sets them apart is the chevron: a song row plays when tapped, an
/// album row navigates, and nothing else about the two says so.
struct AlbumRow: View {
    let album: Album
    /// Off where the list draws its own — a `NavigationLink` inside a `List` supplies the
    /// system disclosure indicator, and a second one beside it reads as a rendering fault.
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            RemoteImage(url: album.thumbnailUrl, size: Theme.ArtSize.row)

            VStack(alignment: .leading, spacing: Theme.Metrics.labelSpacing) {
                Text(album.title)
                    .font(.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(album.subtitle)
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Space.md)

            if showsChevron {
                Image(systemName: "chevron.right")
                    // `.footnote` rather than the row font: this is the weight the system
                    // draws its own disclosure indicators at, and at `.rowTitle` the chevron
                    // competes with the title instead of pointing past it.
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: Theme.ArtSize.row)
        // The trailing `Spacer` draws nothing, so without this the gap between the byline and
        // the chevron is dead to taps — most of the row's width on a short title.
        .contentShape(Rectangle())
    }
}
