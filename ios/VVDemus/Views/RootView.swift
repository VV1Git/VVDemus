import AVFoundation
import SwiftUI

struct RootView: View {
    @StateObject private var player = PlayerService.shared
    @StateObject private var coordinator = NavigationCoordinator()
    @ObservedObject private var controlServer = LocalControlServer.shared
    @State private var showNowPlaying = false
    @Environment(\.scenePhase) private var scenePhase

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
                    .padding(.bottom, 49)
            }
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView(player: player)
        }
        .task {
            if UserDefaults.standard.bool(forKey: LocalControlServer.defaultsKey) {
                LocalControlServer.shared.start()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                LocalControlServer.shared.applicationDidEnterBackground()
            case .active:
                LocalControlServer.shared.applicationWillEnterForeground()
                try? AVAudioSession.sharedInstance().setActive(true)
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
    }

    private func updateBackgroundKeepAlive() {
        let shouldKeepAlive = scenePhase == .background && controlServer.isRunning && !player.isPlaying
        if shouldKeepAlive {
            BackgroundKeepAlive.shared.start()
        } else {
            BackgroundKeepAlive.shared.stop()
        }
    }
}
