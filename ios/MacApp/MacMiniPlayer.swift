import AppKit
import SwiftUI

/// Whether the floating miniplayer is on screen, and the id the scene is opened by.
///
/// A singleton rather than a `@Binding` threaded down from `MacRootView`, for the reason
/// `TransportMetrics` is one: the toggle that opens this window lives in the transport bar of a
/// *different* window, and the window itself can be closed by its own close button or by the
/// idle rule below — neither of which passes through the bar. A shared fact both windows read is
/// the only shape where the button's lit state cannot drift from what is actually on screen.
@MainActor
final class MiniPlayerPresence: ObservableObject {
    static let shared = MiniPlayerPresence()

    /// Also the scene id. `openWindow(id:)` and `dismissWindow(id:)` both take it.
    static let windowId = "miniplayer"

    @Published private(set) var isOpen = false

    func opened() { isOpen = true }
    func closed() { isOpen = false }

    private init() {}
}

extension Notification.Name {
    static let vvdemusDebugOpenMiniplayer = Notification.Name("vvdemusDebugOpenMiniplayer")
}

/// The corner player: artwork, the words, and enough transport to run the session without
/// bringing the main window forward.
///
/// It shows whichever session is on screen — this Mac's, or the phone's when that is the one
/// playing — and its buttons act on that one, exactly as `MacNowPlayingBar` does. The two are
/// never both visible without also being in agreement, because they read the same `PeerPlayback`.
struct MacMiniPlayerView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject private var peer = PeerPlayback.shared
    @Environment(\.dismissWindow) private var dismissWindow
    /// The panel follows the system appearance rather than being pinned dark like the main
    /// window, which is the whole of what makes black-text-on-white possible: glass and label
    /// colours resolve from the appearance, never from the pixels behind the window. Sampling
    /// those would need screen-recording permission, which this app does not ask for.
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var backdrop = MiniPlayerBackdrop.shared

    /// Which half of the toggle is showing. Deliberately not persisted: the window is a glance
    /// at what is playing, and coming back to lyrics you left up three days ago over a different
    /// song is not the state anyone meant to restore.
    @State private var showingLyrics = false
    @State private var isHovering = false
    @State private var idleCloseTask: Task<Void, Never>?

    /// How long "nothing playing" has to hold before the window closes itself.
    ///
    /// Not zero, and the reason is written down in `MacNowPlayingBar.leading`: `displayedTrack`
    /// falls to nil when the *peer link* drops, not only when playback ends. One failed poll
    /// clears `isPeerReachable`, `recomputeMirroring` clears `isMirroring`, and this device's own
    /// `PlayerService` is deliberately empty while mirroring — so a phone that is still playing
    /// reads as nothing playing for the length of the backoff, 5 seconds doubling to 30.
    ///
    /// The bar survives that by staying on screen in a resting state. This window cannot: it was
    /// asked to close when idle, and it does not reopen on its own, so a close during a blip
    /// costs the window until someone presses ⌘M. 35 seconds outlasts a saturated backoff, which
    /// makes a wrong close much less likely than a late one — and a late close is invisible while
    /// a wrong one is not.
    private static let idleCloseGrace: TimeInterval = 35

    /// The glass sheet's corner, and so the window's — the window itself no longer draws one,
    /// because it has no opaque ground left to draw.
    private static let windowCornerRadius: CGFloat = 14

    /// What keeps a label readable when the glass goes the same brightness as the text on it.
    ///
    /// Matched to the appearance, not fixed: a black halo behind black text is what produced the
    /// smeared look over a white desktop. It lifts the text off the glass by contrast, so it has
    /// to be the opposite of the text colour, and it is deliberately faint — with the appearance
    /// now doing the real work, this is only insurance against a busy backdrop.
    private var textScrim: Color {
        colorScheme == .dark ? .black.opacity(0.5) : .white.opacity(0.6)
    }

    /// The band the lyrics fade into behind the hover controls. Same reasoning as `textScrim`:
    /// fading words into black on a light panel draws a dark smear across the bottom of the
    /// window, so the band has to be the panel's own ground, not a fixed colour.
    /// What sits *on* the filled play button — the inverse of `.primary`, so the glyph reads
    /// against the disc in either appearance. Spelled out rather than `.background`, which is a
    /// `ShapeStyle` and so cannot be handed to `tint`.
    private var onPrimary: Color {
        colorScheme == .dark ? .black : .white
    }

    private var scrimGradient: [Color] {
        let base: Color = colorScheme == .dark ? .black : .white
        return [base.opacity(0), base.opacity(0.75), base.opacity(0.92)]
    }

    var body: some View {
        VStack(spacing: 0) {
            stage
            bottomBar
        }
        .frame(minWidth: 220, minHeight: 260)
        // One glass surface for the whole window rather than a material per bar.
        //
        // The top strip, the bands either side of the cover and the title row are all the same
        // sheet, so there is no seam where two materials meet at slightly different tints — which
        // is what makes a stack of separately-blurred bars read as a panel rather than as glass.
        // Everything above draws onto it.
        .background {
            Color.clear
                .glassEffect(.clear, in: .rect(cornerRadius: Self.windowCornerRadius))
        }
        // The window is transparent now, so nothing else is clipping the content to the frame the
        // glass draws — without this the artwork's corners overhang the sheet.
        .clipShape(.rect(cornerRadius: Self.windowCornerRadius))
        // Driven by what is measured behind the window, not by the system setting. `nil` until
        // the first reading lands, which leaves the system's own answer in place meanwhile.
        .preferredColorScheme(backdrop.isLight.map { $0 ? .light : .dark })
        .background(MiniPlayerWindowConfigurator())
        .onAppear {
            MiniPlayerPresence.shared.opened()
            scheduleIdleCloseIfNeeded()
        }
        .onDisappear {
            MiniPlayerPresence.shared.closed()
            idleCloseTask?.cancel()
            idleCloseTask = nil
        }
        .onChange(of: peer.displayedTrack == nil) { _, _ in
            scheduleIdleCloseIfNeeded()
        }
    }

    // MARK: - The stage

    /// Artwork or words, whichever the toggle is on, drawn straight onto the window's glass.
    private var stage: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                // No ground of its own any more. The bands either side of the cover used to hold
                // a blurred enlargement of the artwork; they are now the window's glass, so what
                // is behind the window shows through them.
                if let track = peer.displayedTrack {
                    if showingLyrics {
                        lyrics(for: track)
                    } else {
                        RemoteImage(url: track.thumbnailUrl, size: side, cornerRadius: Theme.Radius.card)
                            .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
                    }
                } else {
                    resting(side: side)
                }

                // Above the art, below the scrubber: the controls are what the pointer is here
                // for, and the scrubber has to stay hittable while they are showing.
                if isHovering, peer.displayedTrack != nil {
                    controlsLayer
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .bottom) { scrubberBlock }
            .clipped()
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.16)) { isHovering = hovering }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `.inline`, so `LyricsView` paints no ground of its own and the window's glass shows
    /// through — the same reason `NowPlayingView` asks for it over the artwork gradient, and what
    /// makes the words sit on the glass rather than on a panel laid over it.
    ///
    /// `transportClearance(false)` because the clearance is a *global*: `TransportMetrics.height`
    /// is whatever the main window's transport bar measured, and this window has no transport bar
    /// at its bottom edge. Left on, every branch of `LyricsView` would reserve ~60pt of empty
    /// space inside a panel a third that tall.
    private func lyrics(for track: Track) -> some View {
        LyricsView(track: track, player: player, presentation: .inline)
            .transportClearance(false)
            .padding(.horizontal, Theme.Space.sm)
            // Clear of the scrubber, which is drawn over this.
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The shadow is applied to the whole view rather than to a `Text`, because the lines
            // are `LyricsView`'s own and this panel does not get to restyle them one by one. A
            // drop shadow on the container renders under whatever that view draws, which is the
            // only way to protect text belonging to a shared screen without forking it.
            .shadow(color: textScrim, radius: 3, y: 1)
    }

    /// `RemoteImage` with no URL rather than a hand-drawn placeholder, for the reason
    /// `MacNowPlayingBar.resting` gives: it already draws this app's empty artwork, so the two
    /// cannot drift apart.
    private func resting(side: CGFloat) -> some View {
        VStack(spacing: Theme.Space.md) {
            RemoteImage(url: nil, size: side * 0.55, cornerRadius: Theme.Radius.card)
            Text("Nothing playing")
                .font(.miniSubtitle)
                .foregroundStyle(.secondary)
        }
    }

    /// Where the controls sit depends on what they are covering.
    ///
    /// Over artwork they go in the middle, as in Spotify's own miniplayer — the centre of a
    /// cover is the part you lose least by hiding. Over lyrics that would blot out the line
    /// currently being sung, which is the one line the panel exists to show, so they drop to the
    /// bottom and take the oldest lines with them, behind a scrim that fades the words out rather
    /// than letting them collide with the glyphs.
    @ViewBuilder
    private var controlsLayer: some View {
        if showingLyrics {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack(alignment: .bottom) {
                    LinearGradient(
                        colors: scrimGradient,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 118)
                    // The lyrics scroll under this; the band is decoration, and swallowing
                    // drags here would make the words unscrollable exactly where they are
                    // hardest to read.
                    .allowsHitTesting(false)

                    transportOverlay
                        // Clear of the scrubber drawn along the bottom edge.
                        .padding(.bottom, 26)
                }
            }
        } else {
            transportOverlay
        }
    }

    private var transportOverlay: some View {
        HStack(spacing: Theme.Space.md) {
            shuffleButton

            HoverButton(systemImage: "backward.fill", label: "Previous track") { player.previous() }

            // Keeps its slot while loading rather than collapsing to a spinner of a different
            // width — the same reflow `MacNowPlayingBar` avoids, and more visible here where the
            // row is centred and every neighbour moves with it.
            Button { player.togglePlayPause() } label: {
                ZStack {
                    // `.primary` over `.background` rather than white over black: the filled
                    // circle is the panel's one high-contrast control, and a white disc on a
                    // white desktop is the one place that reads as a hole rather than a button.
                    Circle().fill(.primary)
                    if peer.displayedIsLoading {
                        ProgressView().controlSize(.small).tint(onPrimary)
                    } else {
                        Image(systemName: peer.displayedIsPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundStyle(onPrimary)
                    }
                }
                .frame(width: 42, height: 42)
                .contentShape(Circle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(peer.displayedIsPlaying ? "Pause" : "Play")

            HoverButton(systemImage: "forward.fill", label: "Next track") { player.advance() }

            // A hidden second shuffle, purely to balance the row.
            //
            // With four controls the play button sits third of four and is visibly off to the
            // right of the panel's centre line — which is the one control the pointer goes
            // looking for, and the one the artwork is centred behind. Mirroring the leading
            // button's exact width puts it dead centre without inventing a fifth control or
            // hand-tuning a padding that would drift the moment a glyph changed.
            shuffleButton
                .hidden()
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        // Glass, not a black wash: the wash was invisible over a dark desktop and a grey slab
        // over a light one. `.regular` rather than the window's `.clear` deliberately — the
        // controls are the one thing here that must stay legible whatever is behind them.
        .glassEffect(.regular, in: .capsule)
    }

    private var shuffleButton: some View {
        HoverButton(
            systemImage: "shuffle",
            label: peer.displayedIsShuffling ? "Turn off shuffle" : "Shuffle",
            tint: peer.displayedIsShuffling ? Theme.accent : nil
        ) {
            player.toggleShuffle()
        }
    }

    /// Times above, bar below — so the bar is the same width in both states and nothing under the
    /// pointer moves when the times arrive. The row keeps its height at rest for the same reason;
    /// only its opacity changes.
    private var scrubberBlock: some View {
        VStack(spacing: 3) {
            HStack {
                Text(Self.timestamp(peer.displayedProgress))
                Spacer(minLength: Theme.Space.sm)
                Text(Self.timestamp(peer.displayedDuration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0)
            .frame(height: 12)

            MiniScrubber(
                progress: peer.displayedProgress,
                duration: peer.displayedDuration,
                showsThumb: isHovering
            ) { target in
                player.seek(to: target)
            }
            .disabled(peer.displayedTrack == nil || peer.displayedDuration <= 0)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.bottom, Theme.Space.sm)
        // The bar's unplayed track is white at 25%, which is invisible against a white window
        // behind clear glass. The shadow gives it an edge on any ground without darkening the
        // glass itself.
        .shadow(color: textScrim, radius: 3, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playback position")
        .accessibilityValue(
            "\(Self.timestamp(peer.displayedProgress)) of \(Self.timestamp(peer.displayedDuration))"
        )
    }

    // MARK: - Title row

    private var bottomBar: some View {
        HStack(spacing: Theme.Space.sm) {
            VStack(alignment: .leading, spacing: Theme.Metrics.labelSpacing) {
                Text(peer.displayedTrack?.title ?? "Nothing playing")
                    .font(.miniTitle)
                    .lineLimit(1)
                Text(peer.displayedTrack?.artist ?? " ")
                    .font(.miniSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HoverButton(
                systemImage: showingLyrics ? "photo" : "text.quote",
                label: showingLyrics ? "Show artwork" : "Show lyrics",
                tint: showingLyrics ? Theme.accent : nil
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { showingLyrics.toggle() }
            }
            // Nothing to read the words of, and a toggle that swaps one placeholder for another
            // is a control that does nothing while looking live.
            .disabled(peer.displayedTrack == nil)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        // No `.bar` here any more. That material painted its own ground, so the title row stayed a
        // solid strip no matter what the rest of the window did — the one part that visibly failed
        // to blend. It sits on the window's glass now, like everything else.
        .shadow(color: textScrim, radius: 3, y: 1)
    }

    // MARK: - Idle

    /// Starts, restarts or cancels the close countdown to match the current state.
    private func scheduleIdleCloseIfNeeded() {
        idleCloseTask?.cancel()
        idleCloseTask = nil
        guard peer.displayedTrack == nil else { return }

        idleCloseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.idleCloseGrace))
            guard !Task.isCancelled else { return }
            // Re-read rather than trusting the state that scheduled this: the whole point of the
            // wait is that the answer may have changed, and a peer that came back mid-countdown
            // is the case this exists for.
            guard peer.displayedTrack == nil else { return }
            dismissWindow(id: MiniPlayerPresence.windowId)
        }
    }

    private static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Scrubber

/// A bare progress bar that becomes a scrubber under the pointer.
///
/// Hand-drawn rather than a `Slider` because the resting state has to be *only* the bar — no
/// thumb, no track furniture — and SwiftUI offers no way to take a `Slider`'s knob away.
private struct MiniScrubber: View {
    let progress: Double
    let duration: Double
    let showsThumb: Bool
    let onSeek: (Double) -> Void

    /// Where the pointer has dragged to, while it is dragging.
    ///
    /// The same reason `MacNowPlayingBar.scrubPosition` exists: a drag emits dozens of deltas a
    /// second, and writing each one through as a seek fights the player's own periodic position
    /// updates — worse here than on the bar, because while the phone owns the session every one
    /// of those is a relayed network command. One seek, when the drag ends.
    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let fraction = dragFraction ?? Self.fraction(progress: progress, duration: duration)

            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.22))
                Capsule().fill(Theme.accent).frame(width: width * fraction)

                if showsThumb {
                    Circle()
                        .fill(.primary)
                        .frame(width: 9, height: 9)
                        .offset(x: width * fraction - 4.5)
                }
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            // The 4pt bar is a 4pt target; this makes the whole strip draggable without
            // making the bar itself thicker.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        dragFraction = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { value in
                        guard duration > 0 else { dragFraction = nil; return }
                        let target = min(max(value.location.x / width, 0), 1) * duration
                        dragFraction = nil
                        onSeek(target)
                    }
            )
        }
        .frame(height: 12)
    }

    private static func fraction(progress: Double, duration: Double) -> Double {
        guard duration > 0, progress.isFinite else { return 0 }
        return min(max(progress / duration, 0), 1)
    }
}

// MARK: - The window itself

/// An `NSView` that says when it has been given a window.
///
/// `viewDidMoveToWindow` is AppKit telling you the answer instead of you asking for it, which is
/// the difference between configuring the panel reliably and configuring it only when SwiftUI
/// happens to re-render for some unrelated reason.
private final class WindowAwareView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        onWindow?(window)
    }
}

/// Turns the scene's plain window into a floating corner panel.
///
/// None of this is expressible as a SwiftUI scene modifier: window level, Spaces behaviour and
/// frame autosaving are all `NSWindow`, so the view reaches its own window once and configures it.
private struct MiniPlayerWindowConfigurator: NSViewRepresentable {
    /// AppKit's own frame memory, which is why the position and size survive relaunch without any
    /// defaults key of this app's own.
    static let frameAutosaveName = "VVDemusMiniPlayer"

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// `@MainActor` because it holds the sampler, which is main-actor bound — and everything
    /// that touches a coordinator here (`makeCoordinator`, `updateNSView`, `dismantleNSView`)
    /// already runs on the main thread.
    @MainActor
    final class Coordinator {
        var didConfigure = false
        /// The shared instance, so the view observes the same object this drives.
        let backdrop = MiniPlayerBackdrop.shared
    }

    /// Stops the sampler the moment the panel goes away. Without this the capture loop would
    /// outlive the window it was measuring, which is both wasted battery and a screen capture
    /// running with nothing on screen to justify it.
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.backdrop.stop() }
    }

    func makeNSView(context: Context) -> NSView {
        // A view that reports the moment it is given a window, rather than a plain `NSView` whose
        // `window` is polled and hoped about.
        //
        // This used to dispatch `configure(view.window)` from here and again from `updateNSView`.
        // Neither is reliable: at `makeNSView` the view is not in a hierarchy yet, so `window` is
        // nil and configuration is skipped, and the only retry was whatever `updateNSView` SwiftUI
        // happened to send next. With something playing, `PeerPlayback` publishes every second and
        // a retry always arrived; with nothing playing — no session, phone off the network — the
        // view never updated again and the window was never configured at all. The panel then
        // opened as an ordinary window: not floating, not transparent, no backdrop sampler. Which
        // is exactly the "it isn't in front any more" that this comment is being written for.
        let view = WindowAwareView()
        view.onWindow = { [coordinator = context.coordinator] window in
            configure(window, coordinator: coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Still a safety net for the case where the view is reattached to a different window,
        // but no longer the only path to configuration.
        guard !context.coordinator.didConfigure, let window = nsView.window else { return }
        configure(window, coordinator: context.coordinator)
    }

    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window, !coordinator.didConfigure else { return }
        coordinator.didConfigure = true

        // Above ordinary windows, and present on whatever Space you are on — including over a
        // fullscreen app, which is what `.fullScreenAuxiliary` buys that `.canJoinAllSpaces`
        // alone does not.
        window.level = .floating
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.collectionBehavior.insert(.fullScreenAuxiliary)

        // No title bar text, and drag anywhere: with the bar hidden there is no other grip, and
        // the title row at the bottom is a control strip rather than something to pull on.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true

        // Without these three the glass has nothing to sample. A window is opaque by default and
        // paints its own ground behind the content, so `glassEffect` would blur that ground —
        // i.e. blur an opaque colour, which looks like a flat panel and is exactly what it looked
        // like before. Clearing the ground is what lets the material reach the screen behind.
        //
        // The shadow is kept deliberately: a transparent window with no shadow has no edge at
        // all, and the panel stops reading as a window sitting on top of things.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        // Content runs the full height of the window, title bar included. Without this the view
        // starts below the title bar, and since the window no longer paints a ground, that strip
        // showed the desktop raw — a bright band across the top of an otherwise frosted panel,
        // which is the opposite of blending in.
        window.styleMask.insert(.fullSizeContentView)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        // Restore before deciding where to put it: `setFrameAutosaveName` reapplies a saved frame
        // itself, so a first open is the one case that needs a position chosen here.
        let hadSavedFrame = UserDefaults.standard.object(
            forKey: "NSWindow Frame \(Self.frameAutosaveName)"
        ) != nil
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if !hadSavedFrame { moveToBottomTrailing(window) }

        // Last, so the first reading is taken against the frame the panel will actually occupy
        // rather than the one it was created at.
        coordinator.backdrop.start(for: window)
    }

    private func moveToBottomTrailing(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let margin: CGFloat = 20
        let area = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(
            CGPoint(x: area.maxX - size.width - margin, y: area.minY + margin)
        )
    }
}
