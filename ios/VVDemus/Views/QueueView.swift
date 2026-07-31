import SwiftUI

struct QueueView: View {
    @ObservedObject var player: PlayerService
    @State private var path = NavigationPath()
    /// A real binding, not `.constant(.active)`.
    ///
    /// Forcing edit mode on made every `.swipeActions` on this screen inert — Remove, plus
    /// the four from `.trackActions` — so swiping a queue row did nothing at all and there
    /// was no affordance explaining why. Reordering is now opt-in via the Edit button, and
    /// swiping works the rest of the time.
    @State private var editMode: EditMode = .inactive

    private var isQueueEmpty: Bool {
        player.manualQueue.isEmpty && player.contextQueue.isEmpty
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let current = player.currentTrack {
                    Section("Now Playing") {
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

                if !player.manualQueue.isEmpty {
                    Section("Next in Queue") {
                        ForEach(Array(player.manualQueue.enumerated()), id: \.offset) { index, track in
                            queueRow(
                                track,
                                skip: { player.skipToManualQueueEntry(at: index, expecting: track) },
                                remove: { player.removeFromManualQueue(at: index, expecting: track) }
                            )
                        }
                        .onMove { player.moveInManualQueue(from: $0, to: $1) }
                    }
                }

                if !player.contextQueue.isEmpty {
                    Section(player.queueContextTitle.map { "Next from: \($0)" } ?? "Next Up") {
                        ForEach(Array(player.contextQueue.enumerated()), id: \.offset) { index, track in
                            queueRow(
                                track,
                                skip: { player.skipToContextQueueEntry(at: index, expecting: track) },
                                remove: { player.removeFromContextQueue(at: index, expecting: track) }
                            )
                        }
                        .onMove { player.moveInContextQueue(from: $0, to: $1) }
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, $editMode)
            .navigationTitle("Queue")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // The same `$editMode` state is injected again here: toolbar content is
                    // hoisted into the navigation bar, so it does not reliably inherit the
                    // environment written onto the List below it.
                    EditButton()
                        .environment(\.editMode, $editMode)
                        .disabled(isQueueEmpty)
                }
            }
            .navigationDestination(for: LibraryDestination.self) { destination in
                destination.destination(player: player)
            }
            .environment(\.openRadio) { track in path.append(LibraryDestination.radio(track)) }
        }
    }

    private func queueRow(_ track: Track, skip: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        // By position, like `remove` below. `skipTo(track)` matches the first entry
        // with that id, so tapping the second of two identical rows played the first
        // and discarded everything in between.
        TrackRow(track: track, isActive: player.currentTrack?.id == track.id, onTap: skip)
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
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: Theme.Metrics.trailingControl, height: Theme.Metrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }
}
