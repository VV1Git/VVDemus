import SwiftUI

/// Prominent entry point for the Daylist on Home/Library — a wide card rather than a
/// shelf item, since it's the one flagship "made for you today" mix.
struct DaylistCard: View {
    let title: String
    let imageURL: String?

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            // Inset inside the card's corner curve rather than bled into it. The card is
            // taller than the artwork, so a flush image left the curve cutting across its
            // top-left and bottom-left corners.
            RemoteImage(url: imageURL, size: Theme.ArtSize.daylist, cornerRadius: Theme.Radius.artSmall)

            Text(title)
                .font(.cardTitle)
                .foregroundStyle(.primary)
                // Reserves the second line: the title arrives asynchronously, and a card
                // that gains a line on load shoved the whole page down under the user.
                .lineLimit(2, reservesSpace: true)

            Spacer(minLength: Theme.Space.md)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.md)
        .background(Theme.card, in: Theme.Radius.rect(Theme.Radius.card))
    }
}
