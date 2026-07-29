import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject private var liked = LikedSongsStore.shared
    @ObservedObject private var colorLoader = ArtworkColorLoader.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    /// How far the artwork has been dragged sideways, so it follows the finger before
    /// snapping back — without that the gesture gives no sign it's being recognised.
    @State private var artworkDrag: CGFloat = 0
    /// Where the user's finger is while dragging the scrubber; nil when not scrubbing.
    @State private var scrubPosition: Double?

    /// Swiping the artwork changes track; swiping it down closes the screen. Both are
    /// handled by one gesture that commits to whichever axis the drag actually favours, so
    /// a sloppy diagonal can't trigger two things at once.
    private var artworkGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                // Damped, so the artwork clearly isn't going to be dragged off-screen.
                artworkDrag = value.translation.width / 3
            }
            .onEnded { value in
                artworkDrag = 0
                let horizontal = value.translation.width
                let vertical = value.translation.height
                if abs(horizontal) > abs(vertical) {
                    guard abs(horizontal) > 60 else { return }
                    Haptics.impact()
                    if horizontal < 0 { player.advance() } else { player.previous() }
                } else if vertical > 80 {
                    Haptics.impact()
                    dismiss()
                }
            }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [colorLoader.color(for: player.currentTrack), Theme.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.4), value: player.currentTrack?.thumbnailUrl)
            // Loading is driven from here rather than from inside the gradient's argument:
            // reading a colour is pure, fetching one is not, and this body re-evaluates
            // twice a second while playing.
            .task(id: player.currentTrack?.thumbnailUrl) {
                await colorLoader.prepare(for: player.currentTrack)
            }

            VStack(spacing: 24) {
                header

                Spacer()

                RemoteImage(url: player.currentTrack?.thumbnailUrl, size: 300, cornerRadius: 12)
                    .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
                    .offset(x: artworkDrag)
                    .rotationEffect(.degrees(artworkDrag / 40))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: artworkDrag)
                    .gesture(artworkGesture)

                titleRow

                if let errorMessage = player.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        // Dismissable. Only a track load cleared this, and the two
                        // device-switch failures ("Couldn't hand off…", "Couldn't resume…")
                        // don't load anything — so their message sat under the artwork
                        // indefinitely with no way to get rid of it.
                        .contentShape(Rectangle())
                        .onTapGesture { player.errorMessage = nil }
                        .accessibilityHint("Tap to dismiss")
                }

                progressSection
                transportControls

                Spacer()
            }
            .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .sheet(isPresented: $showQueue) {
            QueueView(player: player)
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            Spacer()
            VStack(spacing: 2) {
                Text("NOW PLAYING")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                if let contextTitle = player.queueContextTitle {
                    Text(contextTitle.uppercased())
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            // Balances the leading chevron so the title stack stays centered —
            // the queue button now lives on the transport row, mirroring shuffle.
            Image(systemName: "chevron.down")
                .font(.title3)
                .opacity(0)
        }
        .padding(.horizontal)
    }

    private var titleRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.currentTrack?.title ?? "")
                    .font(.title2.bold())
                    .lineLimit(2)
                Text(player.currentTrack?.artist ?? "")
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if let track = player.currentTrack {
                Button { liked.toggle(track) } label: {
                    Image(systemName: liked.isLiked(track) ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(liked.isLiked(track) ? Theme.accent : .white)
                }
                .buttonStyle(.pressable)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal)
    }

    /// Scrubbing is held locally until the drag ends.
    ///
    /// Binding `value:` straight to `seek(to:)` issued a seek on every touch delta — dozens
    /// a second — while the player's own periodic observer wrote `progress` back from the
    /// pre-seek position in between, so the thumb fought the finger and jumped around.
    private var progressSection: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrubPosition ?? player.progress },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    guard !editing else { return }
                    if let target = scrubPosition { player.seek(to: target) }
                    scrubPosition = nil
                }
            )
            .tint(.white)
            .accessibilityLabel("Playback position")
            .accessibilityValue(format(scrubPosition ?? player.progress))

            HStack {
                Text(format(scrubPosition ?? player.progress))
                Spacer()
                Text(format(player.duration))
            }
            .font(.caption2)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal)
    }

    private var transportControls: some View {
        HStack {
            Button { player.toggleShuffle() } label: {
                VStack(spacing: 4) {
                    Image(systemName: "shuffle")
                        .font(.title3)
                    Circle()
                        .fill(player.isShuffling ? Theme.accent : .clear)
                        .frame(width: 4, height: 4)
                }
                .foregroundStyle(player.isShuffling ? Theme.accent : .white)
            }
            .frame(width: 44)
            .accessibilityLabel(player.isShuffling ? "Shuffle on" : "Shuffle off")

            Spacer()

            HStack(spacing: 44) {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.title2)
                }
                .accessibilityLabel("Previous track")

                Button { player.togglePlayPause() } label: {
                    ZStack {
                        Circle().fill(Color.white).frame(width: 64, height: 64)
                        if player.isLoading {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(.black)
                        }
                    }
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button { player.advance() } label: {
                    Image(systemName: "forward.fill").font(.title2)
                }
                .accessibilityLabel("Next track")
            }

            Spacer()

            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
            }
            .frame(width: 44)
            .accessibilityLabel("Queue")
        }
        .foregroundStyle(.white)
        .buttonStyle(.pressable)
        .padding(.horizontal, 24)
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
