import SwiftUI

/// What the sidebar can select.
///
/// The phone reaches Liked Songs, Downloads and the rest by pushing onto Library's navigation
/// stack, because three tabs is all a tab bar should carry. A sidebar has room to name them
/// outright, so they are peers here — reusing `LibraryDestination` rather than a parallel enum,
/// so there is still exactly one place a destination becomes a screen.
private enum MacSection: Hashable {
    case home
    case search
    case library
    case destination(LibraryDestination)
}

/// The Mac's window shell — the counterpart to `RootView`, which cannot be shared: it is built
/// on `TabView` with iOS-26-only tab-bar API (`tabBarMinimizeBehavior`,
/// `tabViewBottomAccessory`) that has no macOS equivalent, and a Mac window wants a sidebar
/// anyway. Everything below the shell is the same code the phone runs.
struct MacRootView: View {
    @ObservedObject private var player = PlayerService.shared
    @StateObject private var coordinator = NavigationCoordinator()
    @ObservedObject private var playlists = PlaylistStore.shared
    @ObservedObject private var radioHistory = RadioHistoryStore.shared
    @ObservedObject private var albumHistory = AlbumHistoryStore.shared
    @ObservedObject private var link = PeerLink.shared
    @State private var selection: MacSection? = .home
    /// The push stack for whichever leaf screen the sidebar has selected. One path shared by
    /// all of them, held here rather than inside the `detail` branch so it survives that
    /// branch being torn down when you visit Home and comes back empty — see the reset in
    /// `onChange(of: selection)`.
    @State private var leafPath = NavigationPath()
    /// The queue panel's visibility. The full-screen Now Playing sheet it replaced is gone: a
    /// window has room to show the queue beside the content, and a modal over everything was the
    /// phone's compromise, not the desktop's.
    @State private var showQueue = false
    /// Measured, not guessed. The bar's height is three stacked children, two of which come and
    /// go (`PlaybackErrorBar`, `ResumeFromPeerBar`), so a constant would be wrong exactly when an
    /// error is showing — the moment the content underneath most needs to be readable.
    @State private var transportHeight: CGFloat = 0

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            // The queue sits beside the content rather than over it, so it can stay open
            // while you keep browsing — the reason it is a panel and not a sheet.
            HStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // No `safeAreaInset` here any more, and no `contentMargins` before it.
                    // Each screen carries its own clearance instead — see `TransportClearance`.
                    //
                    // The inset that used to sit here reached the *root* of the detail column's
                    // navigation stack and nothing pushed onto it, so every screen reached from
                    // the sidebar looked right while every screen navigated into kept its last
                    // row under the bar. Go to Radio on any track row was the common way in.
                if showQueue {
                    Divider()
                    MacQueuePanel(isShown: $showQueue)
                        .transition(.move(edge: .trailing))
                }
            }
            // The pane's own ground, so a screen that does not paint one — or paints one
            // sized to its content — shows black rather than the window's default grey.
            // Individual screens still set it; this is what stops the next one that forgets.
            .background(Theme.background)
        }
        // Attached to the split view, not returned from `detail:`, which is where these three
        // used to sit as VStack siblings. Two reasons, and only the first is visible today.
        //
        // "Pinned to the bottom of the window" has to mean the whole width: inside `detail:` the
        // transport began where the sidebar ended, and the sidebar ran past it to the window's
        // bottom edge. And a `detail:` closure is *inside* the navigable region — a
        // `NavigationLink(value:)` carrying a type no inner stack registers is taken by the split
        // view's own detail-column stack, which replaces that closure entire, bars included.
        // Every link in the app carries a `LibraryDestination` today and all four leaf stacks
        // register one (HomeView, SearchView, LibraryView, and `detail` below), so nothing trips
        // it yet; the next destination type added would, and the symptom is the transport
        // vanishing on one screen with nothing on that screen to connect it to.
        //
        // A `safeAreaInset` rather than a `VStack` wrapped around the split view, so the split
        // view stays the window's root and goes on hoisting its toolbar into the titlebar —
        // Home's Refresh and `PeerStatusIndicator` live there — along with the sidebar-collapse
        // control.
        //
        // What an inset on a split view does *not* do is reach either column's scroll content.
        // This was previously claimed to work; it does not. Both columns went on scrolling to
        // the window's bottom edge and the bar sat over them — the last few tracks of a playlist
        // were unreachable, and in the sidebar it was Settings, the permanently-last row, so it
        // was covered no matter how far you scrolled. Hence the measured height above: the inset
        // positions the bar, and each column keeps its own content out from under it.
        //
        // Both columns now do that the same way, after two attempts to do it from out here
        // each failed on a different screen. `contentMargins(for: .scrollContent)` is silently
        // dropped by the table-backed sidebar `List` on macOS. `safeAreaInset` survives that,
        // but only reaches the *root* of a `NavigationStack` — so the detail column was correct
        // on every screen selected in the sidebar and wrong on every screen pushed onto it.
        //
        // So neither is used for clearance any more. Every scrolling screen in the window
        // carries its own, as a real row or real padding, sized from the height measured below.
        // See `TransportClearance`.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // The Mac's only surface for `player.errorMessage`. It is rendered on the phone by
                // `NowPlayingView`, which is presented from `RootView` — a file the Mac target
                // excludes — so until this was mounted a stream that failed here stopped the
                // music and said nothing at all.
                PlaybackErrorBar(player: player)
                // Choosing the other device in the picker and having nothing happen reads as a
                // dead control. It was not dead — the failure was landing in a field nothing on
                // this platform renders.
                if let handoffError = link.handoffError {
                    Text(handoffError)
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Metrics.gutter)
                        .padding(.vertical, Theme.Space.xs)
                }
                ResumeFromPeerBar()
                MacNowPlayingBar(player: player, showQueue: $showQueue)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                transportHeight = $0
                // Every scrolling screen in the window reads this to size its own clearance.
                TransportMetrics.shared.height = $0
            }
        }
        .tint(Theme.accent)
        // Every leaf screen pushes onto the same stack, so a radio opened under Liked Songs
        // was still sitting on top of Downloads when you clicked it.
        .onChange(of: selection) { _, _ in
            leafPath = NavigationPath()
        }
        .task {
            // Started unconditionally. The toggle governs the browser remote, not the link to
            // the paired device — which needs this server to answer pairing and sync at all.
            LocalControlServer.shared.setWebRemoteEnabled(
                UserDefaults.standard.bool(forKey: LocalControlServer.defaultsKey)
            )
            LocalControlServer.shared.start()
            DownloadManager.shared.resumeInFlightDownloads()
            // After the server, which owns the port being advertised.
            PeerLink.shared.start()
            PeerPlayback.shared.start()
            await PeerLink.shared.refreshResumeOffer()
        }
    }

    /// Rows are `NavigationLink(value:)` rather than `Label(...).tag(...)` because that is the
    /// pairing Apple documents for a `NavigationSplitView` sidebar: the link supplies both the
    /// selection value and the row's activation behaviour.
    ///
    /// (The tagged form may well work too — it was swapped out while chasing what turned out
    /// to be a test-harness problem, not a SwiftUI one, so it is untested here rather than
    /// known-broken.)
    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                row(.home, "Home", "house.fill")
                row(.search, "Search", "magnifyingglass")
                row(.library, "Library", "books.vertical.fill")
            }

            Section("Your Music") {
                row(.destination(.liked), "Liked Songs", "heart.fill")
                row(.destination(.daylist), "Daylist", "sun.max.fill")
                row(.destination(.downloads), "Downloads", "arrow.down.circle.fill")
                row(.destination(.stats), "Your Stats", "chart.bar.fill")
            }

            if !playlists.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(playlists.playlists) { playlist in
                        row(.destination(.playlist(playlist.id)), playlist.name, "music.note.list")
                            .contextMenu {
                                DownloadToPhoneButton(tracks: playlist.tracks)
                                Divider()
                                Button("Delete Playlist", role: .destructive) {
                                    // Selection would otherwise point at a screen that no longer
                                    // exists, leaving the detail pane on a deleted playlist.
                                    if selection == .destination(.playlist(playlist.id)) {
                                        selection = .home
                                    }
                                    playlists.delete(playlist)
                                }
                            }
                    }
                }
            }

            if !albumHistory.albums.isEmpty {
                Section("Albums") {
                    ForEach(albumHistory.albums) { album in
                        row(.destination(.album(album)), album.title, "square.stack")
                            .contextMenu {
                                DownloadToPhoneButton(tracks: AlbumCacheStore.shared.tracks(for: album.browseId) ?? [])
                                Divider()
                                Button("Remove Album", role: .destructive) {
                                    // Selection would otherwise point at a screen that is no
                                    // longer reachable from the sidebar showing it.
                                    if selection == .destination(.album(album)) {
                                        selection = .home
                                    }
                                    albumHistory.delete(album)
                                }
                            }
                    }
                }
            }

            if !radioHistory.stations.isEmpty {
                Section("Your Radio") {
                    ForEach(radioHistory.stations) { station in
                        row(.destination(.radio(station.seedTrack)),
                            station.title,
                            "dot.radiowaves.left.and.right")
                            .contextMenu {
                                DownloadToPhoneButton(tracks: RadioCacheStore.shared.tracks(for: station.id) ?? [])
                                Divider()
                                Button("Remove Radio", role: .destructive) {
                                    if selection == .destination(.radio(station.seedTrack)) {
                                        selection = .home
                                    }
                                    radioHistory.delete(station)
                                }
                            }
                    }
                }
            }

            Section {
                row(.destination(.settings), "Settings", "gearshape.fill")
            }

            TransportClearanceRow()
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }

    private func row(_ section: MacSection, _ title: String, _ icon: String) -> some View {
        NavigationLink(value: section) {
            Label(title, systemImage: icon)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .home, nil:
            // These three bring their own `NavigationStack`, so they drop into the detail
            // column as they are.
            HomeView(player: player, coordinator: coordinator)
        case .search:
            SearchView(player: player, coordinator: coordinator)
        case .library:
            LibraryView(player: player)
        case .destination(let target):
            // The leaf screens are written to be *pushed*, so they carry no stack of their own
            // — one is supplied here, along with the same `navigationDestination` the phone's
            // stacks register, so pushing onward (a track's radio, say) still works.
            NavigationStack(path: $leafPath) {
                target.destination(player: player)
                    .navigationDestination(for: LibraryDestination.self) { pushed in
                        pushed.destination(player: player)
                    }
            }
            // On the stack, not on the screen inside it.
            //
            // The measured symptom: "Go to Radio" works on whatever the sidebar has selected
            // and is dead one push in. On a radio opened from Home, or a track inside an album
            // opened from Library, the item runs `openRadio`'s default — a closure that does
            // nothing — so the menu item is there, highlights, and goes nowhere.
            //
            // This was written one line further in, on the root screen, with a comment claiming
            // that being outside the `navigationDestination` was enough for pushed screens to
            // inherit it. Whatever else is true, that claim is not: the root screen got the
            // value and the pushed one did not. A destination is built *for the stack*, so
            // anything written below the stack is the wrong side of it — the same hoisting
            // `QueueView` documents for toolbar items, one modifier over. Hence here.
            //
            // Not yet confirmed on a pushed screen: this is the placement the framework
            // documents, but the clearance note in `detail:` above found the pushed screen is
            // not laid out inside this closure either, and if the split view's own stack is
            // taking the push then this environment does not reach it and the fix is elsewhere.
            .environment(\.openRadio) { leafPath.append(LibraryDestination.radio($0)) }
        }
    }
}
