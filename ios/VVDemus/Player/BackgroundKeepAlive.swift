import AVFoundation

/// Loops a bundled, nearly-inaudible (not exactly silent) audio clip while the app is
/// backgrounded and this phone isn't otherwise producing sound, so the
/// `UIBackgroundModes: audio` entitlement (which iOS only honors while audio is genuinely
/// playing) keeps the process — and VVDemus Connect's embedded server — alive through a
/// screen lock instead of being suspended after ~30s.
/// This is a well-known technique, not a documented Apple guarantee: iOS can still
/// eventually suspend a long-idle backgrounded app, and it has a small but real battery
/// cost while active, so it's only started when actually needed and stopped the moment
/// the app returns to the foreground or this phone's own playback resumes.
///
/// Deliberately **not** true digital silence, and **not** `volume = 0`: iOS has been
/// observed to detect exact-silence background-audio loops specifically (the well-known
/// abuse pattern this trick otherwise resembles) and suspend the app anyway. The bundled
/// clip (`silence.m4a`) is a real, very quiet 20Hz tone (~-60dB), and playback volume is
/// kept just above zero, so this reads as genuine (if faint) audio output rather than a
/// no-op loop.
@MainActor
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    private var player: AVAudioPlayer?
    /// What the app *wants*, as opposed to what's currently playing. Anything that stops
    /// the clip behind our back (an interruption, media services restarting) is recovered
    /// from by consulting this rather than by assuming the clip is still running.
    private var shouldBeRunning = false
    private var observersRegistered = false

    private init() {}

    func start() {
        shouldBeRunning = true
        registerObserversIfNeeded()
        startPlayer()
    }

    func stop() {
        shouldBeRunning = false
        player?.stop()
        player = nil
    }

    var isRunning: Bool { player?.isPlaying ?? false }

    private func startPlayer() {
        guard shouldBeRunning, player == nil,
              let url = Bundle.main.url(forResource: "silence", withExtension: "m4a") else { return }
        // The session can have been deactivated while the app sat paused in the
        // background; without reactivating it here `play()` silently does nothing and the
        // app is suspended anyway.
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let audioPlayer = try? AVAudioPlayer(contentsOf: url) else { return }
        audioPlayer.numberOfLoops = -1
        audioPlayer.volume = 0.01
        guard audioPlayer.play() else {
            NSLog("[BackgroundKeepAlive] failed to start — the app may be suspended on lock")
            return
        }
        player = audioPlayer
        NSLog("[BackgroundKeepAlive] started")
    }

    // MARK: - Recovering from things that stop us

    /// A phone call, an alarm, Siri, or another app taking over audio interrupts the
    /// session and stops this clip. Nothing restarted it afterwards, so the app lost its
    /// hold on the background-audio entitlement and was suspended a few seconds later —
    /// the connection dropping some minutes after locking the phone, with no obvious
    /// cause. Media services resetting (rare, but it does happen) had the same effect.
    private func registerObserversIfNeeded() {
        guard !observersRegistered else { return }
        observersRegistered = true

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.handleInterruption(notification) }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSLog("[BackgroundKeepAlive] media services reset — rebuilding")
                self.player = nil
                self.startPlayer()
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // The clip is already stopped by the system; drop our reference so the
            // resume path builds a fresh player.
            player = nil
        case .ended:
            NSLog("[BackgroundKeepAlive] interruption ended — restarting")
            startPlayer()
        @unknown default:
            break
        }
    }
}
