import AVFoundation
import SwiftUI

struct RootView: View {
    // `@ObservedObject`, not `@StateObject`: this view does not create or own the player,
    // it observes a singleton. `@StateObject` means "I own this", which is untrue here.
    @ObservedObject private var player = PlayerService.shared
    @StateObject private var coordinator = NavigationCoordinator()
    @ObservedObject private var controlServer = LocalControlServer.shared
    @State private var showNowPlaying = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $coordinator.selectedTab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView(player: player, coordinator: coordinator)
            }

            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                SearchView(player: player, coordinator: coordinator)
            }

            Tab("Library", systemImage: "books.vertical.fill", value: AppTab.library) {
                LibraryView(player: player)
            }
        }
        .tint(Theme.accent)
        // The Phone-app behaviour: the bar shrinks to a pill as you scroll into content and
        // comes back when you scroll up, so the glass never sits on top of what you're
        // reading. This is the system doing it — there is nothing here to keep in sync.
        .tabBarMinimizeBehavior(.onScrollDown)
        // Where Music puts its mini player. The system owns the glass, the placement and the
        // safe-area inset it costs every scrolling view, which is why `MiniPlayerInset` and
        // the hand-measured `BottomBar` geometry are both gone.
        .tabViewBottomAccessory {
            if player.currentTrack != nil {
                MiniPlayerBar(player: player) { showNowPlaying = true }
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
