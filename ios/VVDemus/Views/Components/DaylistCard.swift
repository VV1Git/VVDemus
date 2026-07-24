import SwiftUI

/// Prominent entry point for the Daylist on Home/Library — a wide card rather than a
/// shelf item, since it's the one flagship "made for you today" mix.
struct DaylistCard: View {
    let title: String
    let imageURL: String?

    var body: some View {
        HStack(spacing: 14) {
            RemoteImage(url: imageURL, size: 64, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text("DAYLIST")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .background(Theme.cardLight)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
