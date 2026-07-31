import SwiftUI

/// The one song row for every screen.
///
/// It deliberately applies **no** horizontal or vertical padding of its own: the row's insets
/// come from `trackRowMetrics()` on the call site, so the artwork, the separator and the
/// screen gutter can never drift apart between screens.
struct TrackRow: View {
    let track: Track
    var isActive: Bool = false
    /// Downloads screen passes `false`: an entire section of inert green checkmarks restates
    /// the screen's own title and eats trailing width.
    var showsDownloadControl: Bool = true
    /// When set, artwork + labels become a real `Button` so the row gets press feedback and a
    /// VoiceOver button trait. Only that region is wrapped — the download and like controls
    /// stay siblings, because a Button nested inside another Button's label is un-hittable.
    var onTap: (() -> Void)? = nil

    @ObservedObject private var liked = LikedSongsStore.shared

    var body: some View {
        HStack(spacing: 0) {
            if let onTap {
                Button(action: onTap) { tappableContent }
                    .buttonStyle(.pressableRow)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
            } else {
                // Un-migrated call sites still hang their own `.onTapGesture` on the row.
                tappableContent
            }

            trailingControls
        }
    }

    private var tappableContent: some View {
        HStack(spacing: Theme.Space.md) {
            ZStack {
                RemoteImage(url: track.thumbnailUrl, size: Theme.ArtSize.row)
                if isActive {
                    // A green title on its own was easy to miss halfway down a radio.
                    EqualizerBars()
                        .frame(width: Theme.ArtSize.row, height: Theme.ArtSize.row)
                        .background(Color.black.opacity(0.55))
                        // Derived from the artwork size so the scrim can never desync from
                        // `RemoteImage`'s own corner radius.
                        .clipShape(Theme.Radius.rect(Theme.Radius.art(for: Theme.ArtSize.row)))
                }
            }

            VStack(alignment: .leading, spacing: Theme.Metrics.labelSpacing) {
                Text(track.title)
                    .font(.rowTitle)
                    .foregroundStyle(isActive ? Theme.accent : .primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Space.md)
        }
        // Declared here rather than on each branch: a `Button`'s hit region comes from its
        // label's content shape, and the trailing `Spacer` draws nothing — without this the
        // gap between the artist line and the download ring is dead to taps, which is most
        // of the row's width on a short title.
        .contentShape(Rectangle())
    }

    /// Tight cluster: the controls carry their own 44pt-tall hit areas, so any spacing between
    /// them would only widen the row without making them easier to hit.
    private var trailingControls: some View {
        HStack(spacing: 0) {
            if showsDownloadControl {
                // Observes `DownloadManager` itself, so a progress publish re-renders one small
                // button instead of every artwork, label and heart in the list. Its identity is
                // pinned to the track because `List` recycles cells: without this a reused row
                // animates its ring from the previous track's fraction to the new one's.
                DownloadButton(track: track)
                    .id(track.videoId)
            }

            Button {
                liked.toggle(track)
            } label: {
                Image(systemName: liked.isLiked(track) ? "heart.fill" : "heart")
                    .foregroundStyle(liked.isLiked(track) ? Theme.accent : .secondary)
                    // Full-height hit area, narrow visual width: spending 44pt of row width to
                    // draw a 20pt glyph is what starved the title column.
                    .frame(width: Theme.Metrics.trailingControl, height: Theme.Metrics.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(liked.isLiked(track) ? "Unlike" : "Like")
        }
    }
}


extension View {
    /// The list metrics every track row shares: one 16pt gutter, a 6pt vertical inset (48pt
    /// artwork → 60pt row) and a separator that starts at the title's leading edge. The guide
    /// is measured inside the row, i.e. after `listRowInsets`.
    func trackRowMetrics() -> some View {
        self.listRowInsets(Theme.Metrics.rowInsets)
            .alignmentGuide(.listRowSeparatorLeading) { _ in Theme.Metrics.separatorLeading }
    }
}


/// Three bars that rise and fall while something is playing, and hold still when paused.
/// The now-playing indicator for both list rows (default scale) and shelf cards
/// (`TrackCard` passes a larger `scale`) — one animation contract, one place to change it.
///
/// Animated on `isAnimating` rather than on a private `@State` flag. `.animation(_:value:)`
/// only starts a transaction when `value` changes, and that flag went false→true once in
/// `onAppear` and never moved again — so play/pause did nothing to the bars. Depending on
/// when the row happened to be created you got bars frozen at full height while playing, or
/// bars still bouncing after pausing. It was the same stale-transport-state bug as the play
/// button, one component over.
struct EqualizerBars: View {
    /// Multiplies every dimension. 1 is the 48pt-row size.
    var scale: CGFloat = 1
    /// Observed here rather than in the host row/card so that only the *active* one
    /// re-renders on the twice-a-second progress tick, instead of every visible cell.
    @ObservedObject private var player = PlayerService.shared

    var body: some View {
        let isAnimating = player.isPlaying
        HStack(alignment: .bottom, spacing: 2 * scale) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1 * scale)
                    .fill(Theme.accent)
                    .frame(width: 3 * scale, height: 16 * scale)
                    .scaleEffect(y: isAnimating ? 1 : 0.375, anchor: .bottom)
                    .animation(
                        isAnimating
                            ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(index) * 0.15)
                            : .default,
                        value: isAnimating
                    )
            }
        }
        .frame(height: 18 * scale)
        .accessibilityHidden(true)
    }
}
