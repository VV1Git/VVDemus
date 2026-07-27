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
        // Handing playback to (or taking it back from) a browser changes whether this
        // phone is making any sound of its own, which is the whole basis of the decision
        // below — and it can happen at any time from the web remote, including while the
        // screen is already locked.
        .onChange(of: player.activeDevice) { _, _ in updateBackgroundKeepAlive() }
    }

    /// iOS only honours the `audio` background mode while the app is *actually* producing
    /// audio. `isPlaying` alone doesn't mean this phone is: while casting it reflects the
    /// browser's playback, reported back over the network, with this phone's own player
    /// paused and silent.
    private var phoneIsProducingAudio: Bool {
        player.isPlaying && player.activeDevice == .iphone
    }

    /// Keeps the process (and so VVDemus Connect's server) alive through a screen lock
    /// whenever nothing else is holding it up.
    ///
    /// This used to key off `!player.isPlaying`, which meant that casting to a computer —
    /// the one situation where the remote connection matters most — looked like "audio is
    /// playing, no need to do anything", while in reality the phone was silent. Locking
    /// the phone then let iOS suspend the app about thirty seconds later, killing the
    /// server, the browser's connection, and the music with it.
    /// While the computer is playing, this phone holds a near-silent audio session purely
    /// to stay alive. The moment playback is paused, that leaves the phone as the only
    /// device making any sound at all — which is precisely the cue AirPods use to decide
    /// you've moved back to it. Pausing on the Mac would pause, and then the AirPods would
    /// hop to the phone.
    ///
    /// So when the computer is the active device and nothing is playing, the phone lets
    /// the audio route go entirely. Nothing is playing anywhere, so it has no business
    /// claiming it.
    private var shouldHoldAudioSession: Bool {
        if player.activeDevice == .computer && !player.isPlaying { return false }
        return !phoneIsProducingAudio
    }

    private func updateBackgroundKeepAlive() {
        let shouldKeepAlive = scenePhase == .background && controlServer.isRunning && shouldHoldAudioSession
        if shouldKeepAlive {
            BackgroundKeepAlive.shared.start()
        } else {
            // Releasing the session (rather than merely stopping the clip) is what actually
            // hands the route back — a still-active session keeps the phone in the running
            // as far as automatic switching is concerned. Only safe because this branch
            // means the phone isn't playing anything of its own.
            BackgroundKeepAlive.shared.stop(releasingSession: !phoneIsProducingAudio)
            // Buys a fresh window of life for the server now that audio isn't holding it
            // up, so pausing doesn't immediately cost the remote its connection.
            if scenePhase == .background { controlServer.renewBackgroundTask() }
        }
    }
}
