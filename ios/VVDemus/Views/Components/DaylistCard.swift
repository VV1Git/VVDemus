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
                // Two lines when it needs them, but the second is no longer *reserved*. It was,
                // because the title arrives asynchronously and a card that gains a line on load
                // shoved the page down under the user — but the card's height is already pinned
                // by the 64pt artwork and its padding, which two lines of this font cannot
                // exceed, so nothing moved anyway. What the reserved line did do was leave an
                // empty second row under every one-line title, lifting it ~9pt above the centre
                // the artwork and the chevron beside it both sit on.
                .lineLimit(2)

            Spacer(minLength: Theme.Space.md)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.md)
        .background(Theme.card, in: Theme.Radius.rect(Theme.Radius.card))
    }
}
