import SwiftUI

struct RadioDetailView: View {
    let seedTrack: Track
    @ObservedObject var player: PlayerService
    @ObservedObject private var radioCache = RadioCacheStore.shared
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var sortOption: MixSortOption = .order
    @State private var isRefreshing = false

    /// Reads straight from the shared cache so a refresh triggered from the web remote
    /// control (or another screen) shows up here immediately, not just on next visit.
    private var tracks: [Track] { radioCache.tracks(for: seedTrack.videoId) ?? [] }

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
            } else if let errorMessage {
                ErrorRow(message: errorMessage) { Task { await load() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                ContentUnavailableView(
                    "No Songs",
                    systemImage: "music.note.list",
                    description: Text("This radio came back empty. Refresh to build it again.")
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
                            Task { await refresh() }
                        } label: {
                            Label(isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(isRefreshing)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .task { await load() }
    }

    private var trackList: some View {
        List {
            MixDetailHeader(
                title: title,
                subtitle: subtitle,
                imageURL: seedTrack.thumbnailUrl,
                trackCount: tracks.count,
                totalDuration: totalDuration(of: tracks),
                tracks: tracks,
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
                        player.play(track: track, context: tracks, contextTitle: title, contextSeed: seedTrack)
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
        guard !tracks.isEmpty else { return }
        let ordered = shuffled ? tracks.shuffled() : tracks
        player.play(track: ordered[0], context: ordered, contextTitle: title, contextSeed: seedTrack)
    }

    private func fetchTracks() async throws -> [Track] {
        try await APIClient.shared.radio(videoId: seedTrack.videoId)
    }

    /// Fetches a mix only the first time a radio is opened; after that the cached list is
    /// what you get, every time, until you ask for a new one with the refresh button.
    ///
    /// This used to re-fetch in the background whenever the cached mix was more than five
    /// minutes old and quietly swap the result in. Because YouTube's radio endpoint returns
    /// a different selection on every call, that meant a radio could rearrange itself, drop
    /// songs, or gain new ones while you were reading it — with no way to get the previous
    /// list back. Re-fetching is now always something the user asked for.
    private func load() async {
        errorMessage = nil
        guard tracks.isEmpty else {
            isLoading = false
            return
        }
        isLoading = true
        do {
            let fresh = try await fetchTracks()
            RadioCacheStore.shared.store(fresh, for: seedTrack.videoId)
        } catch {
            if tracks.isEmpty {
                errorMessage = "Couldn't load this radio. Check your connection."
            }
        }
        isLoading = false
    }

    /// Re-fetches a fresh mix for the same seed track — YouTube Music's radio endpoint
    /// varies between calls, so this surfaces a different set of related songs. Storing it
    /// updates every view (and every connected web browser) watching this radio.
    private func refresh() async {
        isRefreshing = true
        if let fresh = try? await fetchTracks() {
            RadioCacheStore.shared.store(fresh, for: seedTrack.videoId)
        }
        isRefreshing = false
    }
}
