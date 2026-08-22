import SwiftUI

struct QueueView: View {
    @ObservedObject var player: PlayerService
    /// The queue on screen belongs to whichever device owns the session, so every row comes
    /// from here — while the paired device owns it this one's `PlayerService` holds nothing at
    /// all. Taps, swipes and menu items still go to `player`, which relays them to the owner
    /// (`SessionOwning`) addressed by videoId rather than by the position they were rendered at.
    @ObservedObject private var peer = PeerPlayback.shared
    @State private var path = NavigationPath()
    /// A real binding, not `.constant(.active)`.
    ///
    /// Forcing edit mode on made every `.swipeActions` on this screen inert — Remove, plus
    /// the four from `.trackActions` — so swiping a queue row did nothing at all and there
    /// was no affordance explaining why. Reordering is now opt-in via the Edit button, and
    /// swiping works the rest of the time.
    @State private var editMode: PlatformEditMode = .inactive

    private var isQueueEmpty: Bool {
        peer.displayedManualQueue.isEmpty && peer.displayedContextQueue.isEmpty
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let current = peer.displayedTrack {
                    // "Now Playing on <device>" while the session is elsewhere: the rows below
                    // are the other device's queue, and a header that says so is the smallest
                    // thing that explains why the phone is showing songs it isn't playing.
                    Section(peer.owningDeviceName.map { "Now Playing on \($0)" } ?? "Now Playing") {
                        nowPlayingRow(current)
                    }
                }

                if isQueueEmpty {
                    ContentUnavailableView(
                        "Queue is Empty",
                        systemImage: "list.bullet",
                        description: Text("Autoplay will keep the music going.")
                    )
                    .listRowSeparator(.hidden)
                }

                if !peer.displayedManualQueue.isEmpty {
                    Section("Next in Queue") {
                        reorderable(
                            ForEach(Array(peer.displayedManualQueue.enumerated()), id: \.offset) { index, track in
                                queueRow(
                                    track,
                                    skip: { player.skipToManualQueueEntry(at: index, expecting: track) },
                                    remove: { player.removeFromManualQueue(at: index, expecting: track) }
                                )
                            },
                            move: { player.moveInManualQueue(from: $0, to: $1) }
                        )
                    }
                }

                if !peer.displayedContextQueue.isEmpty {
                    Section(peer.displayedContextTitle.map { "Next from: \($0)" } ?? "Next Up") {
                        reorderable(
                            ForEach(Array(peer.displayedContextQueue.enumerated()), id: \.offset) { index, track in
                                queueRow(
                                    track,
                                    skip: { player.skipToContextQueueEntry(at: index, expecting: track) },
                                    remove: { player.removeFromContextQueue(at: index, expecting: track) }
                                )
                            },
                            move: { player.moveInContextQueue(from: $0, to: $1) }
                        )
                    }
                }

                TransportClearanceRow()
            }
            .listStyle(.plain)
            .platformEditMode($editMode)
            .navigationTitle("Queue")
            .toolbar {
                // `EditButton` is iOS-only, and so is the mode it toggles. macOS needs
                // neither: a List row with `.onMove` is draggable whenever it is on screen, so
                // reordering the queue there is always available.
                #if os(iOS)
                ToolbarItem(placement: .trailingActions) {
                    // The same `$editMode` state is injected again here: toolbar content is
                    // hoisted into the navigation bar, so it does not reliably inherit the
                    // environment written onto the List below it.
                    EditButton()
                        .environment(\.editMode, $editMode)
                        .disabled(isQueueEmpty)
                }
                #endif
            }
            .navigationDestination(for: LibraryDestination.self) { destination in
                destination.destination(player: player)
            }
        }
        // On the stack rather than on the list inside it, so a radio reached from a queued
        // track keeps working one push in — see the note in `MacRootView.detail`.
        .environment(\.openRadio) { track in path.append(LibraryDestination.radio(track)) }
    }

    /// Reordering works from either device.
    ///
    /// It was the one queue edit with no command on the wire, so a drag on the mirroring device
    /// rearranged nothing — the local queue it mutates is empty there — and the rows snapped back
    /// on the next poll. `moveInQueue` carries the move now, along with the dragged track's
    /// videoId so the owner can find the row again if its position has shifted in the meantime.
    @ViewBuilder
    private func reorderable<Rows: DynamicViewContent>(
        _ rows: Rows,
        move: @escaping (IndexSet, Int) -> Void
    ) -> some View {
        rows.onMove(perform: move)
    }

    private func queueRow(_ track: Track, skip: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        // By position, like `remove` below. `skipTo(track)` matches the first entry
        // with that id, so tapping the second of two identical rows played the first
        // and discarded everything in between.
        TrackRow(track: track, isActive: peer.displayedTrack?.id == track.id, onTap: skip)
            .trackRowMetrics()
            // Queue owns the trailing edge, so the shared actions keep only their leading
            // swipe — two trailing sets on one row crammed three buttons together and made
            // the full swipe ambiguous.
            .trackActions(track: track, player: player, includesTrailingSwipes: false)
            // Swipe left (trailing edge) to remove — matches Spotify's convention.
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    // By position, so removing one of two identical entries removes exactly
                    // the one swiped rather than every copy.
                    remove()
                } label: {
                    Label("Remove", systemImage: "minus.circle.fill")
                }
            }
            // The same action as a menu item, because a Mac cannot swipe. Without this, removing
            // something from the queue was simply not possible on the desktop.
            .contextMenu {
                Button("Remove from Queue", role: .destructive) { remove() }
            }
    }

    /// The current track, drawn as an ordinary row under its own section header rather than as
    /// a filled card.
    ///
    /// The card was the wrong instinct twice over: a `Theme.card` fill is the only light
    /// surface on an otherwise black list, so it read as a stray bright box, and it carried
    /// three trailing controls — download ring, heart *and* transport — crammed against the
    /// edge while every row below it had two. The section header already says which track this
    /// is, and the artwork's equalizer overlay already says it's playing, so the row only owes
    /// the user one control: play/pause.
    private func nowPlayingRow(_ track: Track) -> some View {
        HStack(spacing: 0) {
            TrackRow(
                track: track,
                isActive: true,
                showsDownloadControl: false,
                showsLikeControl: false,
                onTap: { player.togglePlayPause() }
            )
            transportButton
        }
        .trackRowMetrics()
        .moveDisabled(true)
        // Download and Like left with the download ring above, so they come back as swipes
        // and a long press, exactly as on every other row on this screen.
        .trackActions(track: track, player: player)
    }

    /// Sized and weighted like the download ring and heart it replaces, so the trailing
    /// controls stay in one column all the way down the screen. It used to be a filled green
    /// circle — the only solid-filled control in any list in the app.
    private var transportButton: some View {
        Button {
            player.togglePlayPause()
        } label: {
            Image(systemName: peer.displayedIsPlaying ? "pause.fill" : "play.fill")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: Theme.Metrics.trailingControl, height: Theme.Metrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(peer.displayedIsPlaying ? "Pause" : "Play")
    }
}
