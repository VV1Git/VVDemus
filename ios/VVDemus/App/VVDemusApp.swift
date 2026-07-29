import SwiftUI
import AVFoundation
import UIKit

@main
struct VVDemusApp: App {
    init() {
        // Category only. Activating the session here took the audio route the instant the
        // app launched, which cut off whatever podcast or music app was already playing —
        // before this app had played a note. `.playback` is not a mixable category, so
        // activation is claimed at the point playback actually starts instead (see
        // `PlayerService.attach` / `togglePlayPause`).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
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
        // iOS relaunches the app in the background purely to hand back completed downloads.
        // Not answering costs the app its background-download privileges, which is the
        // whole point of using a background session.
        .backgroundTask(.urlSession(DownloadManager.backgroundSessionIdentifier)) {
            await MainActor.run { DownloadManager.shared.resumeInFlightDownloads() }
        }
    }
}
