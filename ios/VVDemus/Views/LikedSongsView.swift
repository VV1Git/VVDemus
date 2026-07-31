import SwiftUI

struct LikedSongsView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject private var liked = LikedSongsStore.shared
    @State private var searchText = ""
    @State private var sortOption: MixSortOption = .order

    private var visibleTracks: [Track] {
        sortOption.apply(to: filterTracks(liked.tracks, matching: searchText))
    }

    var body: some View {
        Group {
            if liked.tracks.isEmpty {
                ContentUnavailableView(
                    "No Liked Songs",
                    systemImage: "heart",
                    description: Text("Tap the heart on any song and it will appear here.")
                )
            } else {
                trackList
            }
        }
        .background(Theme.background)
        .navigationTitle("Liked Songs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    MixSortPicker(selection: $sortOption)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private var trackList: some View {
        List {
            MixDetailHeader(
                title: "Liked Songs",
                subtitle: "",
                imageURL: liked.tracks.first?.thumbnailUrl,
                trackCount: liked.tracks.count,
                totalDuration: totalDuration(of: liked.tracks),
                tracks: liked.tracks,
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
                        player.play(track: track, context: liked.tracks, contextTitle: "Liked Songs")
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
        guard !liked.tracks.isEmpty else { return }
        let ordered = shuffled ? liked.tracks.shuffled() : liked.tracks
        player.play(track: ordered[0], context: ordered, contextTitle: "Liked Songs")
    }
}
