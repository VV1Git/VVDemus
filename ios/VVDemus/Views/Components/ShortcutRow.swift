import SwiftUI

/// A tile for **Home's 2-column shortcut grid only** — Liked Songs, saved radios and
/// playlists. Despite the name it is not a list row: stretched to full width it is a
/// quarter of a screen of empty fill with the chevron floating outside it, so Library
/// uses plain native rows instead.
struct ShortcutRow: View {
    let title: String
    let imageURL: String?
    var systemImageFallback: String = "music.note"

    /// The tile's own shape. `Theme.Radius.card`, because this is a filled container, not
    /// artwork.
    ///
    /// The artwork used to bleed into this shape's leading edge with square corners of its
    /// own, letting the tile's clip round it. That only holds while the tile is exactly as
    /// tall as the artwork: a two-line title grows the tile, the image no longer reaches the
    /// top and bottom, and the corner curve then cuts diagonally across the album art. The
    /// artwork is inset inside the curve instead, with corners of its own.
    private var shape: RoundedRectangle { Theme.Radius.rect(Theme.Radius.card) }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            artwork
            Text(title)
                .font(.cardTitle)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.sm)
        // minHeight, not height: a two-line title has to be able to grow the tile at
        // accessibility text sizes instead of clipping.
        .frame(minHeight: Theme.ArtSize.tile + 2 * Theme.Space.sm)
        .background(Theme.card, in: shape)
    }

    @ViewBuilder
    private var artwork: some View {
        if let imageURL {
            RemoteImage(url: imageURL, size: Theme.ArtSize.tile)
        } else {
            ZStack {
                Theme.accent
                Image(systemName: systemImageFallback)
                    // Drawn on the accent fill, so an explicit white is correct here.
                    .foregroundStyle(.white)
            }
            .frame(width: Theme.ArtSize.tile, height: Theme.ArtSize.tile)
            .clipShape(Theme.Radius.rect(Theme.Radius.art(for: Theme.ArtSize.tile)))
        }
    }
}
