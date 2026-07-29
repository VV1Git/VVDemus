import SwiftUI

struct MiniPlayerBar: View {
    @ObservedObject var player: PlayerService
    /// Opens the full Now Playing screen — driven by a tap or an upward swipe, the two
    /// ways people already expect a compact player to expand.
    var onExpand: () -> Void = {}
    @ObservedObject private var colorLoader = ArtworkColorLoader.shared

    var body: some View {
        if let track = player.currentTrack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    RemoteImage(url: track.thumbnailUrl, size: 40)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

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
                    // (or reaching for the lock screen) every time.
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
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)

                progressLine
            }
            .background(
                ZStack {
                    colorLoader.color(for: track)
                    Color.black.opacity(0.35)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: track.thumbnailUrl) { await colorLoader.prepare(for: track) }
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .onTapGesture { onExpand() }
            // Sideways to skip, up to expand — the gestures people already expect from a
            // compact player. Whichever axis the drag favours wins, so a diagonal can't
            // both skip and expand.
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let horizontal = value.translation.width
                        let vertical = value.translation.height
                        if abs(horizontal) > abs(vertical) {
                            guard abs(horizontal) > 40 else { return }
                            Haptics.impact()
                            if horizontal < 0 { player.advance() } else { player.previous() }
                        } else if vertical < -30 {
                            Haptics.impact()
                            onExpand()
                        }
                    }
            )
        }
    }

    /// A hairline of progress along the bottom of the bar — enough to tell at a glance how
    /// far into a track you are without opening Now Playing.
    private var progressLine: some View {
        GeometryReader { geometry in
            let fraction = player.duration > 0 ? min(max(player.progress / player.duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}
