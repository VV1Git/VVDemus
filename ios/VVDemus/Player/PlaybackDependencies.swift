import AVFoundation
import Foundation
import MediaPlayer

/// The seams `PlayerService` reaches the outside world through.
///
/// Everything here exists because the behaviour that matters most in this app — what
/// happens when AirPods disconnect mid-song, when a call interrupts playback, when the
/// screen locks, when playback moves between the phone and a browser — is exactly the
/// behaviour that cannot be exercised against real `AVPlayer`/`AVAudioSession`/
/// `MPRemoteCommandCenter` objects in a test. Each protocol has one adapter that forwards
/// to the real framework type (used by `PlayerService.shared`) and one fake in the test
/// target.

// MARK: - Playback engine

/// The subset of `AVPlayer` that `PlayerService` actually drives.
@MainActor
protocol PlaybackEngine: AnyObject {
    var currentTimeSeconds: Double { get }
    var itemDurationSeconds: Double? { get }
    /// Whether the engine is actually producing audio, as opposed to what the app last
    /// asked it to do. These diverge whenever something outside the app stops playback:
    /// an interruption, a route change, a stall, a failed item.
    var isEnginePlaying: Bool { get }

    /// Attenuation applied *under* the system volume, 0...1 — the hardware buttons keep
    /// doing exactly what they did, this only ever quietens what they set.
    ///
    /// A property of the engine rather than an argument to `replaceItem`, because it
    /// outlives any one item: every track plays at whatever level was last set.
    ///
    /// It does *not* survive `rebuild()` — a fresh `AVPlayer` starts at 1.0 — so
    /// `PlayerService`, which owns the stored level, puts it back after a reset.
    var volume: Double { get set }

    func rebuild()
    func replaceItem(url: URL, forwardBufferDuration: TimeInterval)
    /// Lets go of the current item entirely, leaving the engine with nothing loaded.
    ///
    /// Distinct from `pause()`: a paused engine still holds a decoded item, still reports a
    /// duration, and still resumes on the next `play()`. Handing the session to the paired device
    /// has to leave nothing behind for a stray press to restart.
    func detach()
    func play()
    func pause()
    func seek(to seconds: Double)

    /// Fired on the main actor when the current item plays to its end.
    var onItemDidPlayToEnd: (() -> Void)? { get set }
    /// Fired on the main actor when the current item fails (an expired stream URL is the
    /// common case — YouTube's URLs are time-limited and a 403 surfaces here).
    var onItemFailed: ((Error?) -> Void)? { get set }
    /// Fired on the main actor roughly twice a second while an item is attached.
    var onPeriodicTime: ((Double) -> Void)? { get set }
    /// Where forward playback must stop, so `onItemDidPlayToEnd` arrives at the real end of
    /// the audio rather than at the end of a timeline that cannot be true. `nil` plays the
    /// item to its own end, which is the default and right for every well-formed file.
    ///
    /// Needed because AVFoundation reports exactly twice the real length for YouTube's
    /// audio-only MP4s (see `PlayerService.trimmedPlaybackEnd`), and the queue advances on
    /// nothing but the engine saying the item finished.
    var forwardPlaybackEndTime: Double? { get set }

    /// Whether the engine wants to play but has run dry — as opposed to the ordinary
    /// buffering that starts every track. `.waitingToPlayAtSpecifiedRate` covers both, so
    /// this is what tells them apart.
    var isStalled: Bool { get }
    /// Fired on the main actor when playback runs out of buffered data.
    var onStalled: (() -> Void)? { get set }
}

/// `AVPlayer`-backed engine used by the running app.
@MainActor
final class AVPlaybackEngine: PlaybackEngine {
    private var player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    /// Must be retained for as long as its asset is in use — `AVAssetResourceLoader` does
    /// not keep a strong reference to its own delegate.
    private var activeResourceLoader: StreamingResourceLoader?

    var onItemDidPlayToEnd: (() -> Void)?
    var onItemFailed: ((Error?) -> Void)?
    var onPeriodicTime: ((Double) -> Void)?
    /// AVFoundation noticed playback ran out of buffered data.
    var onStalled: (() -> Void)?

    /// Incremented on every `replaceItem`. A failure is reported at most once per attached
    /// item: `AVPlayerItem.status == .failed` and `AVPlayerItemFailedToPlayToEndTime` both
    /// fire for the same dead item, and reporting twice made the second call take the
    /// "already retried" path — showing "Couldn't play…" over a retry that then succeeded,
    /// leaving an error on screen under audible music.
    private var attachGeneration = 0
    private var reportedFailureGeneration: Int?

    private func reportFailure(_ error: Error?, generation: Int) {
        guard generation == attachGeneration, reportedFailureGeneration != generation else { return }
        reportedFailureGeneration = generation
        onItemFailed?(error)
    }

    init() {
        installTimeObserver()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
    }

    var currentTimeSeconds: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    var itemDurationSeconds: Double? {
        guard let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    /// Set on the item rather than remembered here, so it survives nothing: a new item starts
    /// with no limit, which is what `replaceItem` should mean.
    var forwardPlaybackEndTime: Double? {
        get {
            guard let end = player.currentItem?.forwardPlaybackEndTime,
                  end.isValid, end.seconds.isFinite else { return nil }
            return end.seconds
        }
        set {
            guard let item = player.currentItem else { return }
            // `.invalid` is AVFoundation's "no limit", not a zero-length one.
            item.forwardPlaybackEndTime = newValue
                .map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .invalid
        }
    }

    /// True unless the player is genuinely stopped.
    ///
    /// `timeControlStatus` has three values, not two: `.paused`, `.playing`, and
    /// `.waitingToPlayAtSpecifiedRate` — which is where AVPlayer sits while it buffers,
    /// including for the first moment of every track. Comparing against `.playing` treated
    /// that buffering state as "stopped", so the periodic reconcile flipped `isPlaying`
    /// back to false the instant playback was starting: the button stayed on the play
    /// triangle while audio came out, and the next press was read as "resume" rather than
    /// "pause" — hence having to press twice, on screen and on the lock screen both.
    ///
    /// Only `.paused` means the app should stop claiming to play.
    var isEnginePlaying: Bool { player.timeControlStatus != .paused }

    /// `AVPlayer.volume` is a `Float` multiplier under the system volume, so this is a
    /// per-app attenuation and not a replacement for the phone's own volume control.
    var volume: Double {
        get { Double(player.volume) }
        set { player.volume = Float(newValue) }
    }

    /// Waiting to play, with the reason being an empty buffer rather than normal start-up.
    ///
    /// Without this the app cannot distinguish "buffering for a moment" from "stalled in a
    /// tunnel with nothing left to play": both are `.waitingToPlayAtSpecifiedRate`, so
    /// `isEnginePlaying` reports true for both, and a permanent stall left the UI and lock
    /// screen showing playback over silence indefinitely, with no error and a frozen
    /// scrubber.
    var isStalled: Bool {
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return false }
        // `reasonForWaitingToPlay` distinguishes "filling the buffer to avoid a stall" from
        // "no item to play"; combined with an empty buffer it means we have genuinely run
        // dry rather than merely started up.
        if player.reasonForWaitingToPlay == .evaluatingBufferingRate { return false }
        return player.currentItem?.isPlaybackBufferEmpty ?? false
    }

    /// Discards the `AVPlayer` and builds a new one.
    ///
    /// After a media-services reset every AVFoundation object the process holds is inert —
    /// including the player itself and its periodic time observer. Replacing the *item* on
    /// the same dead player, which is what the recovery path used to do, recovers nothing:
    /// playback stays silent until the app is force-quit.
    func rebuild() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        removeItemObservers()
        activeResourceLoader?.shutdown()
        activeResourceLoader = nil
        // Back at 1.0, along with everything else the discarded player was holding.
        // `PlayerService.handleMediaServicesReset` is what restores the level.
        player = AVPlayer()
        installTimeObserver()
    }

    private func installTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.onPeriodicTime?(time.seconds) }
        }
    }

    func replaceItem(url: URL, forwardBufferDuration: TimeInterval) {
        removeItemObservers()
        attachGeneration += 1
        // The outgoing loader owns a URLSession that retains it; without this every track
        // played leaked one.
        activeResourceLoader?.shutdown()
        let (item, loader) = Self.makePlayerItem(for: url, forwardBufferDuration: forwardBufferDuration)
        activeResourceLoader = loader
        // Observed rather than only logged: a `.failed` item is a track that will never
        // play, and without surfacing it the app sits at 0:00 with its play button lit.
        // `Task { @MainActor }`, not `MainActor.assumeIsolated`. KVO on `AVPlayerItem`
        // is delivered on whatever queue AVFoundation chooses, and `assumeIsolated` is a
        // hard `fatalError` when that assumption is wrong — so the app crashed outright
        // the first time a stream URL turned out to be dead, which is a routine event.
        // The notification-based observers below are safe because they specify
        // `queue: .main`; this one had no such guarantee.
        let generation = attachGeneration
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let error = item.error
            Task { @MainActor in self?.reportFailure(error, generation: generation) }
        }
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onStalled?() }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onItemDidPlayToEnd?() }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated { self?.reportFailure(error, generation: generation) }
        }
        player.replaceCurrentItem(with: item)
    }

    private func removeItemObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        endObserver = nil
        failureObserver = nil
        stallObserver = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
    }

    func detach() {
        removeItemObservers()
        // Bumped for the same reason `replaceItem` bumps it: a late KVO or notification callback
        // from the item being dropped must not be mistaken for news about whatever comes next.
        attachGeneration += 1
        activeResourceLoader?.shutdown()
        activeResourceLoader = nil
        player.pause()
        // `forwardPlaybackEndTime` lives on the item, so dropping the item takes it with it.
        player.replaceCurrentItem(with: nil)
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    /// Local (downloaded) files bypass the network entirely — no need to route them through
    /// `StreamingResourceLoader`, and their bytes were already counted at download time.
    /// Everything else goes through the loader so its actual streaming bytes show up in
    /// `NetworkByteCounter`. Falls back to handing AVFoundation the real URL directly (no
    /// byte counting, but playback still works) if the URL can't be remapped.
    private static func makePlayerItem(
        for url: URL,
        forwardBufferDuration: TimeInterval
    ) -> (item: AVPlayerItem, resourceLoader: StreamingResourceLoader?) {
        guard !url.isFileURL, let playableURL = StreamingResourceLoader.playableURL(for: url) else {
            return (AVPlayerItem(url: url), nil)
        }
        let loader = StreamingResourceLoader(realURL: url)
        let asset = AVURLAsset(url: playableURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.callbackQueue)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = forwardBufferDuration
        return (item, loader)
    }
}

// MARK: - Audio session

@MainActor
protocol AudioSessionControlling: AnyObject {
    /// `casting == true` configures the session to mix rather than take the output route
    /// for itself, so the phone stops being a candidate for automatic AirPods switching
    /// while a browser is the one making sound.
    func activate(casting: Bool)
    func deactivate(notifyingOthers: Bool)
}

#if os(macOS)
/// macOS has no `AVAudioSession` — an app does not negotiate for the output route, it just
/// plays. Nothing to activate, nothing to deactivate, and nothing to configure differently
/// while casting. Kept under the same name so `PlayerService` wires itself up identically on
/// both platforms.
@MainActor
final class SystemAudioSession: AudioSessionControlling {
    static let shared = SystemAudioSession()

    func activate(casting: Bool) {}
    func deactivate(notifyingOthers: Bool) {}
}
#else
@MainActor
final class SystemAudioSession: AudioSessionControlling {
    static let shared = SystemAudioSession()

    func activate(casting: Bool) {
        let session = AVAudioSession.sharedInstance()
        // `.allowBluetooth` is deliberately *not* passed: on `.playback` it opts into the
        // HFP call profile, which drops AirPods to 8/16kHz mono. A2DP (full quality) is
        // already the default for `.playback`.
        if casting {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        } else {
            // Plain `.playback`. A `.longFormAudio` route-sharing policy was tried here and
            // removed: it changes how iOS selects an output, it was added on reasoning
            // rather than evidence, and it cannot be adjusted on an active session — the
            // failure is silent because the call is `try?`.
            try? session.setCategory(.playback, mode: .default)
        }
        try? session.setActive(true)
    }

    func deactivate(notifyingOthers: Bool) {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: notifyingOthers ? [.notifyOthersOnDeactivation] : []
        )
    }
}
#endif

// MARK: - Remote commands (lock screen, Control Center, AirPods gestures)

/// The transport actions the system can ask the app to perform. AirPods map their
/// gestures onto these: a single tap (or a stem press) is `togglePlayPause`, a double is
/// `nextTrack`, a triple is `previousTrack` — so every one of them has to be registered
/// and handled for the earbud controls to work at all.
enum RemoteCommandKind: String, CaseIterable {
    case play
    case pause
    case togglePlayPause
    case nextTrack
    case previousTrack
    case changePlaybackPosition
}

@MainActor
protocol RemoteCommandRegistering: AnyObject {
    func setHandler(for command: RemoteCommandKind, _ handler: @escaping (Double?) -> RemoteCommandOutcome)
    func setEnabled(_ enabled: Bool, for command: RemoteCommandKind)
    /// Turns off the commands this app doesn't implement. They default to enabled with no
    /// target, and while `skipForwardCommand`/`skipBackwardCommand` are enabled the lock
    /// screen shows ±15-second buttons *instead of* next/previous track — so leaving them
    /// on costs the user the transport controls they actually want.
    func disableUnhandledCommands()
}

enum RemoteCommandOutcome {
    case success
    case noSuchContent
    case commandFailed
}

@MainActor
final class SystemRemoteCommandCenter: RemoteCommandRegistering {
    static let shared = SystemRemoteCommandCenter()

    private func command(for kind: RemoteCommandKind) -> MPRemoteCommand {
        let center = MPRemoteCommandCenter.shared()
        switch kind {
        case .play: return center.playCommand
        case .pause: return center.pauseCommand
        case .togglePlayPause: return center.togglePlayPauseCommand
        case .nextTrack: return center.nextTrackCommand
        case .previousTrack: return center.previousTrackCommand
        case .changePlaybackPosition: return center.changePlaybackPositionCommand
        }
    }

    func setHandler(for kind: RemoteCommandKind, _ handler: @escaping (Double?) -> RemoteCommandOutcome) {
        let command = self.command(for: kind)
        command.removeTarget(nil)
        command.addTarget { event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            // MediaPlayer documents no delivery thread for remote command handlers and
            // carries no actor annotation, so `assumeIsolated` here was an unproven
            // assumption — and it is a hard `fatalError` when wrong. The system only
            // inspects the returned status, so hop instead of asserting.
            if Thread.isMainThread {
                let outcome = MainActor.assumeIsolated { handler(position) }
                switch outcome {
                case .success: return .success
                case .noSuchContent: return .noSuchContent
                case .commandFailed: return .commandFailed
                }
            }
            Task { @MainActor in _ = handler(position) }
            return .success
        }
    }

    func setEnabled(_ enabled: Bool, for kind: RemoteCommandKind) {
        command(for: kind).isEnabled = enabled
    }

    func disableUnhandledCommands() {
        let center = MPRemoteCommandCenter.shared()
        let unhandled: [MPRemoteCommand] = [
            center.skipForwardCommand,
            center.skipBackwardCommand,
            center.seekForwardCommand,
            center.seekBackwardCommand,
            center.changeRepeatModeCommand,
            center.changeShuffleModeCommand,
            center.likeCommand,
            center.dislikeCommand,
            center.bookmarkCommand,
            center.ratingCommand,
        ]
        for command in unhandled {
            command.removeTarget(nil)
            command.isEnabled = false
        }
    }
}

// MARK: - Now Playing info

/// What the lock screen, Control Center and a paired Mac show.
struct NowPlayingSnapshot: Equatable {
    var title: String
    var artist: String
    var album: String?
    var duration: Double?
    var elapsed: Double
    var rate: Double
}

@MainActor
protocol NowPlayingPublishing: AnyObject {
    func publish(_ snapshot: NowPlayingSnapshot, artwork: MPMediaItemArtwork?)
    func clear()
}

@MainActor
final class SystemNowPlayingCenter: NowPlayingPublishing {
    static let shared = SystemNowPlayingCenter()

    func publish(_ snapshot: NowPlayingSnapshot, artwork: MPMediaItemArtwork?) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: snapshot.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let duration = snapshot.duration, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let album = snapshot.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // `playbackState` is deliberately NOT set. On iOS it needs the private entitlement
        // `com.apple.mediaremote.set-playback-state`, so every attempt was rejected with
        // "Ignoring setPlaybackState…" in the log — twice per press. iOS derives the state
        // from `MPNowPlayingInfoPropertyPlaybackRate` above and from the audio session,
        // which is what actually drives the lock screen and AirPods.
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

// MARK: - Stream resolution

@MainActor
protocol StreamResolving: AnyObject {
    func streamURL(videoId: String) async throws -> String
    /// Forget a URL that turned out not to play, so the next resolve actually goes back
    /// to the network instead of returning the same dead one from cache.
    func invalidate(videoId: String)
}

final class APIStreamResolver: StreamResolving {
    static let shared = APIStreamResolver()
    func streamURL(videoId: String) async throws -> String {
        try await APIClient.shared.stream(videoId: videoId).url
    }

    func invalidate(videoId: String) {
        APIClient.shared.invalidateStream(videoId: videoId)
    }
}

// MARK: - Downloads

@MainActor
protocol DownloadLocating: AnyObject {
    func localFileURL(for track: Track) -> URL?
    func isDownloaded(_ track: Track) -> Bool
}

extension DownloadManager: DownloadLocating {}

// MARK: - The device that owns the session

/// How `PlayerService` reaches the paired device, without knowing anything about pairing.
///
/// Every transport method starts by offering its intent here. When this device is mirroring, the
/// intent is sent to the device that owns the session and nothing happens locally; otherwise it
/// returns false and the method runs as it always has. One funnel rather than routing at each of
/// the twenty-eight call sites in the views — and the only arrangement that also covers the lock
/// screen, whose commands enter through the very same methods.
///
/// A protocol with a no-op default so `PlayerService` still builds and tests in isolation, exactly
/// like `PlaybackSideEffects`. The live implementation is `PeerPlayback`.
@MainActor
protocol SessionOwning: AnyObject {
    /// True when the intent was sent to the paired device, and so must not also happen here.
    func relay(_ intent: PlayerService.PlaybackIntent) -> Bool
    /// Playback just started on this device under its own steam, so it owns the session now.
    func claimSession()
}

/// The unpaired case, and the one every test gets unless it asks for otherwise: nothing is
/// relayed anywhere and every method runs locally.
@MainActor
final class NoSessionOwner: SessionOwning {
    static let shared = NoSessionOwner()
    func relay(_ intent: PlayerService.PlaybackIntent) -> Bool { false }
    func claimSession() {}
}

// MARK: - History / stats side effects

/// The library bookkeeping `PlayerService` triggers as a side effect of playing things.
/// Bundled into one protocol so a test can assert on it (and keep it out of the real
/// `UserDefaults`) without standing in for five separate singletons.
@MainActor
protocol PlaybackSideEffects: AnyObject {
    func recordRadioSeed(_ seed: Track)
    func recordPlay(_ track: Track)
    func recordListening(_ track: Track, secondsPlayed: Int)
    func recentlyPlayedIds(limit: Int) -> Set<String>
    func cachedRadio(seedVideoId: String) -> [Track]?
    func cacheRadioIfAbsent(_ tracks: [Track], seedVideoId: String)
}

@MainActor
final class LivePlaybackSideEffects: PlaybackSideEffects {
    static let shared = LivePlaybackSideEffects()

    func recordRadioSeed(_ seed: Track) { RadioHistoryStore.shared.record(seed: seed) }
    func recordPlay(_ track: Track) { PlayHistoryStore.shared.record(track) }

    func recordListening(_ track: Track, secondsPlayed: Int) {
        ListeningStatsStore.shared.record(track, secondsPlayed: secondsPlayed)
    }

    func recentlyPlayedIds(limit: Int) -> Set<String> {
        Set(PlayHistoryStore.shared.recentSeeds(limit).map(\.id))
    }

    func cachedRadio(seedVideoId: String) -> [Track]? {
        RadioCacheStore.shared.tracks(for: seedVideoId)
    }

    func cacheRadioIfAbsent(_ tracks: [Track], seedVideoId: String) {
        RadioCacheStore.shared.storeIfAbsent(tracks, for: seedVideoId)
    }
}

/// Fetching a radio is the one piece of autoplay that isn't a side effect, so it gets its
/// own seam rather than being folded into `PlaybackSideEffects`.
@MainActor
protocol RadioFetching: AnyObject {
    func radio(videoId: String, limit: Int) async throws -> [Track]
}

final class APIRadioFetcher: RadioFetching {
    static let shared = APIRadioFetcher()
    func radio(videoId: String, limit: Int) async throws -> [Track] {
        try await APIClient.shared.radio(videoId: videoId, limit: limit)
    }
}
