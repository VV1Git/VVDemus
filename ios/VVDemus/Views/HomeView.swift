import SwiftUI

private enum ShortcutItem: Identifiable {
    case likedSongs
    case radio(RadioStation)
    case playlist(Playlist)

    var id: String {
        switch self {
        case .likedSongs: return "liked"
        case .radio(let station): return "radio-\(station.id)"
        case .playlist(let playlist): return "playlist-\(playlist.id)"
        }
    }
}

struct HomeView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject var coordinator: NavigationCoordinator
    @ObservedObject private var history = PlayHistoryStore.shared
    @ObservedObject private var liked = LikedSongsStore.shared
    @ObservedObject private var radioHistory = RadioHistoryStore.shared
    @ObservedObject private var playlists = PlaylistStore.shared
    @ObservedObject private var daylist = DaylistStore.shared
    @ObservedObject private var network = NetworkMonitor.shared
    @ObservedObject private var feed = HomeFeedStore.shared
    @State private var isLoading = false
    @State private var errorMessage: String?

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
            .background(Theme.background)
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
            .environment(\.openRadio) { track in coordinator.homePath.append(LibraryDestination.radio(track)) }
        }
        .task { await load() }
        .task { await daylist.refreshIfNeeded() }
        .refreshable { await load(forceRefresh: true) }
    }

    // MARK: - Shortcuts grid (Liked Songs, saved radios, playlists)

    private var shortcuts: [ShortcutItem] {
        var items: [ShortcutItem] = []
        if !liked.tracks.isEmpty { items.append(.likedSongs) }
        items.append(contentsOf: radioHistory.stations.prefix(6).map(ShortcutItem.radio))
        items.append(contentsOf: playlists.playlists.prefix(6).map(ShortcutItem.playlist))
        // On a phone — two columns — an odd count leaves a half-width hole at the end, so trim
        // to an even one, except for a lone shortcut, which would otherwise vanish from Home.
        // A wider window fits more columns and a ragged last row there is ordinary; this is
        // the phone case, which is the one that looked broken.
        let capped = Array(items.prefix(8))
        guard capped.count > 1 else { return capped }
        return Array(capped.prefix(capped.count - capped.count % 2))
    }

    /// The widest minimum that still leaves two columns on the narrowest supported phone: 375pt
    /// less the gutters is 343, so two columns come out 165 wide. Anything larger and those
    /// phones drop to a single full-width tile.
    private static let shortcutColumnMinimum: CGFloat = 160

    private var shortcutGrid: some View {
        LazyVGrid(
            // `.adaptive`, not two `.flexible()` columns: a fixed pair is a phone measurement,
            // and on a Mac it stretched two tiles of 56pt artwork across the whole window
            // however wide it was pulled. This holds the tile size and adds columns instead.
            columns: [GridItem(.adaptive(minimum: Self.shortcutColumnMinimum), spacing: Theme.Space.md)],
            spacing: Theme.Space.md
        ) {
            ForEach(shortcuts) { item in
                shortcutTile(item)
            }
        }
        .padding(.horizontal, Theme.Metrics.gutter)
    }

    @ViewBuilder
    private func shortcutTile(_ item: ShortcutItem) -> some View {
        switch item {
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

    /// Nothing cached and nothing saved — otherwise Home is a daylist card over a void on
    /// a fresh install.
    private var hasNothingToShow: Bool {
        sections.isEmpty && shortcuts.isEmpty
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
