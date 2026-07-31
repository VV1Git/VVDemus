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

    /// Swipe down anywhere to close. The artwork keeps its own gesture (it also changes
    /// track, and a child gesture wins inside its own bounds), so this only adds the rest of
    /// the screen — dismissing used to require finding the 300pt of artwork or the chevron.
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard value.translation.height > 80,
                      value.translation.height > abs(value.translation.width) else { return }
                Haptics.impact()
                dismiss()
            }
    }

    private var artworkColor: Color { colorLoader.color(for: player.currentTrack) }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [artworkColor, Theme.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            // Keyed on the resolved colour rather than on the track: the colour arrives one
            // frame *after* the track does, so keying on the URL animated the gradient to
            // the fallback and then hard-popped to the real colour.
            .animation(.easeInOut(duration: 0.4), value: artworkColor)
            // Loading is driven from here rather than from inside the gradient's argument:
            // reading a colour is pure, fetching one is not, and this body re-evaluates
            // twice a second while playing.
            .task(id: player.currentTrack?.thumbnailUrl) {
                await colorLoader.prepare(for: player.currentTrack)
            }

            // One flexible gap, above the artwork. With the old pair of Spacers the artwork
            // *and* the whole control panel shifted whenever the title wrapped to two lines
            // or an error appeared; now the panel is pinned to the bottom and only the slack
            // above the artwork changes.
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    header

                    Spacer(minLength: Theme.Space.lg)

                    artwork(fitting: proxy)

                    Spacer(minLength: Theme.Space.lg)

                    // The title block and the panel are two things, not one. At spacing 0 the
                    // artist line sat directly on the glass edge and read as part of the
                    // scrubber.
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        titleRow
                        errorSlot
                        controlPanel
                    }
                }
                // The one gutter for the screen. Nothing inside may add its own horizontal
                // inset — the control panel's is inside its glass, not against the edge.
                .padding(.horizontal, Theme.Metrics.gutter)
                .padding(.vertical, Theme.Space.sm)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .foregroundStyle(.white)
        .gesture(dismissGesture)
        .sheet(isPresented: $showQueue) {
            QueueView(player: player)
        }
    }

    /// Square, and sized to whichever of width or height runs out first — a hardcoded 300pt
    /// nearly touched the edges on an SE and left the controls hanging off the bottom.
    private func artwork(fitting proxy: GeometryProxy) -> some View {
        let side = min(
            proxy.size.width - 2 * Theme.Metrics.gutter,
            proxy.size.height * 0.42,
            Theme.ArtSize.heroMax
        )
        return RemoteImage(
            url: player.currentTrack?.thumbnailUrl,
            size: max(side, 0),
            cornerRadius: Theme.Radius.artHero
        )
        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
        .offset(x: artworkDrag)
        .rotationEffect(.degrees(artworkDrag / 40))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: artworkDrag)
        .gesture(artworkGesture)
    }

    /// Scrubber and transport on one slab of glass, tinted by the artwork behind it.
    ///
    /// Grouped rather than left as two loose rows floating on the gradient: the controls are
    /// one region of the screen and the glass is what says so, and a tinted pane over the
    /// artwork gradient is where the material actually has something to refract.
    private var controlPanel: some View {
        VStack(spacing: Theme.Space.lg) {
            progressSection
            transportControls
        }
        // The panel supplies its own inner inset. The screen gutter is applied once, on the
        // outer stack, and stops at the glass edge.
        .padding(Theme.Space.lg)
        // Untinted. Glass already lightens whatever it sits on, and tinting it with the
        // artwork's average colour on top of that made the panel the brightest thing on the
        // screen — a muddy slab in whatever colour the album happened to average to. The
        // gradient behind it is where the artwork's colour belongs; the controls just need
        // to read as a group.
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.panel))
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: Theme.Metrics.hitTarget, height: Theme.Metrics.hitTarget)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Close")

            Spacer()

            VStack(spacing: Theme.Metrics.labelSpacing) {
                Text("NOW PLAYING")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                if let contextTitle = player.queueContextTitle {
                    Text(contextTitle.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Balances the leading chevron so the title stack stays centered, and carries the
            // actions every list row offers — Now Playing used to offer none of them. The
            // empty slot is only for the moment before a track exists.
            if let track = player.currentTrack {
                NowPlayingActionsMenu(track: track, player: player)
            } else {
                Color.clear
                    .frame(width: Theme.Metrics.hitTarget, height: Theme.Metrics.hitTarget)
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: Theme.Metrics.labelSpacing) {
                Text(player.currentTrack?.title ?? "")
                    .font(.nowPlayingTitle)
                    .lineLimit(2)
                Text(player.currentTrack?.artist ?? "")
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.md)
            if let track = player.currentTrack {
                Button { liked.toggle(track) } label: {
                    Image(systemName: liked.isLiked(track) ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(liked.isLiked(track) ? Theme.accent : .primary)
                        .frame(width: Theme.Metrics.hitTarget, height: Theme.Metrics.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(liked.isLiked(track) ? "Unlike" : "Like")
            }
        }
    }

    /// A fixed slot whether or not there is a message, so one appearing can't shove the
    /// artwork and the controls around mid-playback.
    private var errorSlot: some View {
        Group {
            if let errorMessage = player.errorMessage {
                // Warning, not red: none of these are destructive, they're "this needs you".
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    // Dismissable. Only a track load cleared this, and the two
                    // device-switch failures ("Couldn't hand off…", "Couldn't resume…")
                    // don't load anything — so their message sat under the artwork
                    // indefinitely with no way to get rid of it.
                    .contentShape(Rectangle())
                    .onTapGesture { player.errorMessage = nil }
                    .accessibilityHint("Tap to dismiss")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Space.xxl)
    }

    /// Scrubbing is held locally until the drag ends.
    ///
    /// Binding `value:` straight to `seek(to:)` issued a seek on every touch delta — dozens
    /// a second — while the player's own periodic observer wrote `progress` back from the
    /// pre-seek position in between, so the thumb fought the finger and jumped around.
    private var progressSection: some View {
        VStack(spacing: Theme.Space.xs) {
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
            .tint(Theme.accent)
            .accessibilityLabel("Playback position")
            .accessibilityValue(format(scrubPosition ?? player.progress))

            HStack {
                Text(format(scrubPosition ?? player.progress))
                Spacer()
                Text(format(player.duration))
            }
            // Monospaced digits, or the elapsed time jitters sideways every second.
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 0) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    // The tint alone says "on". The old 4pt dot underneath lifted the glyph
                    // off the optical line of the queue glyph opposite it.
                    .foregroundStyle(player.isShuffling ? Theme.accent : .primary)
                    .frame(width: Theme.Metrics.hitTarget, height: Theme.Metrics.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(player.isShuffling ? "Shuffle on" : "Shuffle off")

            Spacer(minLength: Theme.Space.sm)

            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .frame(width: Theme.Metrics.hitTarget, height: Theme.Metrics.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Previous track")

            Spacer(minLength: Theme.Space.sm)

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
            // The default 0.92 shrink is too much movement on a target this size.
            .buttonStyle(.pressableCard)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Spacer(minLength: Theme.Space.sm)

            Button { player.advance() } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .frame(width: Theme.Metrics.hitTarget, height: Theme.Metrics.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Next track")

            Spacer(minLength: Theme.Space.sm)

            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .frame(width: Theme.Metrics.hitTarget, height: Theme.Metrics.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Queue")
        }
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The long-press menu every track row offers, reachable from the screen where you are
/// most likely to want it.
///
/// Its own view rather than inline: it observes three stores, and NowPlayingView's body
/// re-evaluates twice a second while playing.
private struct NowPlayingActionsMenu: View {
    let track: Track
    @ObservedObject var player: PlayerService
    @ObservedObject private var playlists = PlaylistStore.shared
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""

    var body: some View {
        Menu {
            // `onRadio: nil` — this screen is a full-screen cover presented above every
            // NavigationStack, so there is nowhere to push a radio to.
            TrackMenuItems(
                track: track,
                player: player,
                onRadio: nil,
                showNewPlaylistAlert: $showNewPlaylistAlert
            )
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: Theme.Metrics.hitTarget, height: Theme.Metrics.hitTarget)
        }
        // `.buttonStyle` is only forwarded to a Menu's label once the menu itself is a
        // button, so both are needed to match the close chevron opposite.
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("More")
        .alert("New Playlist", isPresented: $showNewPlaylistAlert) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    let playlist = playlists.create(name: name)
                    playlists.addTrack(track, to: playlist)
                }
                newPlaylistName = ""
            }
        }
    }
}
