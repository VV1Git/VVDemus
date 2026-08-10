import AVFoundation
import Combine
import MediaPlayer

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
    /// Playback volume for whichever device is currently producing sound, 0...1 — an
    /// attenuation *under* the system volume rather than a replacement for it, so the
    /// phone's hardware buttons keep working exactly as they did.
    ///
    /// Each device remembers its own level: the phone and a casting browser are different
    /// speakers, usually in different rooms, and a level that suits one rarely suits the
    /// other. Switching devices swaps which stored level this reflects rather than dragging
    /// one across. Both levels are kept here rather than half of them in the browser, so
    /// the phone can turn the computer down and a reloaded tab comes back where it was.
    @Published private(set) var volume: Double = 1
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
        lastPlaybackChangeAt = Date()
    }

    /// When playback last changed here. Carried in the handoff checkpoint so the "continue
    /// from…" offer can tell a device that stopped a minute ago from one that stopped just now.
    /// Every intent change bumps the epoch, so this is the one place it needs stamping.
    private(set) var lastPlaybackChangeAt = Date()

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

    /// Everything a user can ask of playback, in the shape the paired device receives it.
    ///
    /// Deliberately absolute where it can be: `setPlaying(Bool)` rather than a toggle, and
    /// `next(from:)` naming the track that was on screen when the button was pressed. A command
    /// crossing a network can arrive twice, or arrive after the owner has already moved on, and
    /// an absolute instruction is a no-op in both cases where a relative one skips a song or
    /// flips playback back on.
    /// `Equatable` so a test can say which intent it expected rather than matching on a string.
    enum PlaybackIntent: Equatable {
        case play(Track, context: [Track], contextTitle: String?, contextSeed: Track?)
        /// What the lock screen's separate Play and Pause buttons send.
        case setPlaying(Bool)
        /// What one button that does both sends. Kept distinct all the way to `SessionOwning`
        /// rather than resolved here: on a mirror this device's own `isPlaying` is false because
        /// its player is empty, so negating it here would send "play" every time. Only the relay
        /// knows what is actually on screen, so only the relay can turn this into an absolute
        /// instruction — which it does before anything goes on the wire.
        case togglePlaying
        case next(from: String?)
        case previous
        case seek(Double)
        case toggleShuffle
        case skipTo(videoId: String)
        case removeFromQueue(videoId: String)
        case addToQueue(Track)
        case playNext(Track)
        case setVolume(Double)
        /// Dragging a row to a new position. Carries the track as well as the indices: the
        /// owner's queue advances at every track boundary, so a position captured when the row
        /// rendered can be one out by the time the request lands — the same staleness the
        /// `expecting:` parameter guards against locally.
        case moveInQueue(QueueOrigin, from: Int, to: Int, track: Track?)
    }

    var autoplayEnabled = true

    /// contextQueue in its real (unshuffled) order — the source of truth restored when
    /// shuffle is turned off, and reshuffled fresh each time it's turned back on.
    private var orderedContextQueue: [Track] = []
    /// The track the current context was generated from, when it is a radio. Carried in the
    /// handoff checkpoint — and in the state snapshot — so the station survives moving between
    /// devices, and so a mirror can take it over if the device playing it disappears.
    private(set) var currentContextSeed: Track?

    /// Which of the two queues a track was taken from. Needed so `previous()` can put the
    /// track it's leaving back where it came from: it used to push everything onto
    /// `contextQueue`, so stepping back over a track the user had explicitly queued
    /// quietly demoted it out of the manual queue, and the next `advance()` played
    /// whatever else was in the manual queue instead of retracing the path.
    enum QueueOrigin: String, Equatable {
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
    private let sessionOwner: SessionOwning
    private let mirror: MirroredNowPlayingSource
    private let defaults: UserDefaults

    /// Offers an intent to the device that owns the session, and reports whether it went there.
    ///
    /// Every transport method opens with this. When it returns true the method must return
    /// immediately and change nothing: this device is a mirror, its queue is empty, and acting
    /// locally would start a second session rather than drive the one on screen.
    private func relayed(_ intent: PlaybackIntent) -> Bool {
        guard sessionOwner.relay(intent) else { return false }
        // The press has gone to the owner and nothing here will change until its reply lands, so
        // the lock screen is repainted from what the mirror already believes — which includes the
        // optimistic play state `PeerPlayback` holds for exactly that second. Without it, pausing
        // the Mac from the phone's lock screen leaves a pause button over a running clock until
        // the next poll comes back, which reads as the press having been swallowed.
        updateNowPlayingInfo()
        return true
    }

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
            notifications: .default,
            sessionOwner: PeerPlayback.shared,
            mirror: PeerMirroredNowPlaying.shared
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
        notifications: NotificationCenter,
        /// Defaulted so every existing test keeps building and keeps acting locally — see
        /// `NoSessionOwner`.
        sessionOwner: SessionOwning = NoSessionOwner.shared,
        /// Where the Now Playing slot is filled from while the *other* device owns the session.
        /// Defaulted to the empty one for the same reason `sessionOwner` is.
        mirror: MirroredNowPlayingSource = NoMirroredNowPlaying.shared,
        /// Injectable so a test's volume levels don't land in — or read out of — the real
        /// app's defaults. Everything else `PlayerService` persists already goes through a
        /// store it can be handed a fake of; two scalars didn't warrant a whole store.
        defaults: UserDefaults = .standard
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
        self.sessionOwner = sessionOwner
        self.mirror = mirror
        self.defaults = defaults

        loadVolumes()
        configureEngineCallbacks()
        configureMirrorCallback()
        configureRemoteCommandCenter()
        observeAudioSession()
    }

    /// The mirror's poll is the only thing that ticks on a device that owns nothing.
    ///
    /// `updateNowPlayingInfo` is otherwise reached from the periodic time observer, and that
    /// observer belongs to an engine which — on a mirror — has been detached and has no item to
    /// report time for. Left to itself the lock screen would show whatever was last published
    /// before the session was handed over, frozen, for as long as the Mac played.
    private func configureMirrorCallback() {
        mirror.onChange = { [weak self] in self?.updateNowPlayingInfo() }
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
            // Before `progress` is written: if this returns true the track is over and a new
            // one is loading, and the position belongs to an item that is on its way out.
            if self.advanceIfPlayedPastTheRealEnd(seconds) { return }
            self.progress = seconds
            self.limitPlaybackToTheRealEndIfNeeded()
            if let itemDuration = self.engine.itemDurationSeconds,
               let reconciled = Self.reconciledDuration(
                   itemDuration: itemDuration,
                   metadataSeconds: self.currentTrack?.durationSeconds
               ) {
                self.duration = reconciled
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

    // MARK: - Ending a track when the track actually ends

    /// Where forward playback should stop for the attached item, once decided. `nil` when the
    /// item's own end is trustworthy, which is the ordinary case.
    private var trimmedEnd: Double?
    /// Whether the decision has been made for the attached item. The item's duration is not
    /// known at attach time — the asset loads asynchronously — so the decision waits for the
    /// first tick that can see it, and must then not be remade on every tick after.
    private var hasDecidedPlaybackEnd = false

    /// Tells the engine to end the item at the real end of its audio, when AVFoundation's idea
    /// of the item's length cannot be true.
    ///
    /// Applied on the first tick where the item's duration is known, and once only.
    private func limitPlaybackToTheRealEndIfNeeded() {
        guard !hasDecidedPlaybackEnd, let itemDuration = engine.itemDurationSeconds else { return }
        hasDecidedPlaybackEnd = true
        guard let end = Self.trimmedPlaybackEnd(
            itemDuration: itemDuration,
            metadataSeconds: currentTrack?.durationSeconds
        ) else { return }
        NSLog("[PlayerService] item claims %.1fs for a track stated as %ds — ending playback at %.1fs",
              itemDuration, currentTrack?.durationSeconds ?? 0, end)
        trimmedEnd = end
        engine.forwardPlaybackEndTime = end
    }

    /// The belt to `forwardPlaybackEndTime`'s braces.
    ///
    /// `forwardPlaybackEndTime` is the right mechanism: AVFoundation ends the item itself, so
    /// the queue advances through exactly the same path as an untrimmed track, with no timer of
    /// ours to keep running while the screen is off. But the whole of the bug being fixed here
    /// was one end-of-track trigger not firing when it should have, and the price of a second,
    /// independent trigger is one comparison per tick. If playback runs past the real end
    /// anyway, that is the end of the track.
    ///
    /// - Returns: whether the queue was advanced, in which case the caller must not go on to
    ///   write this position anywhere.
    private func advanceIfPlayedPastTheRealEnd(_ seconds: Double) -> Bool {
        guard let trimmedEnd, seconds > trimmedEnd + Self.playedPastEndMargin,
              isPlaying, !isLoading else { return false }
        NSLog("[PlayerService] ran %.1fs past a %.1fs end without the engine reporting it — advancing",
              seconds - trimmedEnd, trimmedEnd)
        // Cleared first: `advance()` can re-enter this observer, and a second advance for the
        // same track would skip one.
        self.trimmedEnd = nil
        advance()
        return true
    }

    /// How far past the real end playback may run before the safety net calls it over. Wider
    /// than the gap between two periodic ticks — they are half a second apart, so an ordinary
    /// overshoot is not a missed trigger — and narrow enough to be inaudible.
    nonisolated static let playedPastEndMargin: Double = 1.5

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

    /// Keeps `isPlaying` describing what the engine is actually doing — in both directions.
    ///
    /// The engine stopping on its own (a stall, an interruption the app didn't see, the
    /// route going away) has to be reflected or the UI, the lock screen and the AirPods
    /// gesture all end up out of step with reality.
    ///
    /// And equally the other way round, which this used to miss. `AVPlayer.timeControlStatus`
    /// changes asynchronously, so a reading taken in the instant after `attach` calls `play()`
    /// can still say `.paused` about an instruction that is landing — and a reading is taken
    /// in exactly that instant, because AVFoundation invokes the periodic observer on every
    /// time jump and whenever playback starts or stops, and replacing the item at a track
    /// boundary is both. Correcting only a true that should be false made one such stale
    /// reading permanent: sound arrived a moment later underneath an `isPlaying` of false, and
    /// nothing in the app ever raised the flag again.
    ///
    /// What that cost was a press, everywhere at once, because every control reads this flag.
    /// The lock screen's `.pause` was dropped outright, its `.play` "resumed" music that had
    /// never stopped, and `advanceIfPlayedPastTheRealEnd` and `handleStall` both switched
    /// themselves off — so a song that had just started needed a pause, a play and a second
    /// pause before anything happened.
    private func reconcileIsPlayingWithEngine() {
        guard activeDevice == .iphone, !isLoading, !isResumingAfterDeviceSwitch, currentTrack != nil else { return }
        // An interruption is handled by its own notification, which knows whether to
        // resume; don't let the periodic tick race it.
        guard !isInterrupted else { return }
        let enginePlaying = engine.isEnginePlaying
        guard isPlaying != enginePlaying else { return }
        isPlaying = enginePlaying
        updateNowPlayingInfo()
    }

    // MARK: - Lock screen / Control Center / AirPods gestures

    /// AirPods (and most Bluetooth headsets) don't have their own protocol for transport:
    /// a stem press or tap arrives as one of these remote commands. All of them are
    /// registered — a missing `togglePlayPause` in particular means a single tap does
    /// nothing at all, which is the control people use most.
    private func configureRemoteCommandCenter() {
        // `setPlayback` rather than a toggle guarded by `isPlaying`: these two are absolute
        // instructions, and gating them on the app's own record of playback is what let a
        // press disappear without trace. When that record had drifted — which it can, since
        // `AVPlayer` reports its state asynchronously — `.pause` did nothing at all and
        // returned `.success`, so iOS was satisfied and the music carried on.
        commandCenter.setHandler(for: .play) { [weak self] _ in
            guard let self, self.hasSomethingToControl else { return .noSuchContent }
            self.setPlayback(playing: true)
            return .success
        }
        commandCenter.setHandler(for: .pause) { [weak self] _ in
            guard let self, self.hasSomethingToControl else { return .noSuchContent }
            self.setPlayback(playing: false)
            return .success
        }
        commandCenter.setHandler(for: .togglePlayPause) { [weak self] _ in
            guard let self, self.hasSomethingToControl else { return .noSuchContent }
            self.togglePlayPause()
            return .success
        }
        commandCenter.setHandler(for: .nextTrack) { [weak self] _ in
            // Returning `.success` with nothing loaded made a double-tap on an idle set of
            // AirPods look handled, so the system never fell back to anything else.
            guard let self, self.hasSomethingToControl else { return .noSuchContent }
            self.advance()
            return .success
        }
        commandCenter.setHandler(for: .previousTrack) { [weak self] _ in
            guard let self, self.hasSomethingToControl else { return .noSuchContent }
            self.previous()
            return .success
        }
        commandCenter.setHandler(for: .changePlaybackPosition) { [weak self] position in
            guard let self, let position, self.hasSomethingToControl else { return .commandFailed }
            self.seek(to: position)
            return .success
        }
        for kind in RemoteCommandKind.allCases {
            commandCenter.setEnabled(true, for: kind)
        }
        commandCenter.disableUnhandledCommands()
    }

    /// Whether a transport press has anything to land on — a track of this device's own, or the
    /// owner's track this device is mirroring.
    ///
    /// A mirror has no `currentTrack` by design, so guarding these handlers on that alone answers
    /// every lock-screen button and every AirPods gesture with `.noSuchContent` for as long as the
    /// paired device is the one playing — a phone showing the Mac's song above controls that
    /// refuse to do anything about it. Nothing else in the handlers needs widening:
    /// `setPlayback`, `advance`, `previous`, `seek` and `togglePlayPause` all open with
    /// `relayed(…)`, so they reach the owner by themselves.
    private var hasSomethingToControl: Bool {
        currentTrack != nil || mirror.nowPlaying != nil
    }

    /// Fills the Now Playing slot from whichever session this device is showing.
    ///
    /// The mirrored branch is not a second implementation of the lock screen: it lands in the same
    /// `NowPlayingPublishing` collaborator, through the same artwork cache, so there is exactly one
    /// thing that can be holding the slot at any moment. Consulted only when there is no local
    /// track, which is also what keeps the ordinary playing case free of any peer bookkeeping.
    private func updateNowPlayingInfo() {
        if let track = currentTrack {
            publishNowPlaying(
                track: track,
                duration: duration > 0 ? duration : nil,
                elapsed: progress,
                rate: isPlaying ? 1.0 : 0.0
            )
        } else if let mirrored = mirror.nowPlaying {
            publishNowPlaying(
                track: mirrored.track,
                duration: mirrored.duration,
                elapsed: mirrored.elapsed,
                rate: mirrored.isPlaying ? 1.0 : 0.0
            )
        } else {
            nowPlaying.clear()
        }
    }

    private func publishNowPlaying(track: Track, duration: Double?, elapsed: Double, rate: Double) {
        let artwork = artworkCache[track.id]
        if artwork == nil { loadArtwork(for: track) }
        nowPlaying.publish(
            NowPlayingSnapshot(
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: duration,
                elapsed: elapsed,
                rate: rate
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
            guard let data, let image = PlatformImage(data: data) else {
                self.failedArtworkIds.insert(track.id)
                return
            }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.cacheArtwork(artwork, for: track.id)
            // The mirrored track counts as still being the one on screen. Without it the artwork
            // for the Mac's song would sit in the cache unused until the peer's next *change* —
            // a paused mirror republishes nothing, so a track paused before its image arrived
            // would show none for the length of the pause.
            if self.currentTrack?.id == track.id || self.mirror.nowPlaying?.track.id == track.id {
                self.updateNowPlayingInfo()
            }
        }
    }

    /// Same (url, pixel-size) keying `RemoteImage` uses for its ~300pt hero images (Now
    /// Playing, Mix headers), so lock-screen artwork and on-screen artwork for the same
    /// track share one disk cache entry instead of each fetching their own copy.
    nonisolated static func artworkCacheKey(for thumbnailUrl: String) -> String {
        let targetPixels = RemoteImage.targetPixelSize(for: 300, displayScale: PlatformScreen.scale)
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

    // `AVAudioSession` is iOS-only, and so is every event it reports: a Mac has no phone call
    // to interrupt playback, no AirPods-pulled-from-ears route change, and no media-services
    // daemon to restart. The Mac takes the no-op at the bottom of this section so `init` need
    // not know the difference.
    #if os(iOS)
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
    #else
    private func observeAudioSession() {}
    #endif

    /// Rare, but it does happen (and reliably under memory pressure on older phones): the
    /// media daemon restarts and every AVFoundation object the app holds becomes inert.
    /// Without rebuilding, playback is dead until the app is force-quit.
    private func handleMediaServicesReset() {
        // The player object itself is dead after a reset, not just its item — rebuild
        // before anything else, or the reattach below plays into a corpse.
        engine.rebuild()
        // The replacement player is at full volume. Nothing about a media daemon restarting
        // is the user asking for that, and it happens with the phone in a pocket — left
        // unrestored, a track being listened to quietly comes back at 100% mid-song.
        engine.volume = deviceVolumes[.iphone] ?? 1
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
            stopEngineOnGivingUp()
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
        isLoading = true
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let urlString = try await self.streams.streamURL(videoId: track.videoId)
                guard !Task.isCancelled, self.currentTrack?.videoId == track.videoId else { return }
                guard let url = URL(string: urlString) else { throw APIError.invalidURL }
                // Both read now rather than captured before the await, for the same reason:
                // this Task is seconds long, and anything the user did inside it is newer
                // than anything sampled before it started. A scrub would otherwise be
                // reverted to wherever playback died, and a pause undone outright — the
                // music restarting by itself moments after a press that appeared to do
                // nothing. Deliberately `wantsPlayback` and not `isPlaying`: playback is
                // stopped at this point by definition, so only the intent survives.
                self.attach(url: url, track: track, resumeAt: self.progress,
                            autoplay: self.wantsPlayback, recordHistory: false)
            } catch {
                guard !Task.isCancelled else { return }
                self.stopEngineOnGivingUp()
                self.isLoading = false
                self.isPlaying = false
                self.errorMessage = "Couldn't play \"\(track.title)\". Check your connection and try again."
                self.updateNowPlayingInfo()
            }
        }
    }

    /// Stops the player when the app gives up on the current track.
    ///
    /// Writing `isPlaying = false` is not the same as stopping. Reached from `handleStall`
    /// the item hasn't failed, it has run dry, and a stalled `AVPlayer` is still an armed one
    /// — `.waitingToPlayAtSpecifiedRate` means the rate is 1 and it is only waiting for
    /// bytes. Leaving it alone meant coming back into coverage resumed the track by itself,
    /// audibly, under a UI showing an error and a play button; and nothing ever repaired the
    /// flag, because `reconcileIsPlayingWithEngine` only corrects a true that should be
    /// false. The lock screen's pause then did nothing (`.pause` acts only `if isPlaying`),
    /// play silently repaired the flag without changing the sound, and the press after that
    /// finally paused — two presses to pause, for the rest of the track.
    private func stopEngineOnGivingUp() {
        // For the same reason `fallBackToPhone` does it: the app has just declared playback
        // stopped, so a later reattach must not start the music again on its own.
        wantsPlayback = false
        engine.pause()
    }

    // MARK: - Playback entry points

    /// Play `track`, queuing up whatever comes after it in `context` (the list it was tapped from).
    ///
    /// `contextSeed` is the track a radio was generated from, when the context is a radio.
    /// Passing it here is what files the station under Your Radio — previously that only
    /// happened via the Play button on a radio's own screen, so tapping a song inside a
    /// radio, or starting one from the web remote, left no trace of the station at all.
    func play(track: Track, context: [Track] = [], contextTitle: String? = nil, contextSeed: Track? = nil) {
        // Sent to the owner rather than played here, exactly as pressing a track in the web
        // remote posts `/api/play` to the phone. Two apps that both start playing are two
        // sessions, and the point of the pairing is that there is one.
        if relayed(.play(track, context: context, contextTitle: contextTitle, contextSeed: contextSeed)) { return }
        // Starting something here is the clearest possible statement that this device is in
        // charge — the same rule as before, now recorded rather than inferred.
        sessionOwner.claimSession()
        if let contextSeed { sideEffects.recordRadioSeed(contextSeed) }
        // Remembered so a handoff can carry *which radio* is playing. A radio is identified by
        // its seed, and without it the other device receives the queue as a loose list of songs
        // with no station behind it.
        currentContextSeed = contextSeed
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

    // MARK: - Handing playback between paired devices

    /// Everything the other device needs to carry on from here.
    ///
    /// The unshuffled order travels alongside the shuffled one on purpose: without it, turning
    /// shuffle off after a handoff could not restore the real running order, because the
    /// receiving device would never have seen it.
    func nowPlayingCheckpoint() -> NowPlayingCheckpoint {
        NowPlayingCheckpoint(
            peerId: PeerIdentity.shared.peerId,
            isDesktop: PeerIdentity.shared.isDesktop,
            // When playback last *changed*, not when this was read. Stamping it here made
            // `NowPlayingCheckpoint.preferred` compare "now" against "now" — both checkpoints are
            // built within a round trip of each other — so its tiebreak decided nothing and the
            // resume offer was a coin flip.
            updatedAt: lastPlaybackChangeAt,
            currentTrack: currentTrack,
            progress: progress,
            isPlaying: isPlaying,
            manualQueue: manualQueue,
            contextQueue: contextQueue,
            orderedContextQueue: orderedContextQueue,
            isShuffling: isShuffling,
            queueContextTitle: queueContextTitle,
            contextSeed: currentContextSeed
        )
    }

    /// Takes over from `checkpoint` — used both by an explicit handoff and by the
    /// "continue from…" prompt.
    func adopt(checkpoint: NowPlayingCheckpoint, autoplay: Bool) {
        guard let track = checkpoint.currentTrack else { return }
        if let seed = checkpoint.contextSeed { sideEffects.recordRadioSeed(seed) }
        currentContextSeed = checkpoint.contextSeed
        manualQueue = checkpoint.manualQueue
        orderedContextQueue = checkpoint.orderedContextQueue
        contextQueue = checkpoint.contextQueue
        isShuffling = checkpoint.isShuffling
        queueContextTitle = checkpoint.queueContextTitle

        load(track, autoplay: autoplay)
        // *After* `load`, deliberately. `beginLoad` resets `progress` to 0, and the load task
        // reads `progress` when it finally attaches the item — which happens after this returns,
        // since resolving the stream URL is asynchronous. Setting it here is therefore what the
        // attach picks up as its resume point; setting it before would be wiped.
        progress = max(0, checkpoint.progress)
    }

    /// Gives the session up entirely, because the paired device has taken it over.
    ///
    /// Not a pause, and that distinction is the whole bug this fixes. A paused device still holds
    /// a track and a queue, and two devices that both hold one is precisely the state in which
    /// neither can be told it is mirroring — so handing playback over used to be a one-way trip
    /// that left the two permanently unable to drive each other.
    ///
    /// Called only once the receiver has confirmed it is playing, so a failed handoff cannot
    /// leave the music nowhere at all.
    func releaseSession() {
        // Before the track is forgotten. Stats are otherwise credited when one track replaces
        // another, and the track handed to the other device is never replaced here — so the
        // seconds listened to before the handoff would simply vanish.
        recordListeningStats()
        PairLog.info("releasing the session: \(currentTrack?.title ?? "nothing") at \(String(format: "%.1f", progress))s")
        bumpPlaybackEpoch()
        loadTask?.cancel()
        loadTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        // Detached, not paused: a paused engine still holds the item and still resumes on the
        // next `play()`, which is exactly what must not happen on a device that has handed over.
        engine.detach()
        attachedURL = nil
        currentTrack = nil
        manualQueue = []
        contextQueue = []
        orderedContextQueue = []
        backStack = []
        queueContextTitle = nil
        currentContextSeed = nil
        upNextTrack = nil
        upNextStream = nil
        externalStream = nil
        progress = 0
        duration = 0
        isPlaying = false
        wantsPlayback = false
        isLoading = false
        isStoppedAtEndOfQueue = false
        isResumingAfterDeviceSwitch = false
        pendingPlayIntent = nil
        // The output comes home too. Handing the session over while a browser was casting used to
        // leave this device parked on `.computer` with an empty player — so the browser went on
        // playing a track nothing here still owned, and whenever the session came back it was
        // routed to the browser rather than to this device's own speaker.
        //
        // Assigned rather than going through `setActiveDevice`, which would try to reattach the
        // outgoing track to bring it home; there is deliberately nothing left to bring.
        if activeDevice != .iphone {
            activeDevice = .iphone
            volume = deviceVolumes[.iphone] ?? 1
            engine.volume = volume
            session.activate(casting: false)
        }
        // Republished rather than cleared. Nothing is playing *here*, and the slot must stop
        // offering transport for a track this device no longer has — but by the time the poll
        // that hands the session over reaches this, the mirror already knows what the other
        // device is playing, so the right end state is the owner's track and not an empty slot.
        // Clearing here and letting the next poll fill it back in is the version that fights
        // itself: a blank lock screen for up to a second, once per handoff, and a permanent
        // flicker for anything that releases and re-mirrors repeatedly.
        //
        // Falls back to `clear()` on its own when there is no mirrored session either, which is
        // every case that isn't a handoff.
        updateNowPlayingInfo()
    }

    // MARK: - Shuffle

    /// Toggling on shuffles the remaining context queue fresh (so re-enabling after
    /// disabling produces a new order, not the last shuffle); toggling off restores the
    /// real order. Manually queued tracks are never shuffled — the user chose that order.
    func toggleShuffle() {
        if relayed(.toggleShuffle) { return }
        isShuffling.toggle()
        contextQueue = isShuffling ? orderedContextQueue.shuffled() : orderedContextQueue
        prefetchUpNext()
    }

    // MARK: - Queue manipulation

    /// Removing the track from `contextQueue`/`orderedContextQueue` first (if it's already
    /// there) keeps a track from ever sitting in two queues at once — without this, a
    /// track queued explicitly could get played once from the manual queue and then
    /// played *again* later when the context queue reached its own untouched copy.
    func addToQueue(_ track: Track) {
        if relayed(.addToQueue(track)) { return }
        contextQueue.removeAll { $0.id == track.id }
        orderedContextQueue.removeAll { $0.id == track.id }
        // Already queued by hand — queuing it again is a no-op rather than a second copy.
        // Two identical entries played the track twice and made the row identity ambiguous.
        guard !manualQueue.contains(where: { $0.id == track.id }) else { return }
        manualQueue.append(track)
        prefetchUpNext()
    }

    func playNext(_ track: Track) {
        if relayed(.playNext(track)) { return }
        manualQueue.removeAll { $0.id == track.id }
        contextQueue.removeAll { $0.id == track.id }
        orderedContextQueue.removeAll { $0.id == track.id }
        manualQueue.insert(track, at: 0)
        prefetchUpNext()
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
        // Addressed by id across the wire, never by position: the two devices' queues are the
        // same list but a row's index is captured when it renders, and the owner is the only one
        // whose indices are still true by the time the request lands.
        if let track, relayed(.removeFromQueue(videoId: track.videoId)) { return }
        guard let resolved = Self.resolveIndex(index, expecting: track, in: manualQueue) else { return }
        manualQueue.remove(at: resolved)
        prefetchUpNext()
    }

    private static func resolveIndex(_ index: Int, expecting track: Track?, in queue: [Track]) -> Int? {
        if queue.indices.contains(index), track == nil || queue[index].id == track?.id { return index }
        guard let track else { return nil }
        return queue.firstIndex { $0.id == track.id }
    }

    func removeFromContextQueue(at index: Int, expecting track: Track? = nil) {
        if let track, relayed(.removeFromQueue(videoId: track.videoId)) { return }
        guard let index = Self.resolveIndex(index, expecting: track, in: contextQueue) else { return }
        let removed = contextQueue.remove(at: index)
        // Mirror the removal in the unshuffled order, one copy only.
        if let mirrored = orderedContextQueue.firstIndex(where: { $0.id == removed.id }) {
            orderedContextQueue.remove(at: mirrored)
        }
        prefetchUpNext()
    }

    /// Removes one queue entry, addressed by track rather than by position — the web remote
    /// has no position-carrying route, so this is what it has to use.
    ///
    /// One entry, not every entry with that id. A radio mix or a Home shelf can repeat a
    /// videoId, and the `removeAll`-across-all-three-queues this used to do meant removing
    /// one such row silently took every other copy with it. Manual queue first, then
    /// context, matching the order the two are displayed in.
    /// Finds a track the other device named by id.
    ///
    /// Commands from the paired device carry a `videoId` rather than a whole `Track`: the peer
    /// is mirroring this device's queue, so the authoritative copy of every field is already
    /// here, and echoing it back only invites the two to disagree.
    func queuedTrack(videoId: String) -> Track? {
        if let track = manualQueue.first(where: { $0.videoId == videoId }) { return track }
        if let track = contextQueue.first(where: { $0.videoId == videoId }) { return track }
        return currentTrack?.videoId == videoId ? currentTrack : nil
    }

    func removeFromQueue(_ track: Track) {
        if relayed(.removeFromQueue(videoId: track.videoId)) { return }
        if let index = manualQueue.firstIndex(where: { $0.id == track.id }) {
            removeFromManualQueue(at: index)
        } else if let index = contextQueue.firstIndex(where: { $0.id == track.id }) {
            removeFromContextQueue(at: index)
        }
    }

    func moveInManualQueue(from source: IndexSet, to destination: Int) {
        if let first = source.first,
           relayed(.moveInQueue(.manual, from: first, to: destination,
                                track: manualQueue.indices.contains(first) ? manualQueue[first] : nil)) { return }
        manualQueue.move(fromOffsets: source, toOffset: destination)
        prefetchUpNext()
    }

    func moveInContextQueue(from source: IndexSet, to destination: Int) {
        if let first = source.first,
           relayed(.moveInQueue(.context, from: first, to: destination,
                                track: contextQueue.indices.contains(first) ? contextQueue[first] : nil)) { return }
        // Read before the move, because both name rows in the list the drag was measured
        // against: `destination` is a pre-removal offset, so the row standing there is the one
        // the drop lands in front of.
        let moved = source.first.flatMap { contextQueue.indices.contains($0) ? contextQueue[$0] : nil }
        let anchor: QueueMove.Anchor = contextQueue.indices.contains(destination)
            ? .before(contextQueue[destination].videoId)
            : .end
        let before = contextQueue.map(\.videoId)

        contextQueue.move(fromOffsets: source, toOffset: destination)
        guard isShuffling else {
            // Not shuffling, so the two lists are the same list and this is the whole of it.
            orderedContextQueue = contextQueue
            prefetchUpNext()
            return
        }
        // The same move, re-resolved against the real order. This used to be skipped entirely
        // while shuffling — the reorder went into `contextQueue` only, and `toggleShuffle`
        // restores `orderedContextQueue` wholesale, so switching shuffle off silently threw the
        // edit away. The two lists are different permutations of the same tracks, so an index
        // cannot carry across; what carries is "this song plays in front of that one", which is
        // the whole of what the drag said.
        //
        // Gated on the shuffled list actually changing. Dropping a row back onto itself moves
        // nothing here — `toOffset` of the row's own offset, or the one after it, is a no-op —
        // but it still names the row it was let go in front of, and that pairing *is* a real
        // constraint in the other order. Ungated, releasing a row without moving it rearranged
        // the unshuffled queue behind the user's back.
        guard contextQueue.map(\.videoId) != before else {
            prefetchUpNext()
            return
        }
        let decision = QueueMove.reorder(
            orderedContextQueue.map(\.videoId), moving: moved?.videoId, to: anchor
        )
        if let source = decision.source {
            orderedContextQueue.move(fromOffsets: IndexSet(integer: source), toOffset: decision.destination)
        }
        prefetchUpNext()
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
        if relayed(.skipTo(videoId: track.videoId)) { return }
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
        if let track, relayed(.skipTo(videoId: track.videoId)) { return }
        guard let index = Self.resolveIndex(index, expecting: track, in: manualQueue) else { return }
        let target = manualQueue[index]
        manualQueue.removeFirst(index + 1)
        load(target, origin: .manual)
    }

    func skipToContextQueueEntry(at index: Int, expecting track: Track? = nil) {
        if let track, relayed(.skipTo(videoId: track.videoId)) { return }
        guard let index = Self.resolveIndex(index, expecting: track, in: contextQueue) else { return }
        let target = contextQueue[index]
        let consumed = Array(contextQueue.prefix(index + 1))
        contextQueue.removeFirst(index + 1)
        load(target, origin: .context, orderedIndex: consumeFromOrderedQueue(consumed))
    }

    // MARK: - Transport

    func togglePlayPause() {
        if relayed(.togglePlaying) { return }
        guard currentTrack != nil else { return }
        setPlayback(playing: !isPlaying)
    }

    /// Absolute transport: what the lock screen's and Control Centre's separate buttons send,
    /// and what a toggle resolves to.
    ///
    /// Asking for the state the app already believes it is in is not a no-op. `isPlaying` is
    /// the app's *record* of playback and the engine is the thing making the sound; the two
    /// can drift apart, and a control that reads only the record spends the press on
    /// bookkeeping instead of on the music. That is what a dropped `.pause` was — nothing
    /// happened and iOS was told the command had succeeded, so it had no reason to try
    /// anything else.
    func setPlayback(playing shouldPlay: Bool) {
        if relayed(.setPlaying(shouldPlay)) { return }
        guard currentTrack != nil else { return }
        guard shouldPlay != isPlaying else { return restatePlaybackToEngine(shouldPlay) }
        // See `isStoppedAtEndOfQueue`: starting again from the end of a finished queue is a
        // restart, not a resume. Cleared unconditionally — once the user has touched
        // play/pause, whatever happens next is an ordinary transport state.
        let restartsFinishedTrack = isStoppedAtEndOfQueue && shouldPlay
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
            isPlaying = shouldPlay
            pendingPlayIntent = (playing: isPlaying, at: Date())
            onComputerCommand?(.toggle)
            updateNowPlayingInfo()
            return
        }
        // Between items during a hand-back: touching the player would briefly resume the
        // outgoing item's audio, and the value set here is what the reattach reads.
        if isResumingAfterDeviceSwitch {
            isPlaying = shouldPlay
            updateNowPlayingInfo()
            return
        }
        // Bumped on the phone's own play/pause too, not just while casting. The epoch is
        // what a browser uses to recognise reports describing a state the phone has
        // already moved past, and a pause taken here while a browser was still connected
        // (about to be handed playback, or just watching) left the two agreeing on an
        // epoch that no longer described the same thing.
        bumpPlaybackEpoch()
        if !shouldPlay {
            wantsPlayback = false
            engine.pause()
            isPlaying = false
        } else {
            wantsPlayback = true
            // Asking for playback ends the interruption as far as this app is concerned.
            // iOS doesn't promise an `.ended` for every `.began` — one the app is suspended
            // through, or whose owner never hands the route back, never delivers one — and
            // until `beginLoad` clears it a whole track later the flag keeps describing a
            // state the user has already overruled: `attach` refuses to start the item a
            // mid-track recovery just resolved, and the reconcile that notices the engine
            // stopping by itself stays switched off.
            isInterrupted = false
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

    /// The app already believes it is doing what was just asked for — so say it to the engine
    /// again, and only if the engine disagrees. That disagreement is the whole reason the
    /// press would otherwise have been dropped, and it is invisible from `isPlaying` alone.
    ///
    /// Not reached while a load is in flight, a hand-back is in progress or an interruption is
    /// running: in all three the flag is deliberately the *intent* and the engine deliberately
    /// out of step with it, and restating anything there would resume the outgoing track or
    /// play over a phone call.
    private func restatePlaybackToEngine(_ shouldPlay: Bool) {
        guard activeDevice == .iphone, !isLoading, !isResumingAfterDeviceSwitch, !isInterrupted else { return }
        guard engine.isEnginePlaying != shouldPlay else { return }
        if shouldPlay {
            wantsPlayback = true
            session.activate(casting: false)
            engine.play()
        } else {
            wantsPlayback = false
            engine.pause()
        }
        updateNowPlayingInfo()
    }

    func seek(to seconds: Double) {
        if relayed(.seek(seconds)) { return }
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
        // Nobody is looking at the phone when this fires, so the lock screen has to be right
        // the moment they do look. Nothing else covers the hand-back: the periodic tick is
        // gated off while `isResumingAfterDeviceSwitch`, and the next publish is the reattach
        // a network round trip later. Left unsaid, iOS keeps drawing the casting-era rate 1 —
        // a pause button over silence, with the clock still running — and the press that
        // invites is dropped by `.pause`'s own `isPlaying` guard. Published after
        // `setActiveDevice` so the snapshot describes the state the phone settled into.
        updateNowPlayingInfo()
    }

    // MARK: - Volume

    static func volumeDefaultsKey(for device: PlaybackDevice) -> String {
        "volume.\(device.rawValue)"
    }

    /// The stored level for each device, so switching between them restores the level that
    /// device was last left at rather than carrying one across.
    private var deviceVolumes: [PlaybackDevice: Double] = [:]

    private static func clampVolume(_ value: Double) -> Double {
        // A non-finite value is a corrupt default or a malformed request body, not a
        // request for silence, so it falls back to full rather than to 0.
        guard value.isFinite else { return 1 }
        return min(max(value, 0), 1)
    }

    private func loadVolumes() {
        for device in [PlaybackDevice.iphone, .computer] {
            // `object(forKey:)`, not `double(forKey:)`: an absent key reads as 0.0 there,
            // which is silence — a fresh install would have started muted.
            let stored = defaults.object(forKey: Self.volumeDefaultsKey(for: device)) as? Double
            deviceVolumes[device] = stored.map(Self.clampVolume) ?? 1
        }
        volume = deviceVolumes[activeDevice] ?? 1
        // The engine always holds the *phone's* level, whichever device is active — while
        // casting its item is merely paused, and this is the level it comes back at.
        engine.volume = deviceVolumes[.iphone] ?? 1
    }

    /// Sets the level for the device currently producing sound, and remembers it for that
    /// device alone.
    func setVolume(_ newValue: Double) {
        // The trim belongs to whichever device is making the sound, so on a mirror the slider has
        // to reach across — left local it would quietly set a level for a player that is empty.
        if relayed(.setVolume(newValue)) { return }
        let clamped = Self.clampVolume(newValue)
        let device = activeDevice
        deviceVolumes[device] = clamped
        volume = clamped
        // While casting, this is the *computer's* level: it belongs to the browser's
        // `<audio>` element (which reads it off the state snapshot), not to an AVPlayer
        // that is producing no sound and whose own level must survive the handoff.
        if device == .iphone { engine.volume = clamped }
        defaults.set(clamped, forKey: Self.volumeDefaultsKey(for: device))
    }

    func setActiveDevice(_ device: PlaybackDevice) {
        guard device != activeDevice else { return }
        PairLog.info("output moving \(activeDevice.rawValue) -> \(device.rawValue): track=\(currentTrack?.title ?? "none") at \(String(format: "%.1f", progress))s playing=\(isPlaying)")
        activeDevice = device
        // Before anything can make a sound on the new device: the slider in both UIs reads
        // this, and it must already say what the incoming device was last left at.
        volume = deviceVolumes[device] ?? 1
        if device == .iphone { engine.volume = volume }
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
            prefetchUpNext()
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
            // The prefetched URL is deliberately kept. It used to be dropped here because
            // only the browser had any use for one; now the phone attaches from it too, and
            // it is a URL for the same next track either way — throwing it away just put the
            // silence back into the first transition after every handoff.
            prefetchUpNext()
            guard let track = currentTrack else { return }
            // Deliberately always a fresh attach, never a seek-and-play on the item the engine
            // was left holding. That shortcut would save the re-buffer, but `attachedURL` is the
            // app's record of what it last handed the engine, not proof the engine still has it:
            // a media-services reset while casting rebuilds the player and its reattach is gated
            // to `activeDevice == .iphone`, so the record outlives the item. Seeking into that
            // plays nothing, silently, with no failure to recover from.
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
        if relayed(.next(from: from)) { return }
        guard let from else { return advance() }
        guard currentTrack?.videoId == from else { return }
        advance()
    }

    func advance() {
        // `from` names the track the press was made against so the owner can ignore a next it
        // has already handled — see `advanceIfCurrent`. On a mirror this device has no current
        // track, so the relay fills in the one actually on screen.
        if relayed(.next(from: currentTrack?.videoId)) { return }
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
        // Stopping the player, not only the flag. Reached from the safety net in
        // `advanceIfPlayedPastTheRealEnd` the player is still running — running past the real
        // end of the audio is what made that net fire — so writing `isPlaying = false` alone
        // left the app claiming to be stopped over a player that was not. The reconcile now
        // repairs that kind of disagreement, and left to itself it would repair this one the
        // wrong way round, by declaring playback resumed.
        if activeDevice == .iphone { engine.pause() }
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
        if relayed(.previous) { return }
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
                // radio screen, or the web remote fetching it) instead of always re-fetching.
                // The whole radio is taken, not the 25 autoplay strictly needs: the response
                // is the same fixed page either way, and this fetch is frequently the one
                // that populates the cache for that seed's radio screen.
                let mix: [Track]
                if let cached = self.sideEffects.cachedRadio(seedVideoId: seed.videoId), !cached.isEmpty {
                    mix = cached
                } else {
                    let fetched = try await self.radios.radio(
                        videoId: seed.videoId,
                        limit: InnerTubeClient.radioLength
                    )
                    // `cacheRadioIfAbsent`, so autoplay quietly refilling the queue can never
                    // replace the mix shown on that radio's screen with a different selection.
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
                // Read after the fetch, not before it: the radio round trip takes seconds,
                // and a pause taken inside that window is newer than the decision to advance.
                // Asserting playback here regardless is what restarted the music by itself
                // moments after a press that appeared to do nothing.
                self.load(next, autoplay: self.wantsPlayback)
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
    private func load(_ track: Track, origin: QueueOrigin = .context, orderedIndex: Int = 0,
                      autoplay: Bool = true) {
        pushOntoBackStack()
        currentTrackOrigin = origin
        currentTrackOrderedIndex = orderedIndex
        beginLoad(track, autoplay: autoplay)
    }

    private func pushOntoBackStack() {
        guard let outgoing = currentTrack else { return }
        backStack.append((outgoing, currentTrackOrigin, currentTrackOrderedIndex))
        if backStack.count > backStackLimit {
            backStack.removeFirst(backStack.count - backStackLimit)
        }
    }

    private func beginLoad(_ track: Track, autoplay: Bool = true) {
        loadTask?.cancel()
        // Starting a track is a request to play it — true whenever a person started it, which
        // is every caller but one. `continueAutoplay` is the exception: seconds of radio fetch
        // sit between the decision to advance and this call, and a pause taken inside that
        // window is newer than the decision, so it passes the intent it was chosen under
        // rather than asserting a fresh one.
        wantsPlayback = autoplay
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

        // Downloaded tracks play straight from disk — no network, no data usage. Checked
        // before the prefetch below, which is why that branch can never hand AVPlayer the
        // browser-facing `/api/audio/local` path a downloaded track prefetches to.
        if let localURL = downloads.localFileURL(for: track) {
            attach(url: localURL, track: track)
            // Still worth doing: this track needed no network, but the one after it may.
            prefetchUpNext()
            return
        }

        // The URL was resolved while the previous track was still playing, so there is
        // nothing to wait for — attach now. This is what closes the silence between tracks;
        // going back to the network here would spend a round trip re-fetching a string
        // already in hand.
        if let prefetched = upNextStream, prefetched.videoId == track.videoId,
           let url = URL(string: prefetched.url) {
            loadTask?.cancel()
            attach(url: url, track: track, resumeAt: progress)
            prefetchUpNext()
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
                // Only once this track is attached and playing. Started any earlier, the
                // speculative request for the *next* track competes for bandwidth with the
                // one the user is waiting to hear.
                self.prefetchUpNext()
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
            // Audio is genuinely starting, so the intent flag has to say so. Left unset here,
            // it stayed false through an entire casting session and the reads that ask "does
            // the user still want playback" — the autoplay hand-off at a track boundary, the
            // expired-URL retry — silently answered no and stopped the music.
            wantsPlayback = true
            updateNowPlayingInfo()
            prefetchUpNext()
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
                self.wantsPlayback = true
                self.updateNowPlayingInfo()
                self.prefetchUpNext()
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

    /// Resolves the next track's stream URL ahead of time, so whatever is about to play it
    /// already holds a usable URL before it needs one.
    ///
    /// Runs on both devices. It used to be casting-only, on the reasoning that AVPlayer's
    /// own buffering made a network gap between tracks survivable on the phone — but a
    /// stream URL is not buffered audio. Resolving one is a full InnerTube `player` round
    /// trip, and the phone only started it once the previous track had already ended, so
    /// every transition was a second or more of silence with the next title already showing
    /// in the UI. Warming it here means `beginLoad` finds it in `APIClient`'s stream cache
    /// and attaches immediately.
    ///
    /// Costs one extra player request per track, which buys a gap the length of AVPlayer's
    /// buffering rather than that plus a round trip.
    ///
    /// Autoplay's radio-derived next track deliberately isn't prefetched — that needs a
    /// whole radio fetch to even know what the track is, which is far too much work to do
    /// speculatively on every track change.
    private func prefetchUpNext() {
        guard let next = nextQueuedTrack else {
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
        // The browser is audibly playing this, so the intent flag agrees rather than sitting
        // false underneath it.
        wantsPlayback = true
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
        prefetchUpNext()
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
        // Per item, and reset before the new one arrives: a fresh item starts with no limit and
        // its own duration to be judged on. Left set, the previous track's end would cut this
        // one short — or, worse, a track whose length matched would never be trimmed at all.
        trimmedEnd = nil
        hasDecidedPlaybackEnd = false
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
            // Only ever raised here, never lowered: a caller that passed `autoplay: true`
            // explicitly — the hand-back from a browser does — would otherwise start audio
            // while the flag it never touched stayed false. Lowering it in the `else` would
            // instead discard a pending intent, since an attach can decline to play for
            // reasons that have nothing to do with what the user wants (an interruption).
            wantsPlayback = true
        } else {
            // Not merely "don't start it". `AVPlayer.replaceCurrentItem` keeps whatever rate
            // the player already had, so an attach that declines to play can otherwise begin
            // audio entirely on its own, underneath the `isPlaying = false` written here.
            // Every caller reaches this through `beginLoad`'s own `pause()` today; the one
            // that doesn't is the re-resolve after a stall, which leaves the player armed
            // rather than stopped.
            engine.pause()
            isPlaying = false
        }
        isLoading = false
        if recordHistory { sideEffects.recordPlay(track) }
        updateNowPlayingInfo()
    }

    /// A plausible number of seconds, or nil. Anything longer than a day is nonsense for a
    /// track, and letting it through means a later `Int(...)` conversion aborts the app.
    /// `nonisolated`, like `artworkCacheKey`: a pure function of its argument, so callers off
    /// the main actor have no reason to hop onto it just to sanity-check a number.
    nonisolated static func sanitisedSeconds(_ value: Double) -> Double? {
        guard value.isFinite, value >= 0, value <= 86_400 else { return nil }
        return value
    }

    /// How far the player's own measurement may drift from YouTube's stated length before it
    /// is treated as a misread container rather than a rounding difference. Encoder priming
    /// accounts for hundredths of a second; the failure this guards is off by minutes.
    nonisolated static let durationAgreementMargin: Double = 5

    /// Which length to believe when the AVPlayer item and YouTube's metadata disagree.
    ///
    /// AVFoundation reports **exactly double** the real length for YouTube's audio-only MP4s.
    /// The files themselves are not wrong: for a 4:00 track, `mvhd`, `tkhd` and `mdhd` all say
    /// 239.6s and ffprobe agrees, but the file carries a one-entry `elst` edit list for the
    /// AAC encoder's 1600-sample priming and `AVAsset.duration` comes back 479.19s, having
    /// double-counted it. Both itag 140 and itag 139 do it.
    ///
    /// It only ever surfaced on downloads. Streaming goes through `StreamingResourceLoader`,
    /// where the item's duration stays indefinite and this code path therefore never replaced
    /// the metadata value — so a streamed track showed 4:00 and the same track played from
    /// disk showed 7:59, with a scrubber at half scale and a seek to "halfway" landing at the
    /// end.
    ///
    /// The item's figure is still preferred when it corroborates the metadata, since it is the
    /// more precise of the two, and used outright when there is no metadata to check against —
    /// this rejects a measurement that cannot be true, rather than assuming YouTube is always
    /// right.
    /// Where forward playback must stop, when AVFoundation's idea of the item's length cannot be
    /// true. `nil` means play the item to its own end.
    ///
    /// This is the half of `reconciledDuration` that was missing. That function corrects the
    /// figure on the *scrubber*, and stops there: the player itself was left running on the
    /// doubled timeline, and the queue advances on nothing but the engine reporting the item
    /// finished. So a 5:21 track played its audio, then five and a half more minutes of silence,
    /// and only then moved on — "it doesn't go to the next song, or takes a very long time to".
    /// Nothing looked wrong on screen except a scrubber sitting past the end, which is why this
    /// survived so long: it is only audible, and only when nobody is watching the screen.
    ///
    /// Measured on a real device: a 321s track advanced at 640.7s.
    ///
    /// Streaming was believed immune, because the item's duration stayed indefinite behind
    /// `StreamingResourceLoader`. It no longer does. The loader has to report a real
    /// `contentLength` from `Content-Range` or the asset refuses to open at all, so AVFoundation
    /// now parses the container and inherits the same doubled duration downloads always had.
    ///
    /// Only ever halves, and only when halving is what makes the two sources agree — the
    /// documented failure is a one-entry `elst` counted exactly twice. Anything else (a live
    /// stream, a genuinely mislabelled upload, metadata that is simply wrong) is left alone:
    /// truncating a song on a guess is worse than a late advance.
    nonisolated static func trimmedPlaybackEnd(itemDuration: Double, metadataSeconds: Int?) -> Double? {
        guard let itemDuration = sanitisedSeconds(itemDuration), itemDuration > 0,
              let metadataSeconds, metadataSeconds > 0 else { return nil }
        let halved = itemDuration / 2
        guard abs(halved - Double(metadataSeconds)) <= durationAgreementMargin else { return nil }
        // The halved measurement, not the metadata: it comes from the container and is exact to
        // the sample, where YouTube's figure is rounded to the whole second.
        return halved
    }

    nonisolated static func reconciledDuration(itemDuration: Double, metadataSeconds: Int?) -> Double? {
        guard let itemDuration = sanitisedSeconds(itemDuration), itemDuration > 0 else { return nil }
        guard let metadataSeconds, metadataSeconds > 0 else { return itemDuration }
        let stated = Double(metadataSeconds)
        guard abs(itemDuration - stated) > durationAgreementMargin else { return itemDuration }
        return stated
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
