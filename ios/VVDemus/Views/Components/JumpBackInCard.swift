import SwiftUI

/// Big square card with an optional badge (e.g. "RADIO"), used in Home's Your Radio /
/// Your Playlists shelves.
struct JumpBackInCard: View {
    let title: String
    let subtitle: String
    let badge: String?
    let imageURL: String?
    var width: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RemoteImage(url: imageURL, size: width, cornerRadius: 6)
                if let badge {
                    Text(badge.uppercased())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.6))
                        .clipShape(Capsule())
                        .padding(6)
                }
            }
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }
}
