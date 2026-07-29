import AVFoundation
import SwiftUI

struct RootView: View {
    // `@ObservedObject`, not `@StateObject`: this view does not create or own the player,
    // it observes a singleton. `@StateObject` means "I own this", which is untrue here.
    @ObservedObject private var player = PlayerService.shared
    @StateObject private var coordinator = NavigationCoordinator()
    @ObservedObject private var controlServer = LocalControlServer.shared
    @State private var showNowPlaying = false
    /// Height of the mini player, exported so each tab can inset its own content by it.
    /// Without the inset the bar simply covers the last row of every list — it's an
    /// overlay, so nothing underneath knows it's there.
    static let miniPlayerHeight: CGFloat = 56
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// The system tab bar is shorter in compact height (landscape iPhone).
    private var tabBarHeight: CGFloat { verticalSizeClass == .compact ? 32 : 49 }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $coordinator.selectedTab) {
                HomeView(player: player, coordinator: coordinator)
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(Tab.home)

                SearchView(player: player, coordinator: coordinator)
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(Tab.search)

                LibraryView(player: player)
                    .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                    .tag(Tab.library)
            }
            .tint(Theme.accent)

            if player.currentTrack != nil {
                MiniPlayerBar(player: player) { showNowPlaying = true }
                    // Sits directly above the tab bar. The height is read from the safe
                    // area rather than hardcoded to 49 — that constant is the portrait tab
                    // bar, and in landscape the real one is shorter, leaving the bar
                    // floating in mid-air.
                    .padding(.bottom, tabBarHeight)
            }
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView(player: player)
        }
        .task {
            if UserDefaults.standard.bool(forKey: LocalControlServer.defaultsKey) {
                LocalControlServer.shared.start()
            }
            // Downloads now run in a system-owned background session, so some may have
            // been finishing (or finished) while the app wasn't running. Pick their
            // progress back up rather than showing them stalled at zero.
            DownloadManager.shared.resumeInFlightDownloads()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                LocalControlServer.shared.applicationDidEnterBackground()
            case .active:
                LocalControlServer.shared.applicationWillEnterForeground()
                // Deliberately does not reactivate the audio session. Foregrounding the
                // app to browse shouldn't stop the podcast the user is listening to; the
                // session is claimed when playback actually starts.
            default:
                break
            }
            updateBackgroundKeepAlive()
        }
        // Real playback pausing *while already backgrounded* (e.g. from the lock-screen
        // controls) doesn't change scenePhase at all, so relying on that alone left a gap:
        // the silent keep-alive would never start for a pause that happens after
        // backgrounding, and the server would still go dark ~30s later. Watching isPlaying
        // (and isRunning, in case Connect gets toggled off while backgrounded) directly
        // closes that gap.
        .onChange(of: player.isPlaying) { _, _ in updateBackgroundKeepAlive() }
        .onChange(of: controlServer.isRunning) { _, _ in updateBackgroundKeepAlive() }
        // Handing playback to (or taking it back from) a browser changes whether this
        // phone is making any sound of its own, which is the whole basis of the decision
        // below — and it can happen at any time from the web remote, including while the
        // screen is already locked.
        .onChange(of: player.activeDevice) { _, _ in updateBackgroundKeepAlive() }
    }

    private func updateBackgroundKeepAlive() {
        let decision = BackgroundAudioPolicy.decide(
            .init(
                isBackgrounded: scenePhase == .background,
                isPlaying: player.isPlaying,
                activeDevice: player.activeDevice,
                isConnectServerRunning: controlServer.isRunning
            )
        )
        if decision.runKeepAlive {
            BackgroundKeepAlive.shared.start()
        } else {
            BackgroundKeepAlive.shared.stop(releasingSession: decision.releaseSession)
            // Buys a fresh window of life for the server now that audio isn't holding it
            // up, so pausing doesn't immediately cost the remote its connection.
            if scenePhase == .background { controlServer.renewBackgroundTask() }
        }
    }
}
