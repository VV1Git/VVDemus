import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject private var liked = LikedSongsStore.shared
    @ObservedObject private var colorLoader = ArtworkColorLoader.shared
    /// The session on screen, which is this device's own or the paired device's depending on
    /// who owns it. Read for everything shown, never called for anything done — the buttons
    /// below all go to `player`, which relays to the owner itself (`SessionOwning`), so no
    /// control on this screen has to know which device it is driving.
    @ObservedObject private var peer = PeerPlayback.shared
    @ObservedObject private var pairedStore = PairedPeerStore.shared

    /// Whether there is another device to send playback to.
    ///
    /// Decides the shape of the controls, not just their contents: with nothing paired the device
    /// picker draws nothing at all, and a row containing only a right-aligned queue button leaves
    /// a band of dead space the height of a hit target under the volume slider. On the far more
    /// common unpaired phone the queue button belongs back in the transport row, which has the
    /// width for it precisely because the picker is not there to take 44pt of it.
    private var hasPairedDevice: Bool { pairedStore.peer != nil }
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

    private var artworkColor: Color { colorLoader.color(for: peer.displayedTrack) }

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
            .task(id: peer.displayedTrack?.thumbnailUrl) {
                await colorLoader.prepare(for: peer.displayedTrack)
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
            url: peer.displayedTrack?.thumbnailUrl,
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
            volumeSection
            if hasPairedDevice { secondaryControls }
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
                // The screen's own caption carries the device indication rather than a badge
                // of its own: the line already sits above the artwork saying what this screen
                // is, and while the session lives on the paired device that answer is simply
                // longer. Accent when it isn't this device, matching the equalizer bars and
                // the active row — nothing else here says the sound is somewhere else.
                let owner = peer.owningDeviceName
                Text(owner.map { "PLAYING ON \($0.uppercased())" } ?? "NOW PLAYING")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(owner == nil ? Color.secondary : Theme.accent)
                    .lineLimit(1)
                if let contextTitle = peer.displayedContextTitle {
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
            if let track = peer.displayedTrack {
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
                Text(peer.displayedTrack?.title ?? "")
                    .font(.nowPlayingTitle)
                    .lineLimit(2)
                Text(peer.displayedTrack?.artist ?? "")
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.md)
            if let track = peer.displayedTrack {
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
    ///
    /// `minHeight`, not `height`: 32pt is exactly two `.footnote` lines at the default text
    /// size and fewer at every size above it, so the hard cap clipped the second line — and
    /// often the first — for anyone who had turned type up. The slot still reserves its 32pt
    /// when empty, which is all the reservation was ever for.
    private var errorSlot: some View {
        PlaybackErrorBar(player: player)
            .frame(maxWidth: .infinity)
            .frame(minHeight: Theme.Space.xxl)
    }

    /// Scrubbing is held locally until the drag ends.
    ///
    /// Binding `value:` straight to `seek(to:)` issued a seek on every touch delta — dozens
    /// a second — while the player's own periodic observer wrote `progress` back from the
    /// pre-seek position in between, so the thumb fought the finger and jumped around. The
    /// same latch does double duty for the mirror, where the position arriving once a second
    /// from the owner would otherwise drag the thumb backwards mid-drag.
    private var progressSection: some View {
        VStack(spacing: Theme.Space.xs) {
            Slider(
                value: Binding(
                    get: {
                        if let scrubPosition { return scrubPosition }
                        // Clamped into the range the Slider was actually given. Before a
                        // duration is known the range collapses to 0...1 while `progress` is
                        // whatever the last track left behind, and a value outside its own
                        // bounds draws the thumb pinned off the end of the track.
                        let duration = peer.displayedDuration
                        return duration > 0 ? min(max(peer.displayedProgress, 0), duration) : 0
                    },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(peer.displayedDuration, 1),
                onEditingChanged: { editing in
                    guard !editing else { return }
                    if let target = scrubPosition { player.seek(to: target) }
                    scrubPosition = nil
                }
            )
            .tint(Theme.accent)
            // There is nothing to seek within until a duration arrives; dragging then only
            // issued a seek in seconds-of-one into a track that hadn't loaded. Matches
            // `MacNowPlayingBar`, which has always clamped and disabled.
            .disabled(peer.displayedDuration <= 0)
            .accessibilityLabel("Playback position")
            .accessibilityValue(format(scrubPosition ?? peer.displayedProgress))

            HStack {
                Text(format(scrubPosition ?? peer.displayedProgress))
                Spacer()
                Text(format(peer.displayedDuration))
            }
            // Monospaced digits, or the elapsed time jitters sideways every second.
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    /// Volume for whatever device is playing, flanked by the two speaker glyphs that say
    /// which way is quieter.
    ///
    /// Inside the same glass as the scrubber and the transport rather than loose on the
    /// gradient: it is one more thing you do to the sound coming out right now, and the
    /// panel is what groups those. Deliberately smaller and dimmer than the scrubber — this
    /// is a trim, not the control the screen is about.
    private var volumeSection: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "speaker.fill")
            Slider(
                value: Binding(get: { peer.displayedVolume }, set: { player.setVolume($0) }),
                in: 0...1
            )
            .tint(Theme.accent)
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int((peer.displayedVolume * 100).rounded())) percent")
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var transportControls: some View {
        HStack(spacing: 0) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    // The tint alone says "on". The old 4pt dot underneath lifted the glyph
                    // off the optical line of the queue glyph opposite it.
                    .foregroundStyle(peer.displayedIsShuffling ? Theme.accent : .primary)
                    .frame(width: Theme.Metrics.hitTarget, height: Theme.Metrics.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(peer.displayedIsShuffling ? "Shuffle on" : "Shuffle off")

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
                    if peer.displayedIsLoading {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: peer.displayedIsPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.black)
                    }
                }
            }
            // The default 0.92 shrink is too much movement on a target this size.
            .buttonStyle(.pressableCard)
            .accessibilityLabel(peer.displayedIsPlaying ? "Pause" : "Play")

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

            // Always the fifth control, whether or not a device is paired. It is what balances
            // shuffle on the other side of the play button — with four controls the white circle
            // sits 45pt right of the centreline the artwork, the scrubber and the panel all
            // share, and it is the largest, brightest thing on the screen, so the whole layout
            // reads as crooked. Five controls also still fit: 240pt plus four 8pt gaps against
            // the ~311pt a 375pt phone offers inside the gutter and the panel's inset.
            queueButton
        }
    }

    private var queueButton: some View {
        Button { showQueue = true } label: {
            Image(systemName: "list.bullet")
                .font(.title3)
                .frame(width: Theme.Metrics.hitTarget, height: Theme.Metrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Queue")
    }

    /// The device picker, on its own line under the transport — bottom-left, where Spotify puts
    /// it.
    ///
    /// It used to sit in the transport row and does not fit there: every control in that row is an
    /// exact fixed frame, nothing can compress, and six of them came to 284pt plus spacers against
    /// the ~311pt a 375pt phone offers inside the gutter and the panel's inset. It overran the
    /// glass on an SE and a 13 mini, taking the queue button off the edge with it.
    ///
    /// Only the picker moved down, though. Taking the queue button with it left the transport row
    /// with four controls and no counterweight to shuffle, which pushed the white play circle
    /// 45pt off the centreline everything else on the screen shares; and with nothing paired the
    /// picker draws nothing at all, so the row became 294×44pt of blank glass with one button
    /// stranded in the corner. A row that holds one thing, and hides itself when it has nothing
    /// to hold, avoids both.
    private var secondaryControls: some View {
        HStack(spacing: Theme.Space.sm) {
            DevicePicker(opensUpward: true)

            Spacer(minLength: 0)
        }
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Playback's one visible failure surface: a stream that wouldn't resolve, a handoff the
/// other device refused.
///
/// A view of its own rather than a computed property on `NowPlayingView`, because
/// `NowPlayingView` is only ever presented from `RootView` — and project.yml leaves `RootView`
/// out of the Mac target. That made `player.errorMessage` unreachable on the Mac: a stream that
/// failed there set the message and nothing anywhere drew it, so the music simply stopped with
/// no explanation. This is the piece a Mac now-playing surface can mount to fix that.
///
/// Draws nothing at all when there is no message — reserving room for one is the caller's
/// decision, and only the full-screen player needs it.
struct PlaybackErrorBar: View {
    @ObservedObject var player: PlayerService

    var body: some View {
        if let errorMessage = player.errorMessage {
            // Warning, not red: none of these are destructive, they're "this needs you".
            Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(Theme.warning)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                // Dismissable. Only a track load cleared this, and the two device-switch
                // failures ("Couldn't hand off…", "Couldn't resume…") don't load anything —
                // so their message sat under the artwork indefinitely with no way to get rid
                // of it.
                .contentShape(Rectangle())
                .onTapGesture { player.errorMessage = nil }
                .accessibilityHint("Tap to dismiss")
        }
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
