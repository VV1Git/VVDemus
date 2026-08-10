import SwiftUI

/// The Mac's transport bar.
///
/// Everything lives here — shuffle, transport, scrubber, the device switch, the queue toggle and
/// volume — because there is no full-screen player on the desktop to hide any of it behind. That
/// modal used to exist and was the wrong shape for a window: a Mac has the width to keep the
/// controls permanently visible, which is what Spotify's own desktop bar does.
///
/// It shows whichever session is on screen — this device's, or the paired device's when that is
/// the one playing — and its buttons act on that one. See `PeerPlayback`.
struct MacNowPlayingBar: View {
    @ObservedObject var player: PlayerService
    @ObservedObject private var peer = PeerPlayback.shared
    @ObservedObject private var liked = LikedSongsStore.shared
    /// Not `@ObservedObject`. This bar only ever *warms* the cache — unlike `NowPlayingView` it
    /// never reads a colour back out — and now that it is mounted for the life of the window, an
    /// observation here would re-render the whole transport every time any other screen resolved
    /// an artwork colour, at whatever rate a list is being scrolled.
    private let colorLoader = ArtworkColorLoader.shared

    @Binding var showQueue: Bool

    /// Where the thumb is being dragged to, while it is being dragged.
    ///
    /// The binding used to write straight through to `seek(to:)`, which is the bug
    /// `NowPlayingView.progressSection` documents and solved the same way: a drag emits dozens of
    /// deltas a second, each one a seek, while the player's own periodic observer writes
    /// `progress` back from the pre-seek position in between — so the thumb fights the finger.
    /// A pointer drag emits more deltas than a finger does, and while the paired device owns the
    /// session every one of them is a network command, since `PlayerService.seek` relays and
    /// nothing throttles it. One seek, when the drag ends.
    @State private var scrubPosition: Double?

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.Space.md) {
                // Flexible rather than the fixed 260 this started as. At the narrowest
                // window the shell allows (900pt, less the sidebar) that 260 plus the two
                // rigid clusters already came to more than the bar had, so the scrubber —
                // the block that is meant to absorb the slack — was proposed nothing and
                // the trailing controls clipped off the edge. It still reaches 260 as soon
                // as there is room, because nothing here has a layout priority: the two
                // flexible blocks share the surplus and this one stops taking at its max.
                leading
                    .frame(minWidth: 140, idealWidth: 260, maxWidth: 260, alignment: .leading)

                // Inert rather than absent while there is nothing to drive, for the reason
                // `DevicePicker` is disabled rather than removed mid-handoff: a control that
                // comes and goes reads as broken.
                transport
                    .disabled(peer.displayedTrack == nil)

                // The floor is what keeps the slider draggable once every other block has
                // taken its minimum — the timestamps alone are ~70pt of it.
                scrubber
                    .frame(minWidth: 150, maxWidth: .infinity)

                trailingControls
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.vertical, Theme.Space.sm)
        }
        .background(.bar)
    }

    // MARK: - Pieces

    /// One layout for both states, so the bar itself never leaves the window.
    ///
    /// The body used to be `if let track = peer.displayedTrack` with no `else`, so a Mac that
    /// had not started anything yet had no transport at all and the window's bottom edge was
    /// whatever screen you happened to be browsing. A playlist, a radio and Search are the
    /// screens you are on *before* you have played anything, which is exactly why it read as
    /// those three losing the bar — nothing about navigating ever removed it.
    ///
    /// "Nothing to show" also covers a state the user did not cause. While this Mac mirrors the
    /// phone its own `PlayerService` is deliberately empty (`PeerPlayback.enforceOwnership`
    /// releases it), so one failed poll clears `isPeerReachable`, `recomputeMirroring` clears
    /// `isMirroring`, and `displayedTrack` falls straight through to that nil — taking the whole
    /// bar, and with it `DevicePicker`, off screen for the length of the backoff, 5 seconds
    /// doubling to 30. That picker is the only way to get the session back.
    ///
    /// Only this block changes between the two states, so the bar's height is a constant and
    /// nothing below the pointer moves when playback starts or stops.
    @ViewBuilder
    private var leading: some View {
        if let track = peer.displayedTrack {
            nowPlaying(track)
                .task(id: track.thumbnailUrl) { await colorLoader.prepare(for: track) }
        } else {
            resting
        }
    }

    /// `RemoteImage` with no URL rather than a hand-built placeholder rectangle: it already
    /// draws the app's empty artwork — `Theme.card` behind a scaled `music.note`, clipped to the
    /// radius `Theme.Radius.art(for:)` picks for the size — so the resting bar cannot drift away
    /// from the playing one it stands in for.
    private var resting: some View {
        HStack(spacing: Theme.Space.md) {
            RemoteImage(url: nil, size: Theme.ArtSize.mini)
            Text("Nothing playing")
                .font(.miniTitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func nowPlaying(_ track: Track) -> some View {
        HStack(spacing: Theme.Space.md) {
            RemoteImage(url: track.thumbnailUrl, size: Theme.ArtSize.mini)
            VStack(alignment: .leading, spacing: Theme.Metrics.labelSpacing) {
                Text(track.title).font(.miniTitle).lineLimit(1)
                Text(track.artist).font(.miniSubtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Liking is a local library action, so it always applies here even while mirroring
            // the other device's playback — the libraries merge either way.
            HoverButton(
                systemImage: liked.isLiked(track) ? "heart.fill" : "heart",
                label: liked.isLiked(track) ? "Remove from Liked Songs" : "Add to Liked Songs",
                tint: liked.isLiked(track) ? Theme.accent : nil
            ) {
                liked.toggle(track)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: Theme.Space.xs) {
            HoverButton(
                systemImage: "shuffle",
                label: peer.displayedIsShuffling ? "Turn off shuffle" : "Shuffle",
                tint: peer.displayedIsShuffling ? Theme.accent : nil
            ) {
                player.toggleShuffle()
            }

            HoverButton(systemImage: "backward.fill", label: "Previous track") { player.previous() }

            // Keeps its slot while loading rather than being swapped for a bare spinner: the
            // spinner's intrinsic width differs, so the whole bar reflowed on every track change.
            Button { player.togglePlayPause() } label: {
                ZStack {
                    if peer.displayedIsLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: peer.displayedIsPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                }
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(peer.displayedIsPlaying ? "Pause" : "Play")

            HoverButton(systemImage: "forward.fill", label: "Next track") { player.advance() }
        }
    }

    private var scrubber: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(Self.timestamp(peer.displayedProgress))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: {
                        if let scrubPosition { return scrubPosition }
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
            // Widened from `displayedDuration <= 0` alone now that the slider is on screen with
            // no session behind it. The two agree today — `releaseSession()` zeroes the duration
            // — but that is an inference from a number someone may later stop resetting, and a
            // `Slider` over `0...1` moves under the pointer while changing nothing.
            .disabled(peer.displayedTrack == nil || peer.displayedDuration <= 0)

            Text(Self.timestamp(peer.displayedDuration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        // `.combine` builds a label out of the two timestamps and `.accessibilityLabel`
        // then REPLACES it, so both times were lost — the element announced "Playback
        // position" and no position. The value is where they belong anyway.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playback position")
        .accessibilityValue(
            "\(Self.timestamp(peer.displayedProgress)) of \(Self.timestamp(peer.displayedDuration))"
        )
    }

    private var trailingControls: some View {
        HStack(spacing: Theme.Space.xs) {
            // The bar sits at the bottom of the window, so the menu opens upward.
            DevicePicker(opensUpward: true)

            HoverButton(
                systemImage: "list.bullet",
                label: showQueue ? "Hide queue" : "Show queue",
                tint: showQueue ? Theme.accent : nil
            ) {
                withAnimation(.easeInOut(duration: 0.18)) { showQueue.toggle() }
            }

            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { peer.displayedVolume }, set: { player.setVolume($0) }),
                    in: 0...1
                )
                .tint(.secondary)
                // Gives way before the scrubber does: a trim is worth less of a narrow window
                // than the control you actually drag, and 90pt of it is comfort, not a floor.
                .frame(minWidth: 56, idealWidth: 90, maxWidth: 90)
            }
            // Same replaced-label problem as the scrubber: combining swallowed the slider's
            // own value, and the label then overwrote what combining had produced.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int((peer.displayedVolume * 100).rounded())) percent")
        }
    }

    private static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// `DevicePicker` (in VVDemus/Views) is the device control for both platforms. It replaced both an
// earlier picker that moved only the audio output — leaving the queue behind, so the two devices
// could be in four states rather than two — and the one-way handoff button that briefly replaced
// it. Moving the whole session is the only gesture, and the picker is it, in both directions.

/// A toolbar-sized icon button that visibly responds to the pointer.
///
/// Its own type because every control in the bar needs the same hover treatment, and a Mac
/// without hover feedback reads as not-clickable — the single most common complaint about a
/// touch UI ported straight across.
///
/// Hover and press are both wanted, and they say different things: the background says "this is
/// clickable", the shrink says "that click landed". This was `.buttonStyle(.plain)`, which is
/// exactly the missing-acknowledgement `PressableButtonStyle` exists to fix — so shuffle, the
/// skips, the heart and the queue toggle went dead under the pointer while the play button
/// beside them, already on `.pressable`, did not.
struct HoverButton: View {
    let systemImage: String
    let label: String
    var tint: Color?
    let action: () -> Void

    @State private var isHovering = false
    /// `.disabled` does not stop `.onHover` firing. The transport is reachable in a disabled
    /// state for the first time now that the bar is on screen with nothing playing, so without
    /// this shuffle and the two skips lit up under the pointer while a click did nothing — and
    /// the plate's entire job is to say "this is clickable".
    ///
    /// Read on a real `View`, which is the half of this that resolves: the note on
    /// `PressableButtonStyle.Effects` records why the same lookup had to be moved off the style
    /// value to work at all.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(tint ?? .primary)
                .frame(width: 28, height: 28)
                // Gated at the draw rather than inside `.onHover`, so the plate also clears for a
                // pointer already resting on a control when that control goes dead — which is
                // what happens when the last track of a queue ends under the cursor.
                .background(isHovering && isEnabled ? Color.primary.opacity(0.12) : .clear,
                            // `.continuous`, like every other shape in the app — see Theme.Radius.
                            in: Theme.Radius.rect(6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
