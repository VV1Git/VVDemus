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
        /// Whether anything is playing *anywhere* — this phone, the browser it is casting to, or
        /// the paired device that owns the session. On a mirror this phone's own `isPlaying` is
        /// false and stays false (its player is empty), so the caller has to answer for the owner
        /// or the session would be released out from under music that is still going.
        var isPlaying: Bool
        var activeDevice: PlaybackDevice
        var isConnectServerRunning: Bool
        /// Whether the paired device owns the session, so this one is a silent mirror of it.
        ///
        /// The same situation as casting, arrived at from the other end of the link: something
        /// else is making the sound and this phone is only showing it and relaying presses.
        /// Defaulted so the callers that predate pairing keep describing what they always meant.
        var isMirroringPeer: Bool = false
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
        // The one thing both special cases have in common: this phone is deliberately making no
        // sound while something else is. A browser it is casting to, or the paired device that
        // owns the session — the phone's audio session has the same job in both, which is to
        // hold the process (and the Now Playing slot) up for a device that cannot do either.
        let soundIsElsewhere = input.activeDevice == .computer || input.isMirroringPeer

        // Only in that state, and never for an ordinary pause.
        //
        // The clip used to run for any backgrounded pause, so pausing on AirPods started a silent
        // looping clip through a second `AVAudioPlayer` — the system saw that as this app's
        // audio, sitting between the AirPods and the real player. A paused music app should
        // simply keep its session and let iOS suspend it; a remote command wakes it again.
        let runKeepAlive = input.isBackgrounded
            && input.isConnectServerRunning
            && soundIsElsewhere

        // Released in exactly one situation: the sound is somewhere else *and* it has stopped, so
        // this phone has no business holding the route — that is what lets AirPods follow the Mac.
        // A near-silent session on the phone is the exact cue iOS uses to decide you have moved
        // back to it, so keeping one up over a paused Mac drags the earbuds back across the room.
        //
        // Deliberately NOT released for an ordinary pause of this phone's own playback. It used to
        // be, and that is what broke resuming from AirPods: pausing with the screen locked
        // deactivated the session, the app lost the Now Playing slot, and the next press went
        // nowhere.
        let releaseSession = input.isBackgrounded
            && soundIsElsewhere
            && !input.isPlaying

        return Decision(runKeepAlive: runKeepAlive && !releaseSession, releaseSession: releaseSession)
    }
}
