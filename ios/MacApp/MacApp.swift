import AVFoundation
import SwiftUI

@main
struct MacApp: App {
    init() {
        // No `AVAudioSession` here, and nothing standing in for it: a Mac app does not
        // negotiate for the output route, so there is no category to set and no session to
        // activate. `SystemAudioSession` is a no-op on this platform for the same reason.
        //
        // No `beginReceivingRemoteControlEvents` either — that is a `UIApplication` call.
        // `MPRemoteCommandCenter` alone is what puts this app in Now Playing and wires the
        // keyboard's media keys to it, and `PlayerService` already registers its handlers
        // through `SystemRemoteCommandCenter`.
        UserDefaults.standard.register(defaults: [LocalControlServer.defaultsKey: true])
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1100, height: 720)
    }
}
