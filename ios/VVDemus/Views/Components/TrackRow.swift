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
    /// The queue's now-playing row passes `false`. It carries a play/pause button of its own, so
    /// with the heart still drawn it had two trailing controls in the opposite order to every row
    /// beneath it — and the like affordance visibly zig-zagged down the trailing edge of the
    /// list. Like stays reachable there as a swipe and a long press, as on every other row.
    var showsLikeControl: Bool = true
    /// When set, artwork + labels become a real `Button` so the row gets press feedback and a
    /// VoiceOver button trait. Only that region is wrapped — the download and like controls
    /// stay siblings, because a Button nested inside another Button's label is un-hittable.
    var onTap: (() -> Void)? = nil

    @ObservedObject private var liked = LikedSongsStore.shared
    @ObservedObject private var peer = PeerPlayback.shared
    @State private var isHovering = false

    /// Highlighted when *either* device is playing this track.
    ///
    /// Call sites pass `isActive` from the local player, which is the right answer on whichever
    /// device owns the session — but the other one is mirroring, its own `currentTrack` is nil,
    /// and the row a radio is currently playing would show as inert there. The session on screen
    /// is the thing to highlight, wherever it happens to live.
    private var isCurrent: Bool {
        isActive || peer.displayedTrack?.videoId == track.videoId
    }

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
        // Pointer feedback, applied here so every screen that shows a song gets it at once.
        //
        // A touch UI moved across unchanged reads as inert on a Mac: nothing acknowledges the
        // pointer, so nothing looks clickable.
        //
        // macOS only, and deliberately. `.onHover` is not a no-op on iOS — an iPad with a
        // trackpad, a mouse, or a hovering Apple Pencil delivers hover events — so left unguarded
        // every song row on iPad grows a highlight plate that belongs to a pointer the design
        // never assumed. `HomeView`'s `cardHover()` settled this already by compiling to nothing
        // off the Mac; this follows it.
        #if os(macOS)
        .background(
            // Corners taken from the row's artwork, so the plate can never sit at a different
            // roundness than the thing at its leading edge — and so it is `.continuous` like
            // every other shape in the app.
            Theme.Radius.rect(Theme.Radius.art(for: Theme.ArtSize.row))
                .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
        )
        .onHover { isHovering = $0 }
        #endif
    }

    private var tappableContent: some View {
        HStack(spacing: Theme.Space.md) {
            ZStack {
                RemoteImage(url: track.thumbnailUrl, size: Theme.ArtSize.row)
                if isCurrent {
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
                    .foregroundStyle(isCurrent ? Theme.accent : .primary)
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

            if showsLikeControl {
                Button {
                    liked.toggle(track)
                } label: {
                    Image(systemName: liked.isLiked(track) ? "heart.fill" : "heart")
                        .font(.trailingGlyph)
                        .foregroundStyle(liked.isLiked(track) ? Theme.accent : .secondary)
                        // Full-height hit area, narrow visual width: spending 44pt of row width
                        // to draw a 20pt glyph is what starved the title column.
                        .frame(width: Theme.Metrics.trailingControl, height: Theme.Metrics.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(liked.isLiked(track) ? "Unlike" : "Like")
            }
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
    /// Observed here rather than in the host row/card so that only the *active* indicator
    /// re-renders on the twice-a-second progress tick, instead of every visible cell.
    ///
    /// `PlayerService` stays observed even though the body no longer reads it: `displayedIsPlaying`
    /// resolves to this device's own player when it owns the session, and a computed read
    /// subscribes to nothing — without this, local play/pause would not reach the bars.
    @ObservedObject private var player = PlayerService.shared
    @ObservedObject private var peer = PeerPlayback.shared

    var body: some View {
        // Driven by the same session the row used to decide it is the current one. Against
        // `player.isPlaying` the mirroring device drew bars over the right track and then never
        // moved them — its own player is empty, so they read as frozen rather than as playing.
        let isAnimating = peer.displayedIsPlaying
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
