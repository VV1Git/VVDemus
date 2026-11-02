import SwiftUI

struct HomeView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject var coordinator: NavigationCoordinator
    @ObservedObject private var history = PlayHistoryStore.shared
    @ObservedObject private var liked = LikedSongsStore.shared
    @ObservedObject private var radioHistory = RadioHistoryStore.shared
    @ObservedObject private var playlists = PlaylistStore.shared
    @ObservedObject private var albumHistory = AlbumHistoryStore.shared
    @ObservedObject private var recentOpens = RecentOpensStore.shared
    @ObservedObject private var daylist = DaylistStore.shared
    @ObservedObject private var network = NetworkMonitor.shared
    @ObservedObject private var feed = HomeFeedStore.shared
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// The grid's own width, measured. A `LazyVGrid` with `.adaptive` columns keeps its
    /// column count to itself, and capping the grid at two rows means knowing it.
    @State private var gridWidth: CGFloat = 0

    private var sections: [RecommendationsBuilder.Section] { feed.sections }

    var body: some View {
        NavigationStack(path: $coordinator.homePath) {
            ScrollView {
                // Spacing 0: every block owns the gap above itself (shelves supply their
                // own Theme.Space.xl), so nothing gets spaced twice.
                VStack(alignment: .leading, spacing: 0) {
                    NavigationLink(value: LibraryDestination.daylist) {
                        DaylistCard(
                            title: daylist.title.isEmpty ? "Your Daylist" : daylist.title,
                            imageURL: daylist.tracks.first?.thumbnailUrl
                        )
                    }
                    .buttonStyle(.pressableCard)
                    .cardHover()
                    .padding(.horizontal, Theme.Metrics.gutter)
                    .padding(.top, Theme.Space.sm)

                    if !shortcuts.isEmpty {
                        shortcutGrid
                            .padding(.top, Theme.Space.lg)
                    }

                    if !radioHistory.stations.isEmpty {
                        HomeShelf(title: "Your Radio") {
                            ForEach(radioHistory.stations) { station in
                                NavigationLink(value: LibraryDestination.radio(station.seedTrack)) {
                                    JumpBackInCard(
                                        title: station.title,
                                        subtitle: "Radio",
                                        imageURL: station.seedTrack.thumbnailUrl
                                    )
                                }
                                .buttonStyle(.pressableCard)
                                .cardHover()
                                .contextMenu { removeRadioButton(station) }
                            }
                        }
                    }

                    if !playlists.playlists.isEmpty {
                        HomeShelf(title: "Your Playlists") {
                            ForEach(playlists.playlists) { playlist in
                                NavigationLink(value: LibraryDestination.playlist(playlist.id)) {
                                    JumpBackInCard(
                                        title: playlist.name,
                                        subtitle: "Playlist",
                                        imageURL: playlist.tracks.first?.thumbnailUrl
                                    )
                                }
                                .buttonStyle(.pressableCard)
                                .cardHover()
                            }
                        }
                    }

                    if isLoading && sections.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else if let errorMessage, sections.isEmpty {
                        // Given the room the shelves would have taken, like the branches either
                        // side of it. Left to size itself the whole failed-feed message sat
                        // jammed under the daylist card with 39% of the screen empty beneath it,
                        // which reads as a page that stopped rendering rather than as a state.
                        ErrorRow(message: errorMessage) { Task { await load() } }
                            .frame(maxWidth: .infinity, minHeight: 440)
                    } else if hasNothingToShow {
                        ContentUnavailableView(
                            "Nothing Here Yet",
                            systemImage: "music.note.list",
                            description: Text("Play a song or search for an artist, and your mixes will show up here.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        ForEach(sections) { section in
                            TrackShelf(title: section.title, tracks: section.tracks, player: player)
                        }
                    }
                }
                // Clears the tab bar / mini player glass, so the last shelf can scroll free of it.
                .padding(.bottom, Theme.Space.xl)
                // And the Mac's transport bar, which is taller and is not part of any tab bar.
                .transportClearance()
            }
            .background(Theme.screenBackground)
            .navigationTitle(greeting)
            .prominentNavigationTitle()
            .toolbar {
                if !network.isConnected {
                    ToolbarItem(placement: .trailingActions) {
                        Label("Offline", systemImage: "wifi.slash")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.warning)
                    }
                }
                // Both platforms. This was desktop-only on the reasoning that the paired device
                // is the computer you are already sitting at — but the phone is where you find
                // out the link is down, because it is the device that gets carried out of range,
                // and "is the Mac reachable" is the question behind every sync that didn't
                // happen. Without it the phone's only readout was the Settings screen.
                ToolbarItem(placement: .trailingActions) {
                    PeerStatusIndicator()
                }
                #if os(macOS)
                // `.refreshable` is the only way to force the feed to rebuild, and it is a
                // pull-to-refresh gesture — which a Mac has no way to perform. Without this the
                // desktop's only recourse for a stale Home was to quit and relaunch.
                ToolbarItem(placement: .trailingActions) {
                    Button {
                        Task { await load(forceRefresh: true) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Refresh")
                }
                #endif
            }
            .navigationDestination(for: LibraryDestination.self) { destination in
                destination.destination(player: player)
            }
        }
        // On the stack rather than on the content inside it, so a radio, album or playlist
        // pushed from Home gets it as well — see the note in `MacRootView.detail`.
        .environment(\.openRadio) { track in coordinator.homePath.append(LibraryDestination.radio(track)) }
        .environment(\.openLyrics) { track in coordinator.homePath.append(LibraryDestination.lyrics(track)) }
        .task { await load() }
        .task { await daylist.refreshIfNeeded() }
        .refreshable { await load(forceRefresh: true) }
    }

    // MARK: - Shortcuts grid (Liked Songs, saved radios, playlists, opened albums)

    /// Everything eligible for the grid, newest first. The ordering itself lives in
    /// `HomeShortcuts.ranked` — it reads four stores and is the whole of the behaviour, so it
    /// is a free function over plain values rather than something only a running app can run.
    private var rankedShortcuts: [HomeShortcut] {
        HomeShortcuts.ranked(
            hasLikedSongs: !liked.tracks.isEmpty,
            radios: radioHistory.stations,
            playlists: playlists.playlists,
            albums: albumHistory.albums,
            albumOpenedAt: { albumHistory.lastOpenedAt($0) },
            openedAt: { recentOpens.openedAt($0) }
        )
    }

    /// What the grid draws at the width it was given.
    private var shortcuts: [HomeShortcut] {
        let all = rankedShortcuts
        let columns = ShortcutGridMetrics.columns(fitting: gridWidth, spacing: Theme.Space.md)
        return Array(all.prefix(ShortcutGridMetrics.visibleCount(available: all.count, columns: columns)))
    }

    private var shortcutGrid: some View {
        // Still `.adaptive`: it holds the tile size and adds columns, which is exactly what a
        // grid that should fill the window wants, and its columns share out the full width
        // rather than leaving the remainder at the trailing edge.
        //
        // The gap this used to end on was never adaptive's doing — it was *running out of
        // tiles*. A wide window fits nine columns; the grid was capped at eight items and
        // trimmed to an even count, so six tiles were drawn into nine column slots and the
        // last three stood empty. Hence the measurement below: the width decides how many
        // tiles there are, and adaptive goes on deciding where they sit.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: ShortcutGridMetrics.columnMinimum), spacing: Theme.Space.md)],
            spacing: Theme.Space.md
        ) {
            ForEach(shortcuts) { item in
                shortcutTile(item)
            }
        }
        .padding(.horizontal, Theme.Metrics.gutter)
        // Measured after the gutters, so the column count is solved against the width the
        // tiles actually get — the same arithmetic `.adaptive` does internally and will not
        // report. Loop-free: the reported width comes from the parent and never depends on
        // the tile count derived from it.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width - 2 * Theme.Metrics.gutter
        } action: { width in
            gridWidth = max(0, width)
        }
    }

    @ViewBuilder
    private func shortcutTile(_ item: HomeShortcut) -> some View {
        switch item.kind {
        case .likedSongs:
            NavigationLink(value: LibraryDestination.liked) {
                ShortcutRow(title: "Liked Songs", imageURL: nil, systemImageFallback: "heart.fill")
            }
            .buttonStyle(.pressableCard)
            .cardHover()
        case .radio(let station):
            NavigationLink(value: LibraryDestination.radio(station.seedTrack)) {
                ShortcutRow(title: station.title, imageURL: station.seedTrack.thumbnailUrl, systemImageFallback: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.pressableCard)
            .cardHover()
            .contextMenu { removeRadioButton(station) }
        case .playlist(let playlist):
            NavigationLink(value: LibraryDestination.playlist(playlist.id)) {
                ShortcutRow(title: playlist.name, imageURL: playlist.tracks.first?.thumbnailUrl, systemImageFallback: "music.note.list")
            }
            .buttonStyle(.pressableCard)
            .cardHover()
        case .album(let album):
            NavigationLink(value: LibraryDestination.album(album)) {
                ShortcutRow(title: album.title, imageURL: album.thumbnailUrl, systemImageFallback: "square.stack")
            }
            .buttonStyle(.pressableCard)
            .cardHover()
            .contextMenu { removeAlbumButton(album) }
        }
    }

    /// Home has no list to swipe, so removing a saved radio is a long press — on the grid tile
    /// and on the shelf card alike, since the same station appears in both.
    private func removeRadioButton(_ station: RadioStation) -> some View {
        Button(role: .destructive) {
            withAnimation { radioHistory.delete(station) }
        } label: {
            Label("Remove Radio", systemImage: "trash")
        }
    }

    /// The album counterpart of `removeRadioButton`. Both grids and both Library sections
    /// offer it, since the same release appears in all of them.
    private func removeAlbumButton(_ album: Album) -> some View {
        Button(role: .destructive) {
            withAnimation { AlbumHistoryStore.shared.delete(album) }
        } label: {
            Label("Remove Album", systemImage: "trash")
        }
    }

    /// Nothing cached and nothing saved — otherwise Home is a daylist card over a void on
    /// a fresh install.
    ///
    /// Asks `rankedShortcuts` rather than `shortcuts`: the latter is empty until the grid has
    /// been measured once, and on the first pass of a fresh launch that would have shown the
    /// "Nothing Here Yet" placeholder to someone with a full library.
    private var hasNothingToShow: Bool {
        sections.isEmpty && rankedShortcuts.isEmpty
            && radioHistory.stations.isEmpty && playlists.playlists.isEmpty
    }

    /// Uses the same time-of-day buckets as the daylist, so the header and the mix card
    /// directly beneath it can't disagree — at 1am this read "Good morning" directly above
    /// a card titled "Saturday Late Night Mix".
    private var greeting: String {
        switch DaylistStore.currentBucket {
        case .morning: return "Good morning"
        case .afternoon: return "Good afternoon"
        case .evening: return "Good evening"
        case .night: return "Good night"
        }
    }

    /// Builds "Because you listened to…" shelves from recent local play history, plus a
    /// generic Quick Picks shelf, mirroring Spotify's mix of personalized and general rows.
    /// Served from `HomeFeedStore`'s cache when it's recent enough, so returning to this
    /// tab isn't worth six network round trips.
    private func load(forceRefresh: Bool = false) async {
        isLoading = feed.sections.isEmpty
        errorMessage = nil
        do {
            _ = forceRefresh ? try await feed.refresh() : try await feed.refreshIfNeeded()
        } catch {
            if feed.sections.isEmpty {
                errorMessage = "Couldn't load Home. Check your connection and try again."
            }
        }
        isLoading = false
    }
}

#if os(macOS)
/// A pointer's answer to `.pressableCard`.
///
/// Press feedback only begins once the mouse is already down, so a cursor could sweep the whole
/// landing screen without one thing acknowledging it — the surest sign of a touch UI that was
/// ported rather than adapted, and why the cards here read as decoration instead of links.
///
/// Brightness rather than a lift or a shadow: these cards sit inside the shelves' horizontal
/// `ScrollView`, which clips anything that grows past their frame, so a hovered card would have
/// had its top and bottom shaved off.
private struct CardHoverHighlight: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .brightness(isHovering ? 0.08 : 0)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { isHovering = $0 }
    }
}
#endif

private extension View {
    /// Nothing on iOS, which has no pointer to answer.
    @ViewBuilder
    func cardHover() -> some View {
        #if os(macOS)
        modifier(CardHoverHighlight())
        #else
        self
        #endif
    }
}
