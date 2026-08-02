import SwiftUI

struct MiniPlayerBar: View {
    @ObservedObject var player: PlayerService
    /// Opens the full Now Playing screen — driven by a tap or an upward swipe, the two
    /// ways people already expect a compact player to expand.
    var onExpand: () -> Void = {}
    @ObservedObject private var colorLoader = ArtworkColorLoader.shared

    /// `.expanded` when the accessory sits as its own row above the tab bar, `.inline` once
    /// the bar minimises on scroll and the two merge into a single pill. The inline form has
    /// room for artwork, a title and one control — no more.
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool { placement == .inline }

    /// The accessory's glass is a capsule, so each end is a semicircle of radius height/2 —
    /// 44pt of controls, 6pt above and below, plus the 2pt hairline, so R = 29. The artwork's
    /// clearance from that arc peaks where its own 6pt corner arc shares the capsule arc's
    /// centre line, at R - 6 = 23, rounded up to `Space.xl` to stay on the theme's 4pt scale.
    /// At the old 16 the corner cleared by 6.4pt against a 16pt gap at the bar's mid-height,
    /// and that mismatch is what read as the art being shoved into the nose of the pill.
    ///
    /// Inline is left alone: it drops the vertical padding and the hairline, so the block is
    /// 44pt tall, R = 22, and the same rule gives 22 - 6 = 16 — what the gutter already is.
    private var leadingInset: CGFloat { isInline ? Theme.Metrics.gutter : Theme.Space.xl }

    /// The trailing side wants the opposite. `forward.fill` is a ~19pt glyph centred in a 44pt
    /// frame, so it already carries ~13pt of optical inset; another 16 put its visual edge at
    /// 29 against the artwork's 16 and tipped the whole row left.
    ///
    /// Inline keeps the gutter on both sides rather than applying that reasoning again: the
    /// merged pill is the system's own tab-bar shape, it is much narrower, and its one control
    /// is all that stands between the title and the end — trimming there costs legibility
    /// without a capsule nose to clear.
    private var trailingInset: CGFloat { isInline ? Theme.Metrics.gutter : Theme.Space.md }

    var body: some View {
        if let track = player.currentTrack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    // A real Button, not just the bar's tap gesture: VoiceOver and Switch
                    // Control had no way at all to open Now Playing. It wraps only the
                    // artwork and labels — nesting the transport buttons inside a Button's
                    // label would make them un-hittable.
                    Button {
                        onExpand()
                    } label: {
                        HStack(spacing: 12) {
                            RemoteImage(url: track.thumbnailUrl, size: 40)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title)
                                    .font(.miniTitle)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                // The inline pill has room for exactly one line.
                                if !isInline {
                                    Text(track.artist)
                                        .font(.miniSubtitle)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            // Takes the slack itself instead of a trailing Spacer, so the
                            // title gets the width rather than leaving it blank.
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressableRow)
                    .accessibilityHint("Opens Now Playing")

                    // The button keeps its slot while loading rather than being swapped
                    // for a bare spinner: the spinner's intrinsic width differs from the
                    // button's, so the whole bar reflowed on every track change, and a tap
                    // during that window fell through to the bar's own tap gesture and
                    // threw the user into the full-screen player.
                    Button {
                        player.togglePlayPause()
                    } label: {
                        ZStack {
                            if player.isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .disabled(player.isLoading)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                    // Skipping is the single most common thing to want from the mini
                    // player, and previously meant opening the full Now Playing screen
                    // (or reaching for the lock screen) every time. First to go when the
                    // bar minimises — play/pause outranks it for the last remaining slot.
                    if !isInline {
                        Button {
                            player.advance()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.subheadline)
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel("Next track")
                    }
                }
                // See `leadingInset` / `trailingInset` for why these differ.
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.vertical, isInline ? 0 : Theme.Metrics.rowVertical)

                // The hairline needs a row of its own, which only the expanded placement has.
                if !isInline {
                    progressLine
                }
            }
            // Deliberately no background and no clip. The accessory is handed to the system
            // already sitting on its own glass, in a shape the system decides and animates
            // between placements — anything drawn here stacks a second slab inside the first.
            .task(id: track.thumbnailUrl) { await colorLoader.prepare(for: track) }
            .contentShape(Rectangle())
            .onTapGesture { onExpand() }
            // Horizontal only. The old gesture also took an upward drag to expand, which is
            // the same drag the system uses to raise the accessory — two handlers fighting
            // over one gesture. Tap still expands.
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let horizontal = value.translation.width
                        guard abs(horizontal) > abs(value.translation.height),
                              abs(horizontal) > 40 else { return }
                        Haptics.impact()
                        if horizontal < 0 { player.advance() } else { player.previous() }
                    }
            )
        }
    }

    /// A hairline of progress along the bottom of the bar — enough to tell at a glance how
    /// far into a track you are without opening Now Playing.
    ///
    /// Inset to the same pair as the row above and clipped to a capsule: as a full-width
    /// sibling of the padded row it ran edge-to-edge under inset content, and the system's own
    /// capsule clip on the accessory sliced its square ends off. Sharing the row's insets
    /// rather than the plain gutter is what keeps its ends under the artwork and the last
    /// control instead of 8pt adrift of them. Accent, to match the Now Playing scrubber.
    private var progressLine: some View {
        GeometryReader { geometry in
            let fraction = player.duration > 0 ? min(max(player.progress / player.duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 2)
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .accessibilityHidden(true)
    }
}
