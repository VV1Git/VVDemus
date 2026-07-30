import SwiftUI

/// Compact pinned-item row for Home/Library's 2-column shortcut grid — Liked Songs,
/// saved radios, and playlists all render through this.
struct ShortcutRow: View {
    let title: String
    let imageURL: String?
    var systemImageFallback: String = "music.note"

    /// Wider than the 4pt this used to use. A tight radius reads as a square-cornered tile
    /// whatever is behind it; glass needs enough curve for the rim highlight to travel
    /// around.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 0) {
            if let imageURL {
                RemoteImage(url: imageURL, size: 56, cornerRadius: 4)
            } else {
                ZStack {
                    Theme.accent
                    Image(systemName: systemImageFallback)
                        .foregroundStyle(.white)
                }
                .frame(width: 56, height: 56)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(.horizontal, 10)
            Spacer(minLength: 0)
        }
        .frame(height: 56)
        // Clipped before the glass goes behind it: the artwork runs right into the leading
        // edge, so it has to take the corner radius with it.
        .clipShape(shape)
        .glassEffect(in: shape)
    }
}
