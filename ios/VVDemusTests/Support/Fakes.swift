import AVFoundation
import Foundation
import MediaPlayer
import XCTest
@testable import VVDemus

// MARK: - Test data

enum Fixtures {
    /// `thumbnailUrl` is nil by default on purpose: a non-nil one sends `PlayerService`
    /// off to fetch artwork over the real network during a unit test.
    static func track(
        _ id: String,
        title: String? = nil,
        artist: String = "Test Artist",
        album: String? = nil,
        durationSeconds: Int? = 180
    ) -> Track {
        Track(
            videoId: id,
            title: title ?? "Track \(id)",
            artist: artist,
            album: album,
            thumbnailUrl: nil,
            durationSeconds: durationSeconds
        )
    }

    static func tracks(_ ids: [String]) -> [Track] {
        ids.map { track($0) }
    }
}

// MARK: - Playback engine

@MainActor
final class FakePlaybackEngine: PlaybackEngine {
    enum Event: Equatable {
        case replaceItem(URL)
        case play
        case pause
        case seek(Double)
        case rebuild
    }

    private(set) var events: [Event] = []
    private(set) var attachedURL: URL?
    /// Counted rather than inferred from `attachedURL`, which is already non-nil after the
    /// first track and so can't tell you that a *new* item was attached.
    private(set) var attachCount = 0

    /// Models AVPlayer's three-state `timeControlStatus` rather than a boolean.
    ///
    /// The fake used to jump straight from paused to playing on `play()`, which no real
    /// player does — AVPlayer sits in `.waitingToPlayAtSpecifiedRate` while it buffers,
    /// including at the start of every track. That missing state is exactly why a
    /// regression here (treating "buffering" as "stopped") passed the whole suite and
    /// still shipped a play button showing the wrong icon.
    enum EngineState {
        case paused
        /// Told to play, buffer ran dry, and it is not recovering. Distinct from
        /// `.buffering`: both look identical to `isEnginePlaying`, which is exactly why a
        /// permanent stall used to be invisible.
        case stalled
        /// Told to play, still filling its buffer. Real players spend the first moment of
        /// every track here.
        case buffering
        case playing
    }

    var currentTimeSeconds: Double = 0
    var itemDurationSeconds: Double?
    /// Survives `replaceItem` but not `rebuild()`, exactly as `AVPlayer.volume` does: a
    /// level belongs to the player, and a rebuild throws the player away.
    var volume: Double = 1
    /// What the player told the engine to treat as the end of the item, so a test can assert
    /// that a doubled item duration is cut back to the real one.
    var forwardPlaybackEndTime: Double?
    private(set) var state: EngineState = .paused

    /// Mirrors the real engine: false only when genuinely stopped.
    var isEnginePlaying: Bool { state != .paused }
    var isStalled: Bool { state == .stalled }
    var onStalled: (() -> Void)?

    /// Playback ran dry and is not coming back on its own.
    func stall() {
        state = .stalled
        onStalled?()
    }

    var onItemDidPlayToEnd: (() -> Void)?
    var onItemFailed: ((Error?) -> Void)?
    var onPeriodicTime: ((Double) -> Void)?

    private(set) var rebuildCount = 0

    func rebuild() {
        rebuildCount += 1
        events.append(.rebuild)
        state = .paused
        attachedURL = nil
        // A fresh `AVPlayer` is at full volume, and the app is what has to notice.
        volume = 1
    }

    func replaceItem(url: URL, forwardBufferDuration: TimeInterval) {
        events.append(.replaceItem(url))
        attachedURL = url
        attachCount += 1
        currentTimeSeconds = 0
        state = .paused
        // A fresh AVPlayerItem carries no end limit, so neither does this one. Deliberately
        // not auto-firing `onItemDidPlayToEnd` when a tick passes the limit: the real engine
        // would, but keeping the two triggers separate here is what lets a test tell the
        // primary mechanism (`finishTrack`) apart from the safety net (ticking past the end).
        forwardPlaybackEndTime = nil
    }

    /// Enters `.buffering`, not `.playing` — a real player does not produce sound the
    /// instant it is asked to. Call `finishBuffering()` to move it on.
    func play() {
        events.append(.play)
        state = .buffering
    }

    func pause() {
        events.append(.pause)
        state = .paused
    }

    /// The buffer filled and audio is now actually coming out.
    func finishBuffering() {
        guard state == .buffering else { return }
        state = .playing
    }

    func seek(to seconds: Double) {
        events.append(.seek(seconds))
        currentTimeSeconds = seconds
    }

    // MARK: Simulation helpers

    /// Pretends the engine advanced, the way the real periodic time observer would.
    func tick(to seconds: Double) {
        currentTimeSeconds = seconds
        onPeriodicTime?(seconds)
    }

    func finishTrack() {
        state = .paused
        onItemDidPlayToEnd?()
    }

    func fail(_ error: Error = NSError(domain: "test", code: 403)) {
        state = .paused
        onItemFailed?(error)
    }

    /// The engine stopping without the app asking — what iOS does to us on an
    /// interruption or when the route disappears.
    func stopBehindOurBack() {
        state = .paused
    }

    /// Audio starting without the app asking for it *now*.
    ///
    /// Models the gap between `AVPlayer.play()` and `timeControlStatus` describing it.
    /// That property is documented to change asynchronously, so a read taken on the main
    /// thread just after `play()` — which is exactly when the periodic observer fires, since
    /// it is invoked on every time jump and whenever playback starts or stops — can still
    /// say `.paused` about an instruction that is about to take effect. Sound then arrives
    /// with nothing further for the app to observe.
    func startPlayingBehindOurBack() {
        state = .playing
    }

    /// Coming back into coverage: the bytes a stalled item was waiting for arrive and its
    /// buffer refills.
    ///
    /// Only produces sound if the app left the player armed. A stall doesn't zero the rate —
    /// `.waitingToPlayAtSpecifiedRate` is still "told to play" — so a stalled player picks
    /// the track back up by itself, while one that was actually paused stays silent. That
    /// asymmetry is the point: it tells "the app gave up but never stopped the player" apart
    /// from "the app stopped the player".
    func refillBufferAfterStall() {
        guard state == .stalled else { return }
        state = .playing
    }

    func clearEvents() { events.removeAll() }

    var didPlayAfterLastAttach: Bool {
        guard let attachIndex = events.lastIndex(where: { if case .replaceItem = $0 { return true }; return false }) else {
            return false
        }
        return events[attachIndex...].contains(.play)
    }
}

// MARK: - Audio session

@MainActor
final class FakeAudioSession: AudioSessionControlling {
    struct Activation: Equatable {
        let casting: Bool
    }

    private(set) var activations: [Activation] = []
    private(set) var deactivations: [Bool] = []
    var isActive = false

    func activate(casting: Bool) {
        activations.append(Activation(casting: casting))
        isActive = true
    }

    func deactivate(notifyingOthers: Bool) {
        deactivations.append(notifyingOthers)
        isActive = false
    }

    func clear() {
        activations.removeAll()
        deactivations.removeAll()
    }
}

// MARK: - Remote commands

@MainActor
final class FakeRemoteCommandCenter: RemoteCommandRegistering {
    private(set) var handlers: [RemoteCommandKind: (Double?) -> RemoteCommandOutcome] = [:]
    private(set) var enabled: [RemoteCommandKind: Bool] = [:]
    private(set) var didDisableUnhandled = false

    func setHandler(for command: RemoteCommandKind, _ handler: @escaping (Double?) -> RemoteCommandOutcome) {
        handlers[command] = handler
    }

    func setEnabled(_ enabled: Bool, for command: RemoteCommandKind) {
        self.enabled[command] = enabled
    }

    func disableUnhandledCommands() {
        didDisableUnhandled = true
    }

    var registeredCommands: Set<RemoteCommandKind> { Set(handlers.keys) }

    /// Fires a command the way the system does when an AirPods gesture, the lock screen
    /// or a car's steering-wheel button asks for it.
    @discardableResult
    func fire(_ command: RemoteCommandKind, position: Double? = nil) -> RemoteCommandOutcome {
        guard let handler = handlers[command] else {
            XCTFail("No handler registered for \(command.rawValue) — the control is dead")
            return .commandFailed
        }
        return handler(position)
    }
}

// MARK: - Now playing

@MainActor
final class FakeNowPlayingCenter: NowPlayingPublishing {
    private(set) var published: [NowPlayingSnapshot] = []

    var latest: NowPlayingSnapshot? { published.last }

    func publish(_ snapshot: NowPlayingSnapshot, artwork: MPMediaItemArtwork?) {
        published.append(snapshot)
    }

    func clear() {
        published.append(NowPlayingSnapshot(title: "", artist: "", album: nil, duration: nil, elapsed: 0, rate: 0))
    }
}

// MARK: - Streams

@MainActor
final class FakeStreamResolver: StreamResolving {
    /// videoId -> URL string. Anything not listed resolves to a synthetic URL.
    var urls: [String: String] = [:]
    /// videoIds that should fail to resolve.
    var failing: Set<String> = []
    /// Blocks resolution until `release()` is called, for testing what happens *during* a
    /// slow resolve (device switch races, transport commands mid-load).
    var isSuspended = false

    private(set) var resolveCount: [String: Int] = [:]
    private(set) var invalidated: [String] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func streamURL(videoId: String) async throws -> String {
        resolveCount[videoId, default: 0] += 1
        if isSuspended {
            await withCheckedContinuation { continuations.append($0) }
        }
        if failing.contains(videoId) {
            throw APIError.server("resolve failed for \(videoId)")
        }
        return urls[videoId] ?? "https://stream.test/\(videoId).m4a"
    }

    func invalidate(videoId: String) {
        invalidated.append(videoId)
    }

    /// Lets every suspended resolve proceed.
    func release() {
        isSuspended = false
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

// MARK: - Downloads

@MainActor
final class FakeDownloads: DownloadLocating {
    var localFiles: [String: URL] = [:]

    func localFileURL(for track: Track) -> URL? { localFiles[track.videoId] }
    func isDownloaded(_ track: Track) -> Bool { localFiles[track.videoId] != nil }
}

// MARK: - Side effects

@MainActor
final class FakeSideEffects: PlaybackSideEffects {
    private(set) var radioSeeds: [Track] = []
    private(set) var plays: [Track] = []
    private(set) var listening: [(track: Track, seconds: Int)] = []
    var recentIds: Set<String> = []
    var radioCache: [String: [Track]] = [:]

    func recordRadioSeed(_ seed: Track) { radioSeeds.append(seed) }
    func recordPlay(_ track: Track) { plays.append(track) }
    func recordListening(_ track: Track, secondsPlayed: Int) { listening.append((track, secondsPlayed)) }
    func recentlyPlayedIds(limit: Int) -> Set<String> { recentIds }
    func cachedRadio(seedVideoId: String) -> [Track]? { radioCache[seedVideoId] }
    func cacheRadioIfAbsent(_ tracks: [Track], seedVideoId: String) {
        radioCache[seedVideoId] = radioCache[seedVideoId] ?? tracks
    }
}

@MainActor
final class FakeRadioFetcher: RadioFetching {
    var results: [String: [Track]] = [:]
    var failing: Set<String> = []
    private(set) var requests: [String] = []

    func radio(videoId: String, limit: Int) async throws -> [Track] {
        requests.append(videoId)
        if failing.contains(videoId) { throw APIError.server("radio failed") }
        return results[videoId] ?? []
    }
}

// MARK: - Harness

/// A `PlayerService` wired entirely to fakes, plus the levers needed to simulate the
/// things this app actually has to survive: AirPods appearing and vanishing, phone calls,
/// the screen locking, a browser taking over playback.
@MainActor
final class PlayerHarness {
    let player: PlayerService
    let engine = FakePlaybackEngine()
    let session = FakeAudioSession()
    let commands = FakeRemoteCommandCenter()
    let nowPlaying = FakeNowPlayingCenter()
    let streams = FakeStreamResolver()
    let downloads = FakeDownloads()
    let sideEffects = FakeSideEffects()
    let radios = FakeRadioFetcher()
    /// Private to this harness, so tests can post real `AVAudioSession` notifications
    /// without reaching every other `PlayerService` alive in the test process.
    let notifications = NotificationCenter()
    /// Private to this harness for the same reason `notifications` is: volume is persisted,
    /// and a test must neither read the developer's own level nor leave one behind in the
    /// app's real defaults. Torn down in `deinit`.
    let defaults: UserDefaults
    private let defaultsSuiteName: String

    /// Commands relayed to a casting browser.
    private(set) var relayedCommands: [String] = []

    /// - Parameter storedVolumes: levels already on disk when the app starts, for testing
    ///   what a relaunch restores. Empty means a fresh install.
    init(storedVolumes: [PlaybackDevice: Double] = [:]) {
        defaultsSuiteName = "VVDemusTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        for (device, level) in storedVolumes {
            defaults.set(level, forKey: PlayerService.volumeDefaultsKey(for: device))
        }
        player = PlayerService(
            engine: engine,
            session: session,
            commandCenter: commands,
            nowPlaying: nowPlaying,
            streams: streams,
            downloads: downloads,
            sideEffects: sideEffects,
            radios: radios,
            notifications: notifications,
            defaults: defaults
        )
        player.onComputerCommand = { [weak self] command in
            switch command {
            case .toggle: self?.relayedCommands.append("toggle")
            case .seek(let seconds): self?.relayedCommands.append("seek:\(seconds)")
            }
        }
    }

    /// `UserDefaults(suiteName:)` writes a real plist into the test process's container, so
    /// without this every harness ever constructed leaves one behind.
    deinit {
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
    }

    // MARK: Simulated system events

    /// A phone call, an alarm, Siri — anything that takes the audio route away.
    func beginInterruption() {
        notifications.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        engine.stopBehindOurBack()
    }

    /// - Parameter shouldResume: whether iOS says we may pick up where we left off. It
    ///   says no when the interrupting app is still in charge.
    func endInterruption(shouldResume: Bool) {
        var userInfo: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
        ]
        if shouldResume {
            userInfo[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue
        }
        notifications.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: userInfo)
    }

    /// AirPods taken out of your ears, a headphone cable pulled, a speaker going out of
    /// range. iOS stops the player itself before telling us.
    func disconnectAirPods() {
        engine.stopBehindOurBack()
        postRouteChange(.oldDeviceUnavailable)
    }

    func connectAirPods() {
        postRouteChange(.newDeviceAvailable)
    }

    func postRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        notifications.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
        )
    }

    func resetMediaServices() {
        notifications.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    // MARK: Convenience

    /// Starts a track and waits for it to actually attach, so tests don't have to repeat
    /// the settling dance.
    func startPlaying(_ track: Track, context: [Track] = []) async {
        player.play(track: track, context: context)
        await settle { self.player.currentTrack?.videoId == track.videoId && !self.player.isLoading }
    }

    /// Runs the main run loop until `condition` holds, or fails the test.
    ///
    /// Loading a track goes through an unstructured `Task`, and the notification observers
    /// are delivered through an `OperationQueue`, so almost nothing here is synchronous
    /// with the call that triggered it.
    func settle(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            await Task.yield()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertTrue(condition(), "Timed out waiting for condition", file: file, line: line)
    }

    /// Lets any already-queued main-actor work run, for assertions about things *not*
    /// happening.
    func drain(_ turns: Int = 12) async {
        for _ in 0..<turns {
            await Task.yield()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }
}
