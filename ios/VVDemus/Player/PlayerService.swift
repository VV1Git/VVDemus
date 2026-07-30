import AVFoundation
import Combine
import MediaPlayer
import UIKit

@MainActor
final class PlayerService: ObservableObject {
    static let shared = PlayerService()

    @Published private(set) var currentTrack: Track?
    /// Explicitly user-queued tracks ("Play Next" / "Add to Queue"), FIFO — these always
    /// play before the rest of the current context, regardless of shuffle.
    @Published private(set) var manualQueue: [Track] = []
    /// The rest of the playlist/radio/search results that were playing when playback
    /// started (or that autoplay fetched next). Reorders when shuffle is toggled.
    @Published private(set) var contextQueue: [Track] = []
    @Published private(set) var isShuffling = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var queueContextTitle: String?
    @Published var errorMessage: String?
    /// Which device is actually producing sound. Switching only ever pauses this phone's
    /// AVPlayer or reattaches it — all queue/radio/stats logic above stays exactly the
    /// same regardless of which device is playing.
    @Published private(set) var activeDevice: PlaybackDevice = .iphone
    /// Only set while `activeDevice == .computer` — what the browser's `<audio>` element
    /// should load. Cleared when switching back to the phone.
    ///
    /// The URL is carried *together with the videoId it was resolved for* rather than on
    /// its own: resolving a stream is async, so between `currentTrack` changing and the
    /// new URL arriving there is a window where a bare URL would still be the previous
    /// track's. The browser samples state during exactly that window on every transport
    /// command (app.js does `post(...).then(refreshState)`), and would load the old
    /// track's audio under the new track's id — playing the computer permanently one
    /// track behind the phone, with no self-correction.
    @Published private(set) var externalStream: ExternalStream?

    /// A resolved playback URL and the track it belongs to, so the two can never be
    /// observed out of step with each other.
    struct ExternalStream: Equatable {
        let videoId: String
        let url: String
    }

    /// The track queued after the current one, with its stream URL already resolved, sent
    /// to the casting browser so it can carry on by itself if this phone isn't reachable
    /// when the current track ends.
    ///
    /// Without it the browser is a dumb terminal: at the end of every track it has to ask
    /// this phone for the next URL, so a phone that's asleep or off the network at that
    /// exact moment stops the music — the failure looked like "it played fine, then died
    /// between songs". Only resolved while casting, since that's the only time anything
    /// reads it.
    @Published private(set) var upNextStream: ExternalStream?
    @Published private(set) var upNextTrack: Track?

    /// Bumped every time the phone changes what playback *should* be doing — a new track,
    /// a seek, a play/pause, a device switch. The browser echoes back the epoch it is
    /// reporting under, and reports from an older epoch are discarded.
    ///
    /// Reports are sent about once a second, so an action taken by the user is always
    /// racing a report describing the state just before it. Tagging reports with the track
    /// alone isn't enough: seeking, or pressing previous to restart the *same* track, is
    /// undone by a report that carries the correct videoId but a position from a moment
    /// ago. That showed up as the scrubber springing back after a drag, and as "previous"
    /// stepping back a track or not depending on timing.
    @Published private(set) var playbackEpoch: Int = 0

    private func bumpPlaybackEpoch() {
        playbackEpoch &+= 1
    }

    /// Bumped only when a track is (re)loaded from the top — unlike `playbackEpoch`, which
    /// also moves on seeks and play/pause. The browser keys its `<audio>` reload on this as
    /// well as on the videoId, because starting the track that is *already* playing (press
    /// previous twice, or click the current song in the web UI) doesn't change the videoId:
    /// the phone would restart at 0:00 while the computer played straight on.
    @Published private(set) var trackLoadEpoch: Int = 0

    /// Set by `LocalControlServer` while it's running, so a transport command issued from
    /// the phone (lock-screen controls, this app's own UI) while the computer is the
    /// active device gets relayed to the browser instead of silently doing nothing.
    var onComputerCommand: ((PlaybackCommand) -> Void)?

    enum PlaybackCommand {
        case toggle
        case seek(Double)
    }

    var autoplayEnabled = true

    /// contextQueue in its real (unshuffled) order — the source of truth restored when
    /// shuffle is turned off, and reshuffled fresh each time it's turned back on.
    private var orderedContextQueue: [Track] = []

    /// Which of the two queues a track was taken from. Needed so `previous()` can put the
    /// track it's leaving back where it came from: it used to push everything onto
    /// `contextQueue`, so stepping back over a track the user had explicitly queued
    /// quietly demoted it out of the manual queue, and the next `advance()` played
    /// whatever else was in the manual queue instead of retracing the path.
    enum QueueOrigin {
        case manual
        case context
    }

    private var currentTrackOrigin: QueueOrigin = .context
    /// Where the current track sat in `orderedContextQueue` — the *unshuffled* running
    /// order — at the moment it was taken off the queue. Meaningless while the origin is
    /// `.manual`.
    ///
    /// `previous()` needs it to put the track back where it came from. While shuffling the
    /// two queues are deliberately in different orders, so the front of `contextQueue` says
    /// nothing about where a track belongs in the real one; the position has to be recorded
    /// when it is consumed. It goes stale if the queue is edited in between, so it is
    /// clamped on use rather than trusted.
    private var currentTrackOrderedIndex = 0
    private var backStack: [(track: Track, origin: QueueOrigin, orderedIndex: Int)] = []
    private let recentRadioAvoidCount = 12
    private let backStackLimit = 30

    // MARK: - Injected collaborators

    private let engine: PlaybackEngine
    private let session: AudioSessionControlling
    private let commandCenter: RemoteCommandRegistering
    private let nowPlaying: NowPlayingPublishing
    private let streams: StreamResolving
    private let downloads: DownloadLocating
    private let sideEffects: PlaybackSideEffects
    private let radios: RadioFetching
    private let notifications: NotificationCenter

    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var stallRecoveryTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    /// Which track `artworkTask` is currently fetching for. `updateNowPlayingInfo` runs on
    /// every periodic tick (twice a second), and each call used to cancel the in-flight
    /// artwork fetch and start it again — so on any connection where the download took
    /// longer than half a second, lock-screen artwork could never finish loading at all.
    private var artworkTrackId: String?
    /// Artwork that could not be fetched or decoded. Without this, `updateNowPlayingInfo`
    /// runs twice a second, finds the cache still empty, and starts the fetch again — two
    /// HTTP requests per second on cellular for the entire track.
    private var failedArtworkIds: Set<String> = []
    /// Bounded so this doesn't grow for the entire app session — lock-screen artwork only
    /// ever needs the current (and maybe just-previous) track, so a handful of entries is
    /// plenty. Unbounded, this held a full decoded UIImage per unique track ever played,
    /// which is what was driving the app's memory usage up over long sessions.
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private var artworkCacheOrder: [String] = []
    private let artworkCacheLimit = 6
    /// True from the moment playback is handed back to this phone until its player item is
    /// actually attached — resolving a stream URL is async, so this can span seconds on a
    /// cold cache. Transport commands issued inside that window are recorded as intent and
    /// applied by the reattach, rather than being silently undone by it.
    private var isResumingAfterDeviceSwitch = false

    /// The queue ran out (or autoplay failed to find anything) with the finished track still
    /// loaded, and whichever player is active is parked on its final frame. Play then has to
    /// mean "start this track again", not "resume".
    ///
    /// Neither player resumes from there on its own: an AVPlayer sitting at the end of its
    /// item ignores `play()`, and the browser's `<audio>` element is `ended`, which app.js
    /// explicitly refuses to call `play()` on. `stopAtEndOfQueue` bumps no epoch either, so
    /// the browser had nothing to key a reload on — pressing play flipped `isPlaying` to
    /// true and produced silence, for good, until another track was chosen by hand.
    private var isStoppedAtEndOfQueue = false

    /// Set while the audio session is interrupted (a call, Siri, an alarm, another app
    /// taking the route). Remembers whether playback was running when the interruption
    /// began, because that is the only thing that decides whether it should come back when
    /// the interruption ends — the notification itself doesn't say.
    /// What the *user* wants playback to be doing, as opposed to what the engine is
    /// currently doing.
    ///
    /// Resolving a stream URL takes 1-3 seconds on a cold cache, and `attach` used to
    /// hardcode `autoplay: true` — so a pause pressed during that window was silently undone
    /// when the URL arrived, and the music started again by itself. Taking AirPods out
    /// during the same window was worse: the route handler paused correctly, then the late
    /// attach played the track out of the phone's loudspeaker. The device-switch path
    /// already read live state for this reason; every other load path did not.
    private var wantsPlayback = false
    private var wasPlayingBeforeInterruption = false
    private(set) var isInterrupted = false

    /// The stream URL currently attached, and the track it belongs to. Kept so a playback
    /// failure can be told apart from a fresh load, and so an expired URL can be re-resolved
    /// exactly once rather than retrying forever.
    private var attachedURL: URL?
    private var hasRetriedCurrentTrack = false

    // MARK: - Init

    private convenience init() {
        self.init(
            engine: AVPlaybackEngine(),
            session: SystemAudioSession.shared,
            commandCenter: SystemRemoteCommandCenter.shared,
            nowPlaying: SystemNowPlayingCenter.shared,
            streams: APIStreamResolver.shared,
            downloads: DownloadManager.shared,
            sideEffects: LivePlaybackSideEffects.shared,
            radios: APIRadioFetcher.shared,
            notifications: .default
        )
    }

    init(
        engine: PlaybackEngine,
        session: AudioSessionControlling,
        commandCenter: RemoteCommandRegistering,
        nowPlaying: NowPlayingPublishing,
        streams: StreamResolving,
        downloads: DownloadLocating,
        sideEffects: PlaybackSideEffects,
        radios: RadioFetching,
        notifications: NotificationCenter
    ) {
        self.engine = engine
        self.session = session
        self.commandCenter = commandCenter
        self.nowPlaying = nowPlaying
        self.streams = streams
        self.downloads = downloads
        self.sideEffects = sideEffects
        self.radios = radios
        self.notifications = notifications

        configureEngineCallbacks()
        configureRemoteCommandCenter()
        observeAudioSession()
    }

    private func configureEngineCallbacks() {
        engine.onPeriodicTime = { [weak self] seconds in
            guard let self else { return }
            // While the computer is the active device, `progress`/`duration` are owned
            // by `applyExternalReport` (fed by the browser) — this phone-side observer
            // keeps firing regardless of `activeDevice` (the AVPlayer item is just
            // paused, not torn down, while casting), and without this guard it could
            // stomp a browser-reported position with a stale/lagging local one, or
            // silently nudge progress forward during the brief window before `pause()`
            // fully takes effect right after a switch to computer.
            // ...and equally must not report the *old* item's position during the gap
            // between switching back to the phone and the new item being attached, which
            // would drag `progress` back to wherever the phone was when it handed off.
            // `!isLoading`: during a load the old item is still attached, and without this
            // its position and duration were written into the incoming track's fields.
            guard self.activeDevice == .iphone, !self.isResumingAfterDeviceSwitch,
                  !self.isLoading else { return }
            guard seconds.isFinite else { return }
            self.progress = seconds
            if let itemDuration = self.engine.itemDurationSeconds {
                self.duration = itemDuration
            }
            // Whatever the app last asked for, the engine is the authority on whether
            // sound is actually coming out. They diverge when something outside the app
            // stops playback — and a stuck `isPlaying` is what made the play button need
            // pressing twice after AirPods dropped out.
            self.reconcileIsPlayingWithEngine()
            self.updateNowPlayingInfo()
        }

        engine.onItemDidPlayToEnd = { [weak self] in
            guard let self, self.activeDevice == .iphone else { return }
            self.advance()
        }

        engine.onItemFailed = { [weak self] error in
            self?.handlePlaybackFailure(error)
        }

        engine.onStalled = { [weak self] in
            self?.handleStall()
        }
    }

    /// Playback ran out of buffered data.
    ///
    /// A brief stall is normal on a patchy connection and AVFoundation recovers by itself,
    /// so this doesn't touch playback immediately. But a stall that never recovers left the
    /// app claiming to play over silence forever — `.waitingToPlayAtSpecifiedRate` reads as
    /// "playing" to `isEnginePlaying`, and no failure is ever raised because the item didn't
    /// fail, it just stopped. After a grace period with the buffer still empty, the track is
    /// re-resolved: the usual cause is a stream URL that died mid-play.
    private func handleStall() {
        guard activeDevice == .iphone, isPlaying, currentTrack != nil else { return }
        stallRecoveryTask?.cancel()
        stallRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, Self.stallGrace) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard self.activeDevice == .iphone, self.isPlaying, self.engine.isStalled else { return }
            NSLog("[PlayerService] playback stalled for %.0fs — re-resolving", Self.stallGrace)
            self.handlePlaybackFailure(nil)
        }
    }

    /// Long enough that an ordinary blip on a train recovers untouched, short enough that a
    /// dead stream doesn't leave the user staring at a frozen scrubber.
    ///
    /// Settable so tests can exercise the recovery branch itself rather than only asserting
    /// that nothing has happened yet — at twelve seconds against a sixty-millisecond test
    /// wait, every stall test passed no matter what this method did.
    static var stallGrace: TimeInterval = 12

    /// The engine stopping on its own (a stall, an interruption the app didn't see, the
    /// route going away) has to be reflected in `isPlaying` or the UI, the lock screen and
    /// the AirPods gesture all end up out of step with reality.
    private func reconcileIsPlayingWithEngine() {
        guard activeDevice == .iphone, !isLoading, !isResumingAfterDeviceSwitch, currentTrack != nil else { return }
        // An interruption is handled by its own notification, which knows whether to
        // resume; don't let the periodic tick race it.
        guard !isInterrupted else { return }
        if isPlaying && !engine.isEnginePlaying {
            isPlaying = false
            updateNowPlayingInfo()
        }
    }

    // MARK: - Lock screen / Control Center / AirPods gestures

    /// AirPods (and most Bluetooth headsets) don't have their own protocol for transport:
    /// a stem press or tap arrives as one of these remote commands. All of them are
    /// registered — a missing `togglePlayPause` in particular means a single tap does
    /// nothing at all, which is the control people use most.
    private func configureRemoteCommandCenter() {
        commandCenter.setHandler(for: .play) { [weak self] _ in
            guard let self, self.currentTrack != nil else { return .noSuchContent }
            if !self.isPlaying { self.togglePlayPause() }
            return .success
        }
        commandCenter.setHandler(for: .pause) { [weak self] _ in
            guard let self, self.currentTrack != nil else { return .noSuchContent }
            if self.isPlaying { self.togglePlayPause() }
            return .success
        }
        commandCenter.setHandler(for: .togglePlayPause) { [weak self] _ in
            guard let self, self.currentTrack != nil else { return .noSuchContent }
            self.togglePlayPause()
            return .success
        }
        commandCenter.setHandler(for: .nextTrack) { [weak self] _ in
            // Returning `.success` with nothing loaded made a double-tap on an idle set of
            // AirPods look handled, so the system never fell back to anything else.
            guard let self, self.currentTrack != nil else { return .noSuchContent }
            self.advance()
            return .success
        }
        commandCenter.setHandler(for: .previousTrack) { [weak self] _ in
            guard let self, self.currentTrack != nil else { return .noSuchContent }
            self.previous()
            return .success
        }
        commandCenter.setHandler(for: .changePlaybackPosition) { [weak self] position in
            guard let self, let position, self.currentTrack != nil else { return .commandFailed }
            self.seek(to: position)
            return .success
        }
        for kind in RemoteCommandKind.allCases {
            commandCenter.setEnabled(true, for: kind)
        }
        commandCenter.disableUnhandledCommands()
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            nowPlaying.clear()
            return
        }
        let artwork = artworkCache[track.id]
        if artwork == nil { loadArtwork(for: track) }
        nowPlaying.publish(
            NowPlayingSnapshot(
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: duration > 0 ? duration : nil,
                elapsed: progress,
                rate: isPlaying ? 1.0 : 0.0
            ),
            artwork: artwork
        )
    }

    /// Checks the disk cache (shared with `RemoteImage`, and pre-warmed by `DownloadManager`
    /// at download time) before falling back to the network — this is what makes a
    /// downloaded track's lock-screen artwork actually stay offline instead of depending on
    /// the tiny 6-entry in-memory `artworkCache` still happening to hold it.
    private func loadArtwork(for track: Track) {
        guard artworkCache[track.id] == nil, !failedArtworkIds.contains(track.id),
              let urlString = track.thumbnailUrl else { return }
        // Already fetching this very track — leave it alone. Restarting here is what
        // starved the fetch on slow connections.
        guard artworkTrackId != track.id else { return }
        artworkTask?.cancel()
        artworkTrackId = track.id
        artworkTask = Task { [weak self] in
            guard let self else { return }
            let requestURLString = PlayerService.artworkCacheKey(for: urlString)
            var data: Data?
            if let diskData = await DiskImageCache.shared.data(for: requestURLString) {
                data = diskData
            } else if let url = URL(string: requestURLString),
                      let (fetched, _) = try? await NetworkSessions.image.data(from: url) {
                data = fetched
                await DiskImageCache.shared.store(fetched, for: requestURLString)
            }
            guard !Task.isCancelled else { return }
            if self.artworkTrackId == track.id { self.artworkTrackId = nil }
            guard let data, let image = UIImage(data: data) else {
                self.failedArtworkIds.insert(track.id)
                return
            }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.cacheArtwork(artwork, for: track.id)
            if self.currentTrack?.id == track.id {
                self.updateNowPlayingInfo()
            }
        }
    }

    /// Same (url, pixel-size) keying `RemoteImage` uses for its ~300pt hero images (Now
    /// Playing, Mix headers), so lock-screen artwork and on-screen artwork for the same
    /// track share one disk cache entry instead of each fetching their own copy.
    nonisolated static func artworkCacheKey(for thumbnailUrl: String) -> String {
        let targetPixels = RemoteImage.targetPixelSize(for: 300, displayScale: UIScreen.main.scale)
        return RemoteImage.resizedThumbnailUrl(thumbnailUrl, targetPixels: targetPixels)
    }

    private func cacheArtwork(_ artwork: MPMediaItemArtwork, for trackId: String) {
        artworkCache[trackId] = artwork
        artworkCacheOrder.removeAll { $0 == trackId }
        artworkCacheOrder.append(trackId)
        while artworkCacheOrder.count > artworkCacheLimit {
            let oldest = artworkCacheOrder.removeFirst()
            artworkCache.removeValue(forKey: oldest)
        }
    }

    // MARK: - Interruptions and route changes

    private func observeAudioSession() {
        notifications.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        }
        notifications.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        }
        notifications.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        }
    }

    /// A call, an alarm, Siri, or another app taking the audio route. The system has
    /// already stopped our audio by the time this arrives; what matters is coming back
    /// afterwards. Nothing handled this before, so a phone call left the app showing
    /// "playing" with no sound, and the play button needed pressing twice to recover.
    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            isInterrupted = true
            wasPlayingBeforeInterruption = (isPlaying || isLoading) && activeDevice == .iphone
            guard activeDevice == .iphone else { return }
            engine.pause()
            if isPlaying {
                isPlaying = false
                updateNowPlayingInfo()
            }
        case .ended:
            isInterrupted = false
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            // `.shouldResume` absent means the system does not want us back yet (the
            // interrupting app is still in charge). Resuming anyway is how apps end up
            // fighting Siri for the speaker.
            guard options.contains(.shouldResume), wasPlayingBeforeInterruption else {
                wasPlayingBeforeInterruption = false
                return
            }
            wasPlayingBeforeInterruption = false
            guard activeDevice == .iphone, currentTrack != nil else { return }
            wantsPlayback = true
            // The session was deactivated under us; it has to be reactivated before the
            // player will make any sound again.
            session.activate(casting: false)
            engine.play()
            isPlaying = true
            updateNowPlayingInfo()
        @unknown default:
            break
        }
    }

    /// AirPods being taken out, a headphone cable being pulled, a Bluetooth speaker going
    /// out of range. The platform convention — and what users expect — is that removing the
    /// thing you were listening on pauses playback rather than switching to the phone's
    /// loudspeaker. iOS pauses the underlying `AVPlayer` for us, but the app's own
    /// `isPlaying` was never updated to match, so the UI and lock screen kept claiming to
    /// be playing and the next AirPods tap was swallowed "un-pausing" something that was
    /// already stopped.
    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .oldDeviceUnavailable, .noSuitableRouteForCategory:
            // `.noSuitableRouteForCategory` is the same event without a replacement route:
            // the last output went away entirely. AVPlayer stops either way, so the app has
            // to stop claiming to play either way.
            guard activeDevice == .iphone else { return }
            // Clears the intent too, or a stream resolve that completes a second later
            // starts the track playing out of the phone's own speaker.
            wantsPlayback = false
            engine.pause()
            if isPlaying {
                isPlaying = false
                updateNowPlayingInfo()
            }
        case .newDeviceAvailable:
            // Deliberately does *not* start playing. Connecting AirPods while nothing is
            // playing should not begin blasting music; the user's tap does that. What it
            // must do is make sure the session is live on the new route, so the first tap
            // afterwards works immediately.
            guard activeDevice == .iphone, currentTrack != nil else { return }
            session.activate(casting: false)
        case .categoryChange, .override, .routeConfigurationChange:
            // Another app (or our own casting switch) reshaped the route. Only worth
            // reconciling our flag against what the engine is actually doing.
            reconcileIsPlayingWithEngine()
        default:
            // Any other reason still means the route was reshaped under us; believe the
            // engine rather than assuming nothing changed.
            reconcileIsPlayingWithEngine()
        }
    }

    /// Rare, but it does happen (and reliably under memory pressure on older phones): the
    /// media daemon restarts and every AVFoundation object the app holds becomes inert.
    /// Without rebuilding, playback is dead until the app is force-quit.
    private func handleMediaServicesReset() {
        // The player object itself is dead after a reset, not just its item — rebuild
        // before anything else, or the reattach below plays into a corpse.
        engine.rebuild()
        isInterrupted = false
        session.activate(casting: activeDevice == .computer)
        guard activeDevice == .iphone, currentTrack != nil, let url = attachedURL else { return }
        let resumeAt = progress
        attach(url: url, track: currentTrack!, resumeAt: resumeAt, autoplay: wantsPlayback, recordHistory: false)
    }

    /// An item that will never play — most often an expired stream URL (they are
    /// time-limited, and a track started from a queue that was built an hour ago hits this
    /// routinely). One silent re-resolve, then a visible error rather than a play button
    /// that does nothing.
    private func handlePlaybackFailure(_ error: Error?) {
        guard activeDevice == .iphone, let track = currentTrack else { return }
        NSLog("[PlayerService] playback failed: %@", error?.localizedDescription ?? "unknown")
        guard !hasRetriedCurrentTrack else {
            isPlaying = false
            isLoading = false
            errorMessage = "Couldn't play \"\(track.title)\". Check your connection and try again."
            updateNowPlayingInfo()
            return
        }
        hasRetriedCurrentTrack = true
        // The cached URL is the thing that just failed; without dropping it the "retry"
        // below would be handed the very same dead URL and fail identically.
        streams.invalidate(videoId: track.videoId)
        let wasPlaying = isPlaying
        isLoading = true
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let urlString = try await self.streams.streamURL(videoId: track.videoId)
                guard !Task.isCancelled, self.currentTrack?.videoId == track.videoId else { return }
                guard let url = URL(string: urlString) else { throw APIError.invalidURL }
                // Read now, not captured before the await, for the same reason as the
                // ordinary load path: a scrub while the replacement URL was being fetched
                // would otherwise be reverted to wherever playback happened to die.
                self.attach(url: url, track: track, resumeAt: self.progress, autoplay: wasPlaying, recordHistory: false)
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoading = false
                self.isPlaying = false
                self.errorMessage = "Couldn't play \"\(track.title)\". Check your connection and try again."
                self.updateNowPlayingInfo()
            }
        }
    }

    // MARK: - Playback entry points

    /// Play `track`, queuing up whatever comes after it in `context` (the list it was tapped from).
    ///
    /// `contextSeed` is the track a radio was generated from, when the context is a radio.
    /// Passing it here is what files the station under Your Radio — previously that only
    /// happened via the Play button on a radio's own screen, so tapping a song inside a
    /// radio, or starting one from the web remote, left no trace of the station at all.
    func play(track: Track, context: [Track] = [], contextTitle: String? = nil, contextSeed: Track? = nil) {
        if let contextSeed { sideEffects.recordRadioSeed(contextSeed) }
        manualQueue = []
        isShuffling = false
        if let index = context.firstIndex(where: { $0.id == track.id }) {
            orderedContextQueue = Array(context[(index + 1)...])
        } else {
            orderedContextQueue = []
        }
        contextQueue = orderedContextQueue
        queueContextTitle = contextTitle
        load(track)
    }

    // MARK: - Shuffle

    /// Toggling on shuffles the remaining context queue fresh (so re-enabling after
    /// disabling produces a new order, not the last shuffle); toggling off restores the
    /// real order. Manually queued tracks are never shuffled — the user chose that order.
    func toggleShuffle() {
        isShuffling.toggle()
        contextQueue = isShuffling ? orderedContextQueue.shuffled() : orderedContextQueue
        prefetchUpNextForComputer()
    }

    // MARK: - Queue manipulation

    /// Removing the track from `contextQueue`/`orderedContextQueue` first (if it's already
    /// there) keeps a track from ever sitting in two queues at once — without this, a
    /// track queued explicitly could get played once from the manual queue and then
    /// played *again* later when the context queue reached its own untouched copy.
    func addToQueue(_ track: Track) {
        contextQueue.removeAll { $0.id == track.id }
        orderedContextQueue.removeAll { $0.id == track.id }
        // Already queued by hand — queuing it again is a no-op rather than a second copy.
        // Two identical entries played the track twice and made the row identity ambiguous.
        guard !manualQueue.contains(where: { $0.id == track.id }) else { return }
        manualQueue.append(track)
        prefetchUpNextForComputer()
    }

    func playNext(_ track: Track) {
        manualQueue.removeAll { $0.id == track.id }
        contextQueue.removeAll { $0.id == track.id }
        orderedContextQueue.removeAll { $0.id == track.id }
        manualQueue.insert(track, at: 0)
        prefetchUpNextForComputer()
    }

    /// Removes exactly one entry, verifying the position still holds the track the caller
    /// meant. Preferred over `removeFromQueue(_:)`, which can only find the first entry with
    /// a given id and so can't tell two identical rows apart.
    ///
    /// A row captures its index when it renders, but the queue moves on its own — `advance()`
    /// pops from the front at every track boundary. A swipe on a row rendered before that
    /// boundary and released after it deleted a *different* track. The expected track is
    /// passed alongside the index so a stale position falls back to matching by identity.
    func removeFromManualQueue(at index: Int, expecting track: Track? = nil) {
        guard let resolved = Self.resolveIndex(index, expecting: track, in: manualQueue) else { return }
        manualQueue.remove(at: resolved)
        prefetchUpNextForComputer()
    }

    private static func resolveIndex(_ index: Int, expecting track: Track?, in queue: [Track]) -> Int? {
        if queue.indices.contains(index), track == nil || queue[index].id == track?.id { return index }
        guard let track else { return nil }
        return queue.firstIndex { $0.id == track.id }
    }

    func removeFromContextQueue(at index: Int, expecting track: Track? = nil) {
        guard let index = Self.resolveIndex(index, expecting: track, in: contextQueue) else { return }
        let removed = contextQueue.remove(at: index)
        // Mirror the removal in the unshuffled order, one copy only.
        if let mirrored = orderedContextQueue.firstIndex(where: { $0.id == removed.id }) {
            orderedContextQueue.remove(at: mirrored)
        }
        prefetchUpNextForComputer()
    }

    /// Removes one queue entry, addressed by track rather than by position — the web remote
    /// has no position-carrying route, so this is what it has to use.
    ///
    /// One entry, not every entry with that id. A radio mix or a Home shelf can repeat a
    /// videoId, and the `removeAll`-across-all-three-queues this used to do meant removing
    /// one such row silently took every other copy with it. Manual queue first, then
    /// context, matching the order the two are displayed in.
    func removeFromQueue(_ track: Track) {
        if let index = manualQueue.firstIndex(where: { $0.id == track.id }) {
            removeFromManualQueue(at: index)
        } else if let index = contextQueue.firstIndex(where: { $0.id == track.id }) {
            removeFromContextQueue(at: index)
        }
    }

    func moveInManualQueue(from source: IndexSet, to destination: Int) {
        manualQueue.move(fromOffsets: source, toOffset: destination)
        prefetchUpNextForComputer()
    }

    func moveInContextQueue(from source: IndexSet, to destination: Int) {
        contextQueue.move(fromOffsets: source, toOffset: destination)
        if !isShuffling {
            orderedContextQueue = contextQueue
        }
        prefetchUpNextForComputer()
    }

    /// Jump straight to an item already in the queue, dropping whatever preceded it —
    /// manual queue first, then context queue, matching how they're displayed.
    ///
    /// Addressing by track can only ever find the *first* entry carrying that id, so with a
    /// repeated videoId a tap on the second copy plays the first one and leaves the rows in
    /// between still queued. Callers that know which row was tapped should use the `at:`
    /// variants below; this one exists for the web remote, whose skip route sends a track
    /// and nothing else.
    func skipTo(_ track: Track) {
        if let index = manualQueue.firstIndex(where: { $0.id == track.id }) {
            skipToManualQueueEntry(at: index)
        } else if let index = contextQueue.firstIndex(where: { $0.id == track.id }) {
            skipToContextQueueEntry(at: index)
        }
    }

    /// `expecting` guards against a stale index exactly as it does for the remove routes:
    /// `advance()` pops the front of the queue at every track boundary, so a row's captured
    /// position can be one out by the time it's tapped.
    func skipToManualQueueEntry(at index: Int, expecting track: Track? = nil) {
        guard let index = Self.resolveIndex(index, expecting: track, in: manualQueue) else { return }
        let target = manualQueue[index]
        manualQueue.removeFirst(index + 1)
        load(target, origin: .manual)
    }

    func skipToContextQueueEntry(at index: Int, expecting track: Track? = nil) {
        guard let index = Self.resolveIndex(index, expecting: track, in: contextQueue) else { return }
        let target = contextQueue[index]
        let consumed = Array(contextQueue.prefix(index + 1))
        contextQueue.removeFirst(index + 1)
        load(target, origin: .context, orderedIndex: consumeFromOrderedQueue(consumed))
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        // See `isStoppedAtEndOfQueue`: starting again from the end of a finished queue is a
        // restart, not a resume. Cleared unconditionally — once the user has touched
        // play/pause, whatever happens next is an ordinary transport state.
        let restartsFinishedTrack = isStoppedAtEndOfQueue && !isPlaying
        isStoppedAtEndOfQueue = false
        if activeDevice == .computer {
            bumpPlaybackEpoch()
            if restartsFinishedTrack {
                progress = 0
                // `trackLoadEpoch` is the only thing app.js watches to decide it must
                // reload its `<audio>` element while the videoId is unchanged
                // (`phoneRestartedTrack`). Without the bump the element stays `ended` and
                // the relayed toggle lands on nothing at all.
                trackLoadEpoch &+= 1
            }
            isPlaying.toggle()
            pendingPlayIntent = (playing: isPlaying, at: Date())
            onComputerCommand?(.toggle)
            updateNowPlayingInfo()
            return
        }
        // Between items during a hand-back: touching the player would briefly resume the
        // outgoing item's audio, and the value set here is what the reattach reads.
        if isResumingAfterDeviceSwitch {
            isPlaying.toggle()
            updateNowPlayingInfo()
            return
        }
        // Bumped on the phone's own play/pause too, not just while casting. The epoch is
        // what a browser uses to recognise reports describing a state the phone has
        // already moved past, and a pause taken here while a browser was still connected
        // (about to be handed playback, or just watching) left the two agreeing on an
        // epoch that no longer described the same thing.
        bumpPlaybackEpoch()
        if isPlaying {
            wantsPlayback = false
            engine.pause()
            isPlaying = false
        } else {
            wantsPlayback = true
            if restartsFinishedTrack {
                // An AVPlayer whose item has played to its end does nothing when told to
                // play; it has to be wound back first.
                engine.seek(to: 0)
                progress = 0
            }
            // Coming back from an interruption or a route change, the session may no
            // longer be active — playing into a dead session is silent, which is exactly
            // what "the first tap does nothing" felt like.
            session.activate(casting: false)
            engine.play()
            isPlaying = true
        }
        updateNowPlayingInfo()
    }

    func seek(to seconds: Double) {
        // A scrub past the end (or a negative one from a jittery remote) otherwise pushed
        // the player into an unrecoverable position.
        let target = clampToTrack(seconds)
        // Scrubbing back into a track the queue already finished picks its own starting
        // point; play must resume from there rather than being rewound to 0:00.
        isStoppedAtEndOfQueue = false
        guard activeDevice != .computer else {
            bumpPlaybackEpoch()
            progress = target
            onComputerCommand?(.seek(target))
            updateNowPlayingInfo()
            return
        }
        bumpPlaybackEpoch()
        engine.seek(to: target)
        progress = target
        updateNowPlayingInfo()
    }

    private func clampToTrack(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        let upperBound = duration > 0 ? duration : Double.greatestFiniteMagnitude
        return min(max(0, seconds), upperBound)
    }

    // MARK: - Device switching (VVDemus Connect)

    /// Moves audio output between this phone's AVPlayer and a connected browser, without
    /// touching queue/radio/shuffle/stats state — those all keep living here regardless
    /// of which device is actually making sound.
    /// Hands playback back to the phone because the browser went quiet, rather than
    /// because the user asked. The distinction matters: the automatic case must not start
    /// making noise — a closed laptop lid otherwise had the phone playing out loud in the
    /// user's bag about ten seconds later.
    func fallBackToPhone() {
        wantsPlayback = false
        isPlaying = false
        setActiveDevice(.iphone)
    }

    func setActiveDevice(_ device: PlaybackDevice) {
        guard device != activeDevice else { return }
        activeDevice = device
        bumpPlaybackEpoch()
        pendingPlayIntent = nil
        session.activate(casting: device == .computer)
        switch device {
        case .computer:
            engine.pause()
            // A phone-side load cancelled by this switch never reaches its own completion,
            // so nothing else would ever clear this — and while it is true the reconcile is
            // disabled entirely.
            isLoading = false
            isResumingAfterDeviceSwitch = false
            prefetchUpNextForComputer()
            // The currently-playing track (if any) needs its stream URL resolved for the
            // browser too — only a *new* track load did this before, so switching devices
            // mid-playback left the browser with nothing to actually play.
            externalStream = nil
            guard let track = currentTrack else { return }
            loadTask?.cancel()
            loadTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let urlString = try await self.resolveComputerStreamUrl(for: track)
                    guard !Task.isCancelled, self.activeDevice == .computer,
                          self.currentTrack?.videoId == track.videoId else { return }
                    self.externalStream = ExternalStream(videoId: track.videoId, url: urlString)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.errorMessage = "Couldn't hand off playback to the computer."
                }
            }
        case .iphone:
            externalStream = nil
            upNextStream = nil
            upNextTrack = nil
            prefetchTask?.cancel()
            guard let track = currentTrack else { return }
            isResumingAfterDeviceSwitch = true
            loadTask?.cancel()
            loadTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let url: URL
                    if let localURL = self.downloads.localFileURL(for: track) {
                        url = localURL
                    } else {
                        let urlString = try await self.streams.streamURL(videoId: track.videoId)
                        guard let resolved = URL(string: urlString) else { throw APIError.invalidURL }
                        url = resolved
                    }
                    // A second switch (back to the computer, or on to another track) while
                    // this was resolving must win — otherwise the late arrival reattaches
                    // the phone's player and steals the route back.
                    guard !Task.isCancelled, self.activeDevice == .iphone,
                          self.currentTrack?.videoId == track.videoId else { return }
                    // Read (rather than pre-captured) so a pause or seek made while this
                    // was resolving is honoured instead of being reverted.
                    self.attach(url: url, track: track, resumeAt: self.progress, autoplay: self.isPlaying, recordHistory: false)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.isResumingAfterDeviceSwitch = false
                    self.isLoading = false
                    self.isPlaying = false
                    self.errorMessage = "Couldn't resume playback on this iPhone."
                    self.updateNowPlayingInfo()
                }
            }
        }
    }

    /// Progress reports POSTed by the browser while it's the active device — keeps the
    /// lock-screen and listening stats accurate without the phone decoding any audio
    /// itself. Guarded by `activeDevice` so a report that was already in flight when the
    /// user switched back to the phone can't stomp on freshly-resumed local playback, and
    /// by `videoId` so the ~1s of reports still describing the *outgoing* track after a
    /// skip don't get applied to the incoming one — that made every track after the first
    /// start partway in (roughly wherever its predecessor was left), since the browser
    /// then dutifully seeked the new track to that position.
    func applyExternalReport(epoch: Int?, videoId: String?, progress: Double, duration: Double, isPlaying: Bool) {
        guard activeDevice == .computer else { return }
        // A report that can't say which track it describes isn't trustworthy — the browser
        // only omits the id when it has no track loaded, and such a report was how a stray
        // frame of leftover audio in the browser's `<audio>` element could tell the phone
        // it was playing something it wasn't.
        guard let videoId, videoId == currentTrack?.videoId else { return }
        // Anything describing playback as it was before the phone's latest instruction is
        // out of date by definition; see `playbackEpoch`.
        guard epoch == playbackEpoch else { return }
        // Bounded, not merely finite: `1e300` is finite, and any consumer that converts it
        // to an Int traps. These values come from any device on the network.
        guard let progress = Self.sanitisedSeconds(progress),
              let duration = Self.sanitisedSeconds(duration) else { return }
        self.progress = progress
        self.duration = duration
        // Position is always worth taking; the play/pause flag is not.
        //
        // Pausing from the phone's own lock screen while casting bumps the epoch and
        // relays a command to the browser. If that relay is slow or the socket is down,
        // the browser carries on playing, picks up the *new* epoch from its next poll, and
        // reports `isPlaying: true` under it — which passed the epoch check and flipped the
        // phone straight back to playing. The pause visibly bounced and didn't stick. The
        // browser holds the mirror-image intent for its own commands; this is the phone's.
        if let intent = pendingPlayIntent {
            if intent.playing == isPlaying {
                pendingPlayIntent = nil
            } else if Date().timeIntervalSince(intent.at) < Self.playIntentTimeout {
                updateNowPlayingInfo()
                return
            } else {
                // The browser never came round; it's the one making sound, so believe it.
                pendingPlayIntent = nil
            }
        }
        self.isPlaying = isPlaying
        updateNowPlayingInfo()
    }

    /// What this phone last told the casting browser to do, held until the browser's
    /// reports agree (or until it's clear they never will).
    private var pendingPlayIntent: (playing: Bool, at: Date)?
    private static let playIntentTimeout: TimeInterval = 5

    /// Advances only if `from` is still the current track.
    ///
    /// The browser posts `/api/next` when its audio element ends, which can arrive just
    /// after the user already pressed next on the phone. Unconditional advancing then
    /// skipped a track entirely — and still recorded it as played.
    func advanceIfCurrent(_ from: String?) {
        guard let from else { return advance() }
        guard currentTrack?.videoId == from else { return }
        advance()
    }

    func advance() {
        if !manualQueue.isEmpty {
            let next = manualQueue.removeFirst()
            load(next, origin: .manual)
        } else if let next = popNextContextTrack() {
            load(next.track, origin: .context, orderedIndex: next.orderedIndex)
        } else if autoplayEnabled, let seed = currentTrack {
            continueAutoplay(from: seed)
        } else {
            stopAtEndOfQueue()
        }
    }

    /// Nothing left to play. The lock screen has to be told, or it keeps showing the last
    /// track as playing forever.
    private func stopAtEndOfQueue() {
        // The track that just finished is credited here. Stats were only ever recorded when
        // one track replaced another, so the last track of every queue — the one the user
        // let play all the way through — was systematically the one never counted.
        recordListeningStats()
        progress = 0
        isPlaying = false
        isLoading = false
        isStoppedAtEndOfQueue = true
        updateNowPlayingInfo()
    }

    private func popNextContextTrack() -> (track: Track, orderedIndex: Int)? {
        guard !contextQueue.isEmpty else { return nil }
        let next = contextQueue.removeFirst()
        return (next, consumeFromOrderedQueue([next]))
    }

    /// Takes a run of entries just consumed off the front of `contextQueue` out of the
    /// unshuffled running order too, and reports where the last of them — the track about
    /// to play — sat among the entries that remain.
    ///
    /// Exactly one removal per consumed entry, never `removeAll`: the same track can
    /// legitimately appear more than once in a mix or playlist, and deleting every matching
    /// id here dropped copies that were still queued to play. The loss was invisible until
    /// shuffle was switched off, since that is when `contextQueue` is restored from this
    /// list.
    ///
    /// Matching each entry by id is enough even when the run contains duplicates of the
    /// track being skipped to: the copies are indistinguishable, so which one is removed
    /// doesn't matter, only that the count comes out right.
    private func consumeFromOrderedQueue(_ entries: [Track]) -> Int {
        guard let target = entries.last else { return 0 }
        for skipped in entries.dropLast() {
            if let index = orderedContextQueue.firstIndex(where: { $0.id == skipped.id }) {
                orderedContextQueue.remove(at: index)
            }
        }
        guard let index = orderedContextQueue.firstIndex(where: { $0.id == target.id }) else { return 0 }
        orderedContextQueue.remove(at: index)
        return index
    }

    /// Walking backward and then forward again now retraces the same path: `previous`
    /// pushes the track being left back onto the front of `contextQueue` (instead of
    /// backward navigation being a wholly separate mechanism from the forward queue),
    /// so a subsequent `advance()` naturally picks it back up rather than jumping ahead
    /// to whatever happened to still be left in the queue.
    func previous() {
        if progress > 3 {
            seek(to: 0)
            return
        }
        guard let entry = backStack.popLast() else {
            seek(to: 0)
            return
        }
        if let outgoing = currentTrack {
            switch currentTrackOrigin {
            case .manual:
                manualQueue.insert(outgoing, at: 0)
            case .context:
                contextQueue.insert(outgoing, at: 0)
                // The unshuffled order has to take the track back as well, at the position
                // it was taken from. Skipping this while shuffling — on the grounds that
                // writing to the unshuffled list at index 0 would rewrite the real running
                // order — lost the track outright: rewinding un-plays it, so it belongs in
                // both lists again, and switching shuffle off replaces `contextQueue`
                // wholesale with this list. Shuffle, next, previous, shuffle-off deleted a
                // track from the queue permanently.
                //
                // Index 0 was the wrong destination, not the write itself. With shuffle off
                // the two are the same thing (a track is always popped from the front of
                // both), which is why the unshuffled case looked correct.
                let position = min(max(0, currentTrackOrderedIndex), orderedContextQueue.count)
                orderedContextQueue.insert(outgoing, at: position)
            }
        }
        currentTrackOrigin = entry.origin
        currentTrackOrderedIndex = entry.orderedIndex
        // Bypass load()'s backStack push: walking backward shouldn't re-push the track
        // we're leaving, or repeated "previous" presses would just bounce between two tracks.
        beginLoad(entry.track)
    }

    var hasPrevious: Bool { !backStack.isEmpty }

    // MARK: - Autoplay

    private func continueAutoplay(from seed: Track) {
        isLoading = true
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Reuse an already-cached mix for this seed (e.g. from having viewed its
                // radio screen, or the web remote fetching it) instead of always re-fetching
                // — and only 25 are needed, not 50, since just `fresh.first` is used
                // immediately and the rest just seed the context queue.
                let mix: [Track]
                if let cached = self.sideEffects.cachedRadio(seedVideoId: seed.videoId), !cached.isEmpty {
                    mix = cached
                } else {
                    let fetched = try await self.radios.radio(
                        videoId: seed.videoId,
                        limit: InnerTubeClient.dataSaverLimit(default: 25)
                    )
                    // `cacheRadioIfAbsent`, so autoplay quietly refilling the queue can never
                    // replace the mix shown on that radio's screen with its own shorter one.
                    self.sideEffects.cacheRadioIfAbsent(fetched, seedVideoId: seed.videoId)
                    mix = fetched
                }
                guard !Task.isCancelled else { return }
                let recent = self.sideEffects.recentlyPlayedIds(limit: self.recentRadioAvoidCount)
                let fresh = mix
                    .excludingLongFormMixes()
                    .filter { $0.id != seed.id && !recent.contains($0.id) }
                guard let next = fresh.first else {
                    self.stopAtEndOfQueue()
                    return
                }
                self.orderedContextQueue = Array(fresh.dropFirst())
                self.contextQueue = self.isShuffling ? self.orderedContextQueue.shuffled() : self.orderedContextQueue
                self.queueContextTitle = "\(seed.title) Radio"
                // Autoplay rolling into a radio counts as listening to it.
                self.sideEffects.recordRadioSeed(seed)
                self.load(next)
            } catch {
                guard !Task.isCancelled else { return }
                self.stopAtEndOfQueue()
            }
        }
    }

    // MARK: - Loading a track

    /// `orderedIndex` defaults to 0 because every caller that doesn't pass one is starting a
    /// context from the top — `play(track:context:)` queues everything *after* the track, and
    /// autoplay queues everything after `fresh.first`.
    private func load(_ track: Track, origin: QueueOrigin = .context, orderedIndex: Int = 0) {
        pushOntoBackStack()
        currentTrackOrigin = origin
        currentTrackOrderedIndex = orderedIndex
        beginLoad(track)
    }

    private func pushOntoBackStack() {
        guard let outgoing = currentTrack else { return }
        backStack.append((outgoing, currentTrackOrigin, currentTrackOrderedIndex))
        if backStack.count > backStackLimit {
            backStack.removeFirst(backStack.count - backStackLimit)
        }
    }

    private func beginLoad(_ track: Track) {
        loadTask?.cancel()
        // Starting a track is a request to play it.
        wantsPlayback = true
        // An interruption that never delivered its `.ended` notification (app suspended, the
        // interrupting app dismissed) would otherwise latch this flag true for the rest of
        // the process and permanently disable the reconcile safety net.
        isInterrupted = false
        // A fresh track supersedes any in-progress hand-back from the computer. Leaving
        // this set meant that if the new load then failed, the flag stuck on forever: the
        // periodic observer dropped every tick (so progress and the lock screen froze) and
        // `togglePlayPause` took its "record the intent" branch, which never touches the
        // player — play/pause was dead for the rest of the session.
        isResumingAfterDeviceSwitch = false
        // There is a track to play again, so the queue is no longer exhausted.
        isStoppedAtEndOfQueue = false
        pendingPlayIntent = nil
        stallRecoveryTask?.cancel()
        bumpPlaybackEpoch()
        trackLoadEpoch &+= 1
        recordListeningStats()
        currentTrack = track
        isLoading = true
        errorMessage = nil
        progress = 0
        // Seeded from the track's own metadata rather than left at zero until the first
        // periodic tick. Without it, handing playback back from the computer *while
        // paused* never ticks at all, so the scrubber was a one-second stub showing 0:00
        // for the track length until the user pressed play.
        duration = track.durationSeconds.map(Double.init) ?? 0
        hasRetriedCurrentTrack = false
        attachedURL = nil
        updateNowPlayingInfo()

        if activeDevice == .computer {
            beginLoadForComputer(track)
            return
        }

        // The previously attached item is still loaded and would otherwise keep playing
        // audibly under the new track's title for the length of the resolve, crediting its
        // elapsed seconds to a song that was never heard.
        engine.pause()

        // Downloaded tracks play straight from disk — no network, no data usage.
        if let localURL = downloads.localFileURL(for: track) {
            attach(url: localURL, track: track)
            return
        }

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let urlString = try await self.streams.streamURL(videoId: track.videoId)
                guard !Task.isCancelled, self.currentTrack?.videoId == track.videoId else { return }
                guard let url = URL(string: urlString) else { throw APIError.invalidURL }
                // `self.progress` rather than the implicit 0. Resolving a stream takes
                // seconds on a cold cache, and the scrubber is live throughout — a drag
                // during that window already moved `progress`, and attaching at zero threw
                // it away, so the scrubber visibly sprang back to 0:00 the instant the
                // track started. `beginLoad` zeroes `progress` before this task runs, so
                // with no scrub this is still an ordinary start from the top.
                self.attach(url: url, track: track, resumeAt: self.progress)
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoading = false
                self.isPlaying = false
                self.errorMessage = "Couldn't play \"\(track.title)\". Check your connection and try again."
                self.updateNowPlayingInfo()
            }
        }
    }

    /// The computer-active counterpart to `attach` — hands the browser something to load
    /// into its own `<audio>` element instead of touching this phone's AVPlayer at all,
    /// so the phone doesn't also decode/stream the same audio while casting.
    private func beginLoadForComputer(_ track: Track) {
        sideEffects.recordPlay(track)
        // The whole point of prefetching the next track's URL is that it's ready the moment
        // the track changes. Discarding it here and re-resolving from scratch put a 1-2
        // second silence into *every* track transition while casting — the browser sits at
        // `streamVideoId !== videoId` waiting — even though the URL was already in hand.
        if let prefetched = upNextStream, prefetched.videoId == track.videoId {
            loadTask?.cancel()
            externalStream = prefetched
            isLoading = false
            isPlaying = true
            updateNowPlayingInfo()
            prefetchUpNextForComputer()
            return
        }
        // Drop the outgoing track's URL immediately, so nothing observing this mid-resolve
        // sees the new track paired with the old track's audio.
        externalStream = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let urlString = try await self.resolveComputerStreamUrl(for: track)
                guard !Task.isCancelled, self.activeDevice == .computer,
                      self.currentTrack?.videoId == track.videoId else { return }
                self.externalStream = ExternalStream(videoId: track.videoId, url: urlString)
                self.isLoading = false
                self.isPlaying = true
                self.updateNowPlayingInfo()
                self.prefetchUpNextForComputer()
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoading = false
                self.isPlaying = false
                self.errorMessage = "Couldn't play \"\(track.title)\". Check your connection and try again."
                self.updateNowPlayingInfo()
            }
        }
    }

    // MARK: - Playing on past a disconnection

    /// Whatever plays after the current track, if it's already decided.
    private var nextQueuedTrack: Track? { manualQueue.first ?? contextQueue.first }

    /// Resolves the next track's stream URL ahead of time so the casting browser holds a
    /// usable URL before it needs one.
    ///
    /// Only while casting: on this phone AVPlayer does its own buffering and a brief
    /// network gap between tracks is survivable, whereas the browser has no other way to
    /// find out what comes next. Costs one extra player request per track, which is the
    /// price of the music not stopping every time the phone's connection hiccups.
    ///
    /// Autoplay's radio-derived next track deliberately isn't prefetched — that needs a
    /// whole radio fetch to even know what the track is, which is far too much work to do
    /// speculatively on every track change.
    private func prefetchUpNextForComputer() {
        guard activeDevice == .computer, let next = nextQueuedTrack else {
            prefetchTask?.cancel()
            upNextStream = nil
            upNextTrack = nil
            return
        }
        guard upNextStream?.videoId != next.videoId else { return }
        // Without this the same in-flight prefetch was cancelled and restarted by every
        // queue mutation, so a rapid series of "add to queue" taps could leave the browser
        // with no next URL at all.
        guard upNextTrack?.videoId != next.videoId || upNextStream != nil else { return }
        upNextTrack = next
        upNextStream = nil
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            guard let urlString = try? await self.resolveComputerStreamUrl(for: next) else { return }
            guard !Task.isCancelled, self.nextQueuedTrack?.videoId == next.videoId else { return }
            self.upNextStream = ExternalStream(videoId: next.videoId, url: urlString)
        }
    }

    /// Accepts the browser's account of what it's actually playing.
    ///
    /// If this phone was unreachable when a track ended, the browser moved on by itself
    /// using the prefetched URL — so the browser, not the phone, knows what's really
    /// coming out of the speakers. Rather than dragging it back to whatever this phone
    /// still had selected, the phone catches up: the device producing audio wins.
    ///
    /// Deliberately does not go through `load()`: the audio is already playing over there,
    /// and reloading would restart the track. `trackLoadEpoch` is left alone for the same
    /// reason — bumping it is the signal that tells the browser to start a track over.
    func adoptExternalPlayback(videoId: String, progress: Double) {
        guard activeDevice == .computer else { return }
        guard let progress = Self.sanitisedSeconds(progress) else { return }
        guard currentTrack?.videoId != videoId else {
            self.progress = progress
            return
        }

        // Consume the queue up to and including the adopted track, so what plays next
        // follows on from where the browser actually got to.
        //
        // First match is the right one here even with a repeated videoId: the browser works
        // through the queue from the front, so the earliest unplayed copy is the one it
        // reached. Mirroring that into the unshuffled order with `removeAll` over the set of
        // consumed ids was not — that deleted copies still sitting further down
        // `contextQueue`, which then vanished the next time shuffle was switched off.
        if let index = manualQueue.firstIndex(where: { $0.videoId == videoId }) {
            let adopted = manualQueue[index]
            manualQueue.removeFirst(index + 1)
            finishAdopting(adopted, origin: .manual, orderedIndex: 0, progress: progress)
        } else if let index = contextQueue.firstIndex(where: { $0.videoId == videoId }) {
            let adopted = contextQueue[index]
            let consumed = Array(contextQueue.prefix(index + 1))
            contextQueue.removeFirst(index + 1)
            let orderedIndex = consumeFromOrderedQueue(consumed)
            finishAdopting(adopted, origin: .context, orderedIndex: orderedIndex, progress: progress)
        }
        // A track that isn't in either queue can't be reconciled — the phone keeps its own
        // idea of the queue and the next state broadcast pulls the browser back into line.
    }

    private func finishAdopting(_ track: Track, origin: QueueOrigin, orderedIndex: Int, progress: Double) {
        // Unconditionally, not just on the `externalStream == nil` path below. The adopt
        // handler switches the device first, which starts a task resolving the *outgoing*
        // track's URL; when the prefetched URL matched (the common case) that task survived
        // and later overwrote `externalStream` with the previous track's audio. The phone's
        // `streamVideoId` then permanently disagreed with `currentTrack`, and any tab
        // loading afterwards waited forever with nothing to play.
        loadTask?.cancel()
        recordListeningStats()
        pushOntoBackStack()
        currentTrackOrigin = origin
        currentTrackOrderedIndex = orderedIndex
        // The browser found something to play, so the queue plainly hasn't run out.
        isStoppedAtEndOfQueue = false
        currentTrack = track
        self.progress = progress
        // Seeded from the track's own metadata like `beginLoad` does, so the scrubber isn't
        // a 0:00 stub until the browser's next report lands.
        duration = track.durationSeconds.map(Double.init) ?? 0
        isLoading = false
        isPlaying = true
        sideEffects.recordPlay(track)
        // The browser already holds a working URL for this track (it's playing it); this
        // just brings the phone's own record back in step, without disturbing playback.
        externalStream = upNextStream?.videoId == track.videoId ? upNextStream : nil
        updateNowPlayingInfo()
        if externalStream == nil {
            loadTask = Task { [weak self] in
                guard let self else { return }
                guard let urlString = try? await self.resolveComputerStreamUrl(for: track),
                      !Task.isCancelled, self.currentTrack?.videoId == track.videoId else { return }
                self.externalStream = ExternalStream(videoId: track.videoId, url: urlString)
            }
        }
        prefetchUpNextForComputer()
    }

    /// What the browser's `<audio>` element should load for `track` while it's the active
    /// device — a same-origin relative path to LocalControlServer's own
    /// `/api/audio/local` route for a downloaded track (the browser can't reach a
    /// `file://` URL on the phone's disk), or the directly-fetchable resolved stream URL
    /// otherwise.
    private func resolveComputerStreamUrl(for track: Track) async throws -> String {
        if downloads.isDownloaded(track) {
            return "/api/audio/local/\(track.videoId)"
        }
        return try await streams.streamURL(videoId: track.videoId)
    }

    /// Throws away the stream URL the casting browser was given and resolves a fresh one.
    ///
    /// For the case where the browser reports it cannot play what it was handed. These
    /// URLs are time-limited and are bound to the phone's network path, so a long pause or
    /// a phone on cellular while the computer is on Wi-Fi produces a 403 that only the
    /// phone can fix. Without this there was no route to a new URL at all: the phone's own
    /// recovery is gated to `activeDevice == .iphone`, `setActiveDevice` returns early when
    /// the device is unchanged, and `APIClient` would hand back the same cached string —
    /// so the browser retried a dead URL every five seconds indefinitely while its
    /// heartbeat convinced the phone everything was fine.
    ///
    /// Returns whether `externalStream` now holds a fresh URL for `videoId`.
    @discardableResult
    func refreshExternalStream(videoId: String) async -> Bool {
        guard canRefreshExternalStream(videoId: videoId), let track = currentTrack else { return false }
        streams.invalidate(videoId: videoId)
        guard let urlString = try? await resolveComputerStreamUrl(for: track) else { return false }
        return adoptRefreshedExternalStream(videoId: videoId, url: urlString)
    }

    /// Whether re-resolving this track's stream is a thing that makes sense right now.
    ///
    /// Downloaded tracks are served from this phone over the LAN and cannot go stale, so a
    /// reported failure there is not something a fresh URL will fix.
    func canRefreshExternalStream(videoId: String) -> Bool {
        guard activeDevice == .computer,
              let track = currentTrack,
              track.videoId == videoId else { return false }
        return !downloads.isDownloaded(track)
    }

    /// Publishes a stream URL that was resolved elsewhere.
    ///
    /// Split from the resolve so a caller that already has its own injectable way of
    /// reaching YouTube — `LocalControlServer`, whose route has to be testable without a
    /// network round trip — can still land the result in the one place everything reads.
    /// Going around this and holding the URL locally is what the server used to do, and it
    /// meant two different answers to "what should the browser load".
    ///
    /// Returns false if the moment has passed: the user can skip or switch device while a
    /// resolve is in flight, and publishing then would point the browser at a track it is
    /// no longer playing.
    @discardableResult
    func adoptRefreshedExternalStream(videoId: String, url: String) -> Bool {
        guard activeDevice == .computer, currentTrack?.videoId == videoId else { return false }
        externalStream = ExternalStream(videoId: videoId, url: url)
        return true
    }

    /// While the computer is the one making sound, this phone's session is set to mix
    /// rather than take the output route for itself. It is still playing audio in the
    /// background — the near-silent keep-alive clip that holds the server up — and a phone
    /// holding the route is what keeps AirPods paired to it instead of following the Mac.
    /// Mixing keeps the background-audio entitlement (the category is still `.playback`)
    /// without claiming to be what you're listening to.
    ///
    /// Note that automatic AirPods switching is the operating system's own heuristic; this
    /// removes a reason for it to stay put, but can't force the change.
    static func configureAudioSession(casting: Bool) {
        SystemAudioSession.shared.activate(casting: casting)
    }

    /// Left to its own devices AVFoundation happily pulls a whole progressive audio file
    /// down as fast as the network allows — so skipping a track twenty seconds in has
    /// usually already paid for all four minutes of it. Capping the read-ahead means a skip
    /// wastes at most this much audio. Kept well above the few seconds of buffer needed to
    /// ride out a bad patch of signal, and tightened further under Data Saver.
    static var forwardBufferDuration: TimeInterval {
        UserDefaults.standard.bool(forKey: InnerTubeClient.dataSaverDefaultsKey) ? 30 : 60
    }

    private func attach(url: URL, track: Track, resumeAt: Double = 0, autoplay: Bool? = nil, recordHistory: Bool = true) {
        // `wantsPlayback` unless a caller is explicit. Read at attach time, not captured
        // before the await, so a pause or a route change during the resolve wins.
        let shouldPlay = (autoplay ?? wantsPlayback) && !isInterrupted
        isResumingAfterDeviceSwitch = false
        // A successful attach clears any error from the attempt it replaces — otherwise a
        // recovered retry plays underneath "Couldn't play…".
        errorMessage = nil
        attachedURL = url
        engine.replaceItem(url: url, forwardBufferDuration: Self.forwardBufferDuration)
        if resumeAt > 0 {
            engine.seek(to: resumeAt)
            progress = resumeAt
        }
        if shouldPlay {
            // Reasserted on every attach: after an interruption or a route change the
            // session can be inactive, and `play()` into an inactive session is silent
            // while still reporting success.
            session.activate(casting: false)
            engine.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
        isLoading = false
        if recordHistory { sideEffects.recordPlay(track) }
        updateNowPlayingInfo()
    }

    /// A plausible number of seconds, or nil. Anything longer than a day is nonsense for a
    /// track, and letting it through means a later `Int(...)` conversion aborts the app.
    static func sanitisedSeconds(_ value: Double) -> Double? {
        guard value.isFinite, value >= 0, value <= 86_400 else { return nil }
        return value
    }

    /// Logs how much of the *outgoing* track was actually heard, right before it's
    /// replaced — using elapsed playback position, not the track's nominal length, so
    /// stats reflect real listening instead of crediting a full play for every skip.
    private func recordListeningStats() {
        guard let outgoing = currentTrack, progress > 0 else { return }
        let cap = outgoing.durationSeconds.map(Double.init) ?? progress
        // Clamped before the Int conversion, which traps on anything out of range.
        let elapsed = min(max(0, min(progress, cap)), 86_400)
        sideEffects.recordListening(outgoing, secondsPlayed: Int(elapsed))
    }
}
