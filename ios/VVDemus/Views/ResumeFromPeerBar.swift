import SwiftUI

/// "Continue from your iPhone — <track> at 1:23, from <station>".
///
/// Deliberately a prompt rather than an automatic takeover. A device that starts playing by
/// itself the moment you wake it — because the other one happened to be paused mid-song — is a
/// worse experience than the one this fixes.
struct ResumeFromPeerBar: View {
    @ObservedObject private var link = PeerLink.shared
    @ObservedObject private var pairedStore = PairedPeerStore.shared

    var body: some View {
        if let offer = link.resumeOffer, let track = offer.currentTrack {
            HStack(spacing: Theme.Space.md) {
                // `mini`, not a literal 40: this is a compact bar like the mini player, and
                // `Theme.Radius.art(for:)` picks a corner radius from the size, so an off-scale
                // value drifts the artwork's roundness away from every other bar as well.
                RemoteImage(url: track.thumbnailUrl, size: Theme.ArtSize.mini)

                VStack(alignment: .leading, spacing: Theme.Metrics.labelSpacing) {
                    // Clamped like the two lines under it. A device name is whatever its owner
                    // typed into Settings and routinely runs long ("MacBook Pro (14-inch, 2023)"),
                    // and this was the one line still free to wrap the bar taller than a row.
                    Text("Continue from \(pairedStore.peer?.name ?? (offer.isDesktop ? "your computer" : "your phone"))")
                        .font(.miniSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(track.title)
                        .font(.miniTitle)
                        .lineLimit(1)
                    Text(subtitle(for: offer))
                        .font(.miniSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Continue") { link.acceptResumeOffer() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)

                Button {
                    link.dismissResumeOffer()
                } label: {
                    // The glyph stays small; the frame is the app's standard 44 so the one
                    // control that makes this bar go away is as easy to hit as every other
                    // icon button. At 28 it was the smallest target on screen.
                    Image(systemName: "xmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: Theme.Metrics.hitTarget, height: Theme.Metrics.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.vertical, Theme.Space.sm)
            .background(.bar)
        }
    }

    /// The position, and what it was playing out of — the station or playlist, not just the
    /// song, since that is the thing you are actually resuming.
    private func subtitle(for offer: NowPlayingCheckpoint) -> String {
        let position = Self.timestamp(offer.progress)
        if let seed = offer.contextSeed {
            return "at \(position) · \(seed.title) Radio"
        }
        if let context = offer.queueContextTitle {
            return "at \(position) · \(context)"
        }
        return "at \(position)"
    }

    private static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
