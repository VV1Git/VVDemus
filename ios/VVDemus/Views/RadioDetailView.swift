import SwiftUI

struct RadioDetailView: View {
    let seedTrack: Track
    @ObservedObject var player: PlayerService
    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var sortOption: MixSortOption = .order
    @State private var isRefreshing = false

    private var title: String { "\(seedTrack.title) Radio" }

    private var subtitle: String {
        let others = tracks
            .filter { $0.id != seedTrack.id }
            .map(\.artist)
            .flatMap { $0.components(separatedBy: ", ") }
        var seen = Set<String>()
        let unique = others.filter { seen.insert($0).inserted }.prefix(3)
        guard !unique.isEmpty else { return "" }
        return "With \(unique.joined(separator: ", ")) and more"
    }

    private var visibleTracks: [Track] {
        sortOption.apply(to: filterTracks(tracks, matching: searchText))
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            } else if let errorMessage {
                ErrorRow(message: errorMessage) { Task { await load() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            } else {
                List {
                    MixDetailHeader(
                        title: title,
                        subtitle: subtitle,
                        badge: "Radio",
                        imageURL: seedTrack.thumbnailUrl,
                        trackCount: tracks.count,
                        totalDuration: totalDuration(of: tracks),
                        tracks: tracks,
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
                                player.play(track: track, context: tracks, contextTitle: title)
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
                    Task { await refresh() }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
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
        .task { await load() }
    }

    private func playAll(shuffled: Bool) {
        guard !tracks.isEmpty else { return }
        let ordered = shuffled ? tracks.shuffled() : tracks
        player.play(track: ordered[0], context: ordered, contextTitle: title)
        RadioHistoryStore.shared.record(seed: seedTrack)
    }

    private func fetchTracks() async throws -> [Track] {
        try await APIClient.shared.radio(videoId: seedTrack.videoId, limit: 50)
    }

    /// Shows a cached mix (if this radio was ever loaded before) immediately, then
    /// refreshes in the background — so a revisit still works offline instead of
    /// blocking on a network call that can't succeed.
    private func load() async {
        if tracks.isEmpty, let cached = RadioCacheStore.shared.tracks(for: seedTrack.videoId) {
            tracks = cached
        }
        isLoading = tracks.isEmpty
        errorMessage = nil
        do {
            let fresh = try await fetchTracks()
            tracks = fresh
            RadioCacheStore.shared.store(fresh, for: seedTrack.videoId)
        } catch {
            if tracks.isEmpty {
                errorMessage = "Couldn't load this radio. Check your connection."
            }
        }
        isLoading = false
    }

    /// Re-fetches a fresh mix for the same seed track — YouTube Music's radio endpoint
    /// varies between calls, so this surfaces a different set of related songs.
    private func refresh() async {
        isRefreshing = true
        if let fresh = try? await fetchTracks() {
            tracks = fresh
            RadioCacheStore.shared.store(fresh, for: seedTrack.videoId)
        }
        isRefreshing = false
    }
}
