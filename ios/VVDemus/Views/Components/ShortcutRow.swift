import SwiftUI

/// Compact pinned-item row for Home/Library's 2-column shortcut grid — Liked Songs,
/// saved radios, and playlists all render through this.
struct ShortcutRow: View {
    let title: String
    let imageURL: String?
    var systemImageFallback: String = "music.note"

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
        .background(Theme.cardLight)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
