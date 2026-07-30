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

    var body: some View {
        NavigationStack(path: $path) {
            List {
                header
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 16, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)

                if let current = player.currentTrack {
                    nowPlayingRow(current)
                        .listRowBackground(Theme.background)
                        .listRowSeparator(.hidden)
                        .moveDisabled(true)
                }

                if player.manualQueue.isEmpty && player.contextQueue.isEmpty {
                    Text("Queue is empty — autoplay will keep the music going.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .listRowBackground(Theme.background)
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
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .environment(\.editMode, $editMode)
            .safeAreaInset(edge: .top) { queueToolbar }
            .navigationBarHidden(true)
            .navigationDestination(for: LibraryDestination.self) { destination in
                switch destination {
                case .liked:
                    LikedSongsView(player: player)
                case .playlist(let id):
                    PlaylistDetailView(playlistId: id, player: player)
                case .radio(let seed):
                    RadioDetailView(seedTrack: seed, player: player)
                case .daylist:
                    DaylistDetailView(player: player)
                case .downloads:
                    DownloadsView(player: player)
                case .stats:
                    StatsView(player: player)
                }
            }
            .environment(\.openRadio) { track in path.append(LibraryDestination.radio(track)) }
        }
    }

    /// Edit/Done, so reordering is available without disabling every swipe action.
    private var queueToolbar: some View {
        HStack {
            Spacer()
            Button(editMode.isEditing ? "Done" : "Reorder") {
                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .background(Theme.background)
    }

    private func queueRow(_ track: Track, skip: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        TrackRow(track: track)
            .listRowBackground(Theme.background)
            .listRowSeparatorTint(Theme.card)
            .contentShape(Rectangle())
            // By position, like `remove` below. `skipTo(track)` matches the first entry
            // with that id, so tapping the second of two identical rows played the first
            // and discarded everything in between.
            .onTapGesture(perform: skip)
            .trackActions(track: track, player: player)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Queue")
                .font(.title.bold())
                .foregroundStyle(.white)
            if let context = player.queueContextTitle {
                Text("Playing \(context)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func nowPlayingRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: track.thumbnailUrl, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle().fill(Color.white).frame(width: 36, height: 36)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.footnote)
                        .foregroundStyle(.black)
                }
            }
            .buttonStyle(.pressable)
        }
        // Glass sets the current track apart from the plain rows queued behind it, which a
        // green title alone was carrying on its own.
        .padding(10)
        .glassSurface(cornerRadius: 16, elevation: .flush)
    }
}
