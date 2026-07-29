import Foundation

/// Decides what to do with the audio session and the background keep-alive clip.
///
/// Extracted from the view because getting it wrong is silent and severe, and it has been
/// wrong twice. A paused music app that deactivates its audio session **surrenders the Now
/// Playing slot** — after which AirPods presses, lock-screen buttons and Control Centre all
/// go somewhere else entirely. The symptom is asymmetric and confusing: pause works (the app
/// still held the session at that instant), and then play does nothing, because the press
/// never reaches the app at all.
enum BackgroundAudioPolicy {
    struct Inputs {
        var isBackgrounded: Bool
        var isPlaying: Bool
        var activeDevice: PlaybackDevice
        var isConnectServerRunning: Bool

        /// Whether this phone is the thing actually making sound. While casting, `isPlaying`
        /// describes the browser, and this phone's own player is silent.
        var phoneIsProducingAudio: Bool { isPlaying && activeDevice == .iphone }
    }

    struct Decision: Equatable {
        /// Run the near-silent clip that keeps the process (and Connect's server) alive
        /// through a screen lock.
        var runKeepAlive: Bool
        /// Deactivate the audio session, handing the output route back to whatever else
        /// wants it.
        var releaseSession: Bool
    }

    static func decide(_ input: Inputs) -> Decision {
        // Only while a browser is the active device.
        //
        // It used to run for any backgrounded pause, so pausing on AirPods started a silent
        // looping clip through a second `AVAudioPlayer` — the system saw that as this app's
        // audio, sitting between the AirPods and the real player. A paused music app should
        // simply keep its session and let iOS suspend it; a remote command wakes it again.
        // The clip is for the one case where this phone is deliberately silent while
        // something else is playing, and that is casting.
        let runKeepAlive = input.isBackgrounded
            && input.isConnectServerRunning
            && input.activeDevice == .computer

        // Released in exactly one situation: a browser is the active device and nothing is
        // playing anywhere, so this phone has no business holding the route — that is what
        // lets AirPods follow the Mac.
        //
        // Deliberately NOT released for an ordinary pause. It used to be, and that is what
        // broke resuming from AirPods: pausing with the screen locked deactivated the
        // session, the app lost the Now Playing slot, and the next press went nowhere.
        let releaseSession = input.isBackgrounded
            && input.activeDevice == .computer
            && !input.isPlaying

        return Decision(runKeepAlive: runKeepAlive && !releaseSession, releaseSession: releaseSession)
    }
}
