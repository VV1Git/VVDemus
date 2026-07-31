import SwiftUI

struct DaylistDetailView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject private var store = DaylistStore.shared
    @State private var searchText = ""
    @State private var sortOption: MixSortOption = .order

    /// The daylist's name is a generated phrase, so the collection's kind rides in the
    /// subtitle instead of the artwork badge the header no longer draws.
    private var title: String { store.title.isEmpty ? "Daylist" : store.title }

    private var visibleTracks: [Track] {
        sortOption.apply(to: filterTracks(store.tracks, matching: searchText))
    }

    var body: some View {
        Group {
            if store.tracks.isEmpty && store.isRefreshing {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.tracks.isEmpty, let errorMessage = store.errorMessage {
                ErrorRow(message: errorMessage) { Task { await store.refresh() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.tracks.isEmpty {
                ContentUnavailableView(
                    "No Songs",
                    systemImage: "music.note.list",
                    description: Text("Today's daylist hasn't arrived yet. Refresh to try again.")
                )
            } else {
                trackList
            }
        }
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    MixSortPicker(selection: $sortOption)
                    Section {
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Label(store.isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.isRefreshing)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .task { await store.refreshIfNeeded() }
    }

    private var trackList: some View {
        List {
            MixDetailHeader(
                title: title,
                subtitle: "Daylist · Updates through the day",
                imageURL: store.tracks.first?.thumbnailUrl,
                trackCount: store.tracks.count,
                totalDuration: totalDuration(of: store.tracks),
                tracks: store.tracks,
                onPlay: { playAll(shuffled: false) },
                onShuffle: { playAll(shuffled: true) }
            )
            .mixHeaderRowMetrics()

            if visibleTracks.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(visibleTracks) { track in
                    TrackRow(track: track, isActive: player.currentTrack?.id == track.id) {
                        player.play(track: track, context: store.tracks, contextTitle: store.title)
                    }
                    .trackRowMetrics()
                    .trackActions(track: track, player: player)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Find on this page")
    }

    private func playAll(shuffled: Bool) {
        guard !store.tracks.isEmpty else { return }
        let ordered = shuffled ? store.tracks.shuffled() : store.tracks
        player.play(track: ordered[0], context: ordered, contextTitle: store.title)
    }
}
