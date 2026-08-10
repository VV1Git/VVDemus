import AVFoundation
import SwiftUI

struct RootView: View {
    // `@ObservedObject`, not `@StateObject`: this view does not create or own the player,
    // it observes a singleton. `@StateObject` means "I own this", which is untrue here.
    @ObservedObject private var player = PlayerService.shared
    @StateObject private var coordinator = NavigationCoordinator()
    @ObservedObject private var controlServer = LocalControlServer.shared
    /// Watched for the audio-session decision below, which cannot be made from this phone's own
    /// player alone: while the paired device owns the session, this one's `PlayerService` is
    /// empty and its `isPlaying` is false however loudly the Mac is playing.
    @ObservedObject private var peer = PeerPlayback.shared
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
        // Top rather than bottom: the bottom belongs to the tab bar and its accessory, and the
        // system owns the geometry of both.
        .safeAreaInset(edge: .top) { ResumeFromPeerBar() }
        // The Phone-app behaviour: the bar shrinks to a pill as you scroll into content and
        // comes back when you scroll up, so the glass never sits on top of what you're
        // reading. This is the system doing it — there is nothing here to keep in sync.
        .tabBarMinimizeBehavior(.onScrollDown)
        // Where Music puts its mini player. The system owns the glass, the placement and the
        // safe-area inset it costs every scrolling view, which is why `MiniPlayerInset` and the
        // hand-measured `BottomBar` geometry are both gone.
        //
        // `isEnabled:` rather than a conditional inside the closure: the accessory draws its
        // glass capsule whenever the modifier is attached, so returning nothing from the content
        // left an empty pill sitting above the tab bar the whole time the app was idle. The
        // content closure is the wrong lever — by the time it runs, the capsule already exists.
        //
        // And rather than attaching the modifier conditionally, which is the obvious fix and a
        // trap: `if playing { tabs.tabViewBottomAccessory { … } } else { tabs }` gives SwiftUI
        // two different view types, so the whole `TabView` is rebuilt the moment the first song
        // starts — new `UITabBarController`, new hosting controller per tab, every tab's
        // navigation stack and scroll position gone. The visible cost is searching for a song,
        // tapping it, and watching the results vanish. `BottomAccessoryVisibilityTests` holds
        // both halves of this down.
        //
        // Keyed on the *displayed* track, not this device's own: while the paired device owns the
        // session this one's player is deliberately empty, and reading `player.currentTrack` here
        // hid the mini bar — and with it the only route to Now Playing and the queue — for exactly
        // the case the mirroring is for.
        .tabViewBottomAccessory(isEnabled: peer.displayedTrack != nil) {
            MiniPlayerBar(player: player) { showNowPlaying = true }
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView(player: player)
        }
        .task {
            // Started unconditionally. The toggle governs the browser remote, not the link to
            // the paired device — which needs this server to answer pairing and sync at all.
            LocalControlServer.shared.setWebRemoteEnabled(
                UserDefaults.standard.bool(forKey: LocalControlServer.defaultsKey)
            )
            LocalControlServer.shared.start()
            // Downloads now run in a system-owned background session, so some may have
            // been finishing (or finished) while the app wasn't running. Pick their
            // progress back up rather than showing them stalled at zero.
            DownloadManager.shared.resumeInFlightDownloads()
            // After the server, which owns the port being advertised.
            PeerLink.shared.start()
            PeerPlayback.shared.start()
            await PeerLink.shared.refreshResumeOffer()
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
                //
                // The offer, on the other hand, is only ever *worth* refreshing here: its own
                // doc comment says "called on launch and on returning to the foreground", but
                // only the launch half was ever wired up — so picking the phone up after
                // listening on the Mac showed either nothing or whatever the peer had been
                // playing whenever the app last started, which could be days ago.
                Task { await PeerLink.shared.refreshResumeOffer() }
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
        // Handing the session to (or taking it back from) the paired device changes the same
        // thing a device switch does: whether this phone is making any sound of its own.
        .onChange(of: peer.isMirroring) { _, _ in updateBackgroundKeepAlive() }
        // And while it is mirroring, the play/pause that matters is the *owner's*. It never
        // touches anything on this device — it arrives on a poll — so nothing above would notice
        // the Mac being paused, and the phone would sit on an active session (and a silent clip)
        // over music that stopped ten minutes ago, keeping AirPods pinned to it.
        .onChange(of: peer.displayedIsPlaying) { _, _ in updateBackgroundKeepAlive() }
    }

    private func updateBackgroundKeepAlive() {
        let decision = BackgroundAudioPolicy.decide(
            .init(
                isBackgrounded: scenePhase == .background,
                // Playing *anywhere*: this device's own player when it owns the session, the
                // owner's when it does not. See `BackgroundAudioPolicy.Inputs.isPlaying`.
                isPlaying: peer.displayedIsPlaying,
                activeDevice: player.activeDevice,
                isConnectServerRunning: controlServer.isRunning,
                isMirroringPeer: peer.isMirroring
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
