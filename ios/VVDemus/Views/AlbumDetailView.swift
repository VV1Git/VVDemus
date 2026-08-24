import SwiftUI

/// One release, laid out like every other collection in the app: hero, Play / Shuffle /
/// Download-all, then the tracks.
///
/// The differences from `RadioDetailView` are all consequences of one fact — an album's
/// tracklist is fixed. There is no refresh in the menu because a second fetch returns the
/// same songs, and no "this mix changed under you" problem to design around. What it gains
/// instead is a record of itself: the release is written into `AlbumHistoryStore` when the
/// screen opens, which is what puts it on Home and in Library.
struct AlbumDetailView: View {
    let album: Album
    @ObservedObject var player: PlayerService
    @ObservedObject private var cache = AlbumCacheStore.shared
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var sortOption: MixSortOption = .order

    /// The release as it is currently known, which is not always the one navigated to. The
    /// album page carries a year and a full byline that a search row or a synced tile may
    /// not, and `load()` writes the better copy into history — so this reads back through
    /// the store rather than trusting the value it was handed.
    @ObservedObject private var history = AlbumHistoryStore.shared
    private var current: Album {
        history.albums.first { $0.browseId == album.browseId } ?? album
    }

    private var tracks: [Track] { cache.tracks(for: album.browseId) ?? [] }

    private var visibleTracks: [Track] {
        sortOption.apply(to: filterTracks(tracks, matching: searchText))
    }

    /// What a tapped row queues up behind itself.
    ///
    /// Sorted, because the queue has to be the order on screen: `PlayerService.play` queues
    /// everything after the track *in the array it is handed*, so passing the album's natural
    /// order while showing a re-sorted list queued songs that were nowhere near the one tapped —
    /// and if the tapped row happened to be the album's last track in natural order, it queued
    /// nothing at all. An empty context queue with a track still playing is the one state that
    /// sends `advance()` into `continueAutoplay`, so the album stopped being an album and became
    /// a radio named after that song, halfway down a list with songs still visible below it.
    ///
    /// Not filtered, deliberately: "Find on this page" narrows what you are *looking* at, and
    /// playing a search hit should carry on through the record rather than through the three
    /// songs that matched what you typed.
    private var playbackContext: [Track] {
        sortOption.apply(to: tracks)
    }

    var body: some View {
        Group {
            if isLoading && tracks.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, tracks.isEmpty {
                ErrorRow(message: errorMessage) { Task { await load() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                ContentUnavailableView(
                    "No Songs",
                    systemImage: "square.stack",
                    description: Text("This album came back empty.")
                )
            } else {
                trackList
            }
        }
        .background(Theme.screenBackground)
        .navigationTitle(current.title)
        .compactNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .trailingActions) {
                Menu {
                    MixSortPicker(selection: $sortOption)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .task { await load() }
    }

    private var trackList: some View {
        List {
            MixDetailHeader(
                title: current.title,
                subtitle: current.subtitle,
                imageURL: current.thumbnailUrl,
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
                        player.play(track: track, context: playbackContext, contextTitle: current.title)
                    }
                    .trackRowMetrics()
                    .trackActions(track: track, player: player)
                }
            }

            TransportClearanceRow()
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Find on this page")
    }

    private func playAll(shuffled: Bool) {
        guard !tracks.isEmpty else { return }
        // Same order the rows are in, for the same reason `playbackContext` exists: pressing Play
        // on an album sorted by title and getting it back in track order is the same surprise as
        // the queue disagreeing with the list, one press earlier.
        let ordered = shuffled ? tracks.shuffled() : playbackContext
        // No `contextSeed`: that is what starts a *radio*, and it would record this album's
        // first track as a station in `RadioHistoryStore` every time the album was played.
        player.play(track: ordered[0], context: ordered, contextTitle: current.title)
    }

    /// Records the visit, then fills the tracklist if it isn't already cached.
    ///
    /// The record is written first and unconditionally — an album opened from Home and closed
    /// again without playing anything is still the most recent thing you looked at, and the
    /// grid's ordering is about exactly that. It also means an album whose tracks fail to load
    /// is still reachable from Home to try again, rather than being lost the moment you leave.
    private func load() async {
        AlbumHistoryStore.shared.record(album)
        RecentOpensStore.shared.markOpened(RecentOpensStore.albumKey(album.browseId))

        errorMessage = nil
        guard tracks.isEmpty else {
            isLoading = false
            return
        }
        isLoading = true
        do {
            let page = try await APIClient.shared.album(browseId: album.browseId)
            AlbumCacheStore.shared.store(page.tracks, for: album.browseId)
            // The page knows more than the row that led here — a year, the full artist
            // credit, the cover at album resolution. Recorded again so Home's tile and
            // Library's row show it too, not just this screen.
            AlbumHistoryStore.shared.record(page.album)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't load this album. Check your connection."
        }
        isLoading = false
    }
}
