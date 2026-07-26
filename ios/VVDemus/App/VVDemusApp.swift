import SwiftUI
import AVFoundation
import UIKit

@main
struct VVDemusApp: App {
    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        MemoryDiagnostics.startLogging()
        // VVDemus Connect is on by default — this only sets the *default* the very first
        // time the key is read; once the user has an explicit preference (via the Library
        // toggle), that's what's honored on every later launch.
        UserDefaults.standard.register(defaults: [LocalControlServer.defaultsKey: true])
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}
