import AVFoundation

/// Loops a bundled, nearly-inaudible (not exactly silent) audio clip while the app is
/// backgrounded and paused, so the `UIBackgroundModes: audio` entitlement (which iOS only
/// honors while audio is genuinely playing) keeps the process — and VVDemus Connect's
/// embedded server — alive through a screen lock instead of being suspended after ~30s.
/// This is a well-known technique, not a documented Apple guarantee: iOS can still
/// eventually suspend a long-idle backgrounded app, and it has a small but real battery
/// cost while active, so it's only started when actually needed and stopped the moment
/// the app returns to the foreground or playback resumes.
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

    private init() {}

    func start() {
        guard player == nil, let url = Bundle.main.url(forResource: "silence", withExtension: "m4a") else { return }
        guard let audioPlayer = try? AVAudioPlayer(contentsOf: url) else { return }
        audioPlayer.numberOfLoops = -1
        audioPlayer.volume = 0.01
        audioPlayer.play()
        player = audioPlayer
    }

    var isRunning: Bool { player != nil }

    func stop() {
        player?.stop()
        player = nil
    }
}
