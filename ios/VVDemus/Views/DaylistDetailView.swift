import SwiftUI

struct DaylistDetailView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject private var store = DaylistStore.shared
    @State private var searchText = ""
    @State private var sortOption: MixSortOption = .order

    private var visibleTracks: [Track] {
        sortOption.apply(to: filterTracks(store.tracks, matching: searchText))
    }

    var body: some View {
        Group {
            if store.tracks.isEmpty && store.isRefreshing {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            } else if store.tracks.isEmpty, let errorMessage = store.errorMessage {
                ErrorRow(message: errorMessage) { Task { await store.refresh() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            } else {
                List {
                    MixDetailHeader(
                        title: store.title.isEmpty ? "Daylist" : store.title,
                        subtitle: "Made for you, updates through the day",
                        badge: "Daylist",
                        imageURL: store.tracks.first?.thumbnailUrl,
                        trackCount: store.tracks.count,
                        totalDuration: totalDuration(of: store.tracks),
                        onPlay: { playAll(shuffled: false) },
                        onShuffle: { playAll(shuffled: true) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)

                    ForEach(visibleTracks) { track in
                        TrackRow(track: track, isActive: player.currentTrack?.id == track.id)
                            .listRowBackground(Theme.background)
                            .listRowSeparatorTint(Theme.card)
                            .onTapGesture {
                                player.play(track: track, context: store.tracks, contextTitle: store.title)
                            }
                            .trackActions(track: track, player: player)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Theme.background)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find on this page")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(MixSortOption.allCases, id: \.self) { option in
                        Button(option.label(orderLabel: "Recommended order")) { sortOption = option }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .task { await store.refreshIfNeeded() }
    }

    private func playAll(shuffled: Bool) {
        guard !store.tracks.isEmpty else { return }
        let ordered = shuffled ? store.tracks.shuffled() : store.tracks
        player.play(track: ordered[0], context: ordered, contextTitle: store.title)
    }
}
