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
    private var backStack: [Track] = []
    private let recentRadioAvoidCount = 12

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    /// Bounded so this doesn't grow for the entire app session — lock-screen artwork only
    /// ever needs the current (and maybe just-previous) track, so a handful of entries is
    /// plenty. Unbounded, this held a full decoded UIImage per unique track ever played,
    /// which is what was driving the app's memory usage up over long sessions.
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private var artworkCacheOrder: [String] = []
    private let artworkCacheLimit = 6
    /// Must be retained for as long as its asset is in use — `AVAssetResourceLoader`
    /// does not keep a strong reference to its own delegate.
    private var activeResourceLoader: StreamingResourceLoader?
    private var itemStatusObservation: NSKeyValueObservation?
    /// True from the moment playback is handed back to this phone until its player item is
    /// actually attached — resolving a stream URL is async, so this can span seconds on a
    /// cold cache. Transport commands issued inside that window are recorded as intent and
    /// applied by the reattach, rather than being silently undone by it.
    private var isResumingAfterDeviceSwitch = false

    private init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
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
            guard let self, self.activeDevice == .iphone, !self.isResumingAfterDeviceSwitch else { return }
            self.progress = time.seconds
            if let itemDuration = self.player.currentItem?.duration.seconds, itemDuration.isFinite {
                self.duration = itemDuration
            }
            self.updateNowPlayingInfo()
        }
        configureRemoteCommandCenter()
    }

    // MARK: - Lock screen / Control Center

    private func configureRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.currentTrack != nil else { return .noSuchContent }
            if !self.isPlaying { self.togglePlayPause() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.currentTrack != nil else { return .noSuchContent }
            if self.isPlaying { self.togglePlayPause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.currentTrack != nil else { return .noSuchContent }
            self.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.advance()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: event.positionTime)
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork = artworkCache[track.id] {
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            loadArtwork(for: track)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Checks the disk cache (shared with `RemoteImage`, and pre-warmed by `DownloadManager`
    /// at download time) before falling back to the network — this is what makes a
    /// downloaded track's lock-screen artwork actually stay offline instead of depending on
    /// the tiny 6-entry in-memory `artworkCache` still happening to hold it.
    private func loadArtwork(for track: Track) {
        guard artworkCache[track.id] == nil, let urlString = track.thumbnailUrl else { return }
        artworkTask?.cancel()
        artworkTask = Task {
            let requestURLString = PlayerService.artworkCacheKey(for: urlString)
            var data: Data?
            if let diskData = await DiskImageCache.shared.data(for: requestURLString) {
                data = diskData
            } else if let url = URL(string: requestURLString),
                      let (fetched, _) = try? await NetworkSessions.image.data(from: url) {
                data = fetched
                await DiskImageCache.shared.store(fetched, for: requestURLString)
            }
            guard let data, let image = UIImage(data: data) else { return }
            guard !Task.isCancelled else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            cacheArtwork(artwork, for: track.id)
            if currentTrack?.id == track.id {
                updateNowPlayingInfo()
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

    // MARK: - Playback entry points

    /// Play `track`, queuing up whatever comes after it in `context` (the list it was tapped from).
    func play(track: Track, context: [Track] = [], contextTitle: String? = nil) {
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
    }

    // MARK: - Queue manipulation

    /// Removing the track from `contextQueue`/`orderedContextQueue` first (if it's already
    /// there) keeps a track from ever sitting in two queues at once — without this, a
    /// track queued explicitly could get played once from the manual queue and then
    /// played *again* later when the context queue reached its own untouched copy.
    func addToQueue(_ track: Track) {
        contextQueue.removeAll { $0.id == track.id }
        orderedContextQueue.removeAll { $0.id == track.id }
        manualQueue.append(track)
    }

    func playNext(_ track: Track) {
        manualQueue.removeAll { $0.id == track.id }
        contextQueue.removeAll { $0.id == track.id }
        orderedContextQueue.removeAll { $0.id == track.id }
        manualQueue.insert(track, at: 0)
    }

    func removeFromQueue(_ track: Track) {
        manualQueue.removeAll { $0.id == track.id }
        contextQueue.removeAll { $0.id == track.id }
        orderedContextQueue.removeAll { $0.id == track.id }
    }

    func moveInManualQueue(from source: IndexSet, to destination: Int) {
        manualQueue.move(fromOffsets: source, toOffset: destination)
    }

    func moveInContextQueue(from source: IndexSet, to destination: Int) {
        contextQueue.move(fromOffsets: source, toOffset: destination)
        if !isShuffling {
            orderedContextQueue = contextQueue
        }
    }

    /// Jump straight to an item already in the queue, dropping whatever preceded it —
    /// manual queue first, then context queue, matching how they're displayed.
    func skipTo(_ track: Track) {
        if let index = manualQueue.firstIndex(where: { $0.id == track.id }) {
            manualQueue.removeFirst(index + 1)
            load(track)
            return
        }
        guard let index = contextQueue.firstIndex(where: { $0.id == track.id }) else { return }
        let skipped = contextQueue.prefix(index + 1).map(\.id)
        contextQueue.removeFirst(index + 1)
        orderedContextQueue.removeAll { skipped.contains($0.id) }
        load(track)
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        if activeDevice == .computer {
            bumpPlaybackEpoch()
            isPlaying.toggle()
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
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
        updateNowPlayingInfo()
    }

    func seek(to seconds: Double) {
        guard activeDevice != .computer else {
            bumpPlaybackEpoch()
            progress = seconds
            onComputerCommand?(.seek(seconds))
            return
        }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        progress = seconds
    }

    // MARK: - Device switching (VVDemus Connect)

    /// Moves audio output between this phone's AVPlayer and a connected browser, without
    /// touching queue/radio/shuffle/stats state — those all keep living here regardless
    /// of which device is actually making sound.
    func setActiveDevice(_ device: PlaybackDevice) {
        guard device != activeDevice else { return }
        activeDevice = device
        bumpPlaybackEpoch()
        switch device {
        case .computer:
            player.pause()
            isResumingAfterDeviceSwitch = false
            // The currently-playing track (if any) needs its stream URL resolved for the
            // browser too — only a *new* track load did this before, so switching devices
            // mid-playback left the browser with nothing to actually play.
            externalStream = nil
            guard let track = currentTrack else { return }
            loadTask?.cancel()
            loadTask = Task {
                do {
                    let urlString = try await self.resolveComputerStreamUrl(for: track)
                    guard !Task.isCancelled else { return }
                    self.externalStream = ExternalStream(videoId: track.videoId, url: urlString)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.errorMessage = "Couldn't hand off playback to the computer."
                }
            }
        case .iphone:
            externalStream = nil
            guard let track = currentTrack else { return }
            isResumingAfterDeviceSwitch = true
            loadTask?.cancel()
            loadTask = Task {
                do {
                    let url: URL
                    if let localURL = DownloadManager.shared.localFileURL(for: track) {
                        url = localURL
                    } else {
                        let stream = try await APIClient.shared.stream(videoId: track.videoId)
                        guard let resolved = URL(string: stream.url) else { throw APIError.invalidURL }
                        url = resolved
                    }
                    guard !Task.isCancelled else { return }
                    // Read (rather than pre-captured) so a pause or seek made while this
                    // was resolving is honoured instead of being reverted.
                    attach(url: url, track: track, resumeAt: progress, autoplay: isPlaying, recordHistory: false)
                } catch {
                    guard !Task.isCancelled else { return }
                    isResumingAfterDeviceSwitch = false
                    errorMessage = "Couldn't resume playback on this iPhone."
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
        self.progress = progress
        self.duration = duration
        self.isPlaying = isPlaying
        updateNowPlayingInfo()
    }

    func advance() {
        if !manualQueue.isEmpty {
            let next = manualQueue.removeFirst()
            load(next)
        } else if let next = popNextContextTrack() {
            load(next)
        } else if autoplayEnabled, let seed = currentTrack {
            continueAutoplay(from: seed)
        } else {
            isPlaying = false
        }
    }

    private func popNextContextTrack() -> Track? {
        guard !contextQueue.isEmpty else { return nil }
        let next = contextQueue.removeFirst()
        // A single `removeFirst`, not `removeAll` — the same track can legitimately
        // appear more than once in a mix/playlist, and removing every matching id here
        // would silently drop the other copy instead of just the one just consumed.
        if let index = orderedContextQueue.firstIndex(where: { $0.id == next.id }) {
            orderedContextQueue.remove(at: index)
        }
        return next
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
        guard let prev = backStack.popLast() else {
            seek(to: 0)
            return
        }
        if let outgoing = currentTrack {
            contextQueue.insert(outgoing, at: 0)
            orderedContextQueue.insert(outgoing, at: 0)
        }
        // Bypass load()'s backStack push: walking backward shouldn't re-push the track
        // we're leaving, or repeated "previous" presses would just bounce between two tracks.
        beginLoad(prev)
    }

    var hasPrevious: Bool { !backStack.isEmpty }

    // MARK: - Autoplay

    private func continueAutoplay(from seed: Track) {
        isLoading = true
        loadTask?.cancel()
        loadTask = Task {
            do {
                // Reuse an already-cached mix for this seed (e.g. from having viewed its
                // radio screen, or the web remote fetching it) instead of always re-fetching
                // — and only 25 are needed, not 50, since just `fresh.first` is used
                // immediately and the rest just seed the context queue.
                let mix: [Track]
                if let cached = RadioCacheStore.shared.tracks(for: seed.videoId), !cached.isEmpty {
                    mix = cached
                } else {
                    let fetched = try await APIClient.shared.radio(videoId: seed.videoId, limit: InnerTubeClient.dataSaverLimit(default: 25))
                    // `storeIfAbsent`, so autoplay quietly refilling the queue can never
                    // replace the mix shown on that radio's screen with its own shorter one.
                    RadioCacheStore.shared.storeIfAbsent(fetched, for: seed.videoId)
                    mix = fetched
                }
                guard !Task.isCancelled else { return }
                let recent = Set(PlayHistoryStore.shared.recentSeeds(recentRadioAvoidCount).map(\.id))
                let fresh = mix
                    .excludingLongFormMixes()
                    .filter { $0.id != seed.id && !recent.contains($0.id) }
                guard let next = fresh.first else {
                    isLoading = false
                    isPlaying = false
                    return
                }
                orderedContextQueue = Array(fresh.dropFirst())
                contextQueue = isShuffling ? orderedContextQueue.shuffled() : orderedContextQueue
                queueContextTitle = "\(seed.title) Radio"
                load(next)
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                isPlaying = false
            }
        }
    }

    // MARK: - Loading a track

    private func load(_ track: Track) {
        if let outgoing = currentTrack {
            backStack.append(outgoing)
            if backStack.count > 30 { backStack.removeFirst(backStack.count - 30) }
        }
        beginLoad(track)
    }

    private func beginLoad(_ track: Track) {
        loadTask?.cancel()
        bumpPlaybackEpoch()
        trackLoadEpoch &+= 1
        recordListeningStats()
        currentTrack = track
        isLoading = true
        errorMessage = nil
        progress = 0
        duration = 0
        updateNowPlayingInfo()

        if activeDevice == .computer {
            beginLoadForComputer(track)
            return
        }

        // Downloaded tracks play straight from disk — no network, no data usage.
        if let localURL = DownloadManager.shared.localFileURL(for: track) {
            attach(url: localURL, track: track)
            return
        }

        loadTask = Task {
            do {
                let stream = try await APIClient.shared.stream(videoId: track.videoId)
                guard !Task.isCancelled else { return }
                guard let url = URL(string: stream.url) else { throw APIError.invalidURL }
                attach(url: url, track: track)
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                errorMessage = "Couldn't play \"\(track.title)\". Check your connection and try again."
            }
        }
    }

    /// The computer-active counterpart to `attach` — hands the browser something to load
    /// into its own `<audio>` element instead of touching this phone's AVPlayer at all,
    /// so the phone doesn't also decode/stream the same audio while casting.
    private func beginLoadForComputer(_ track: Track) {
        PlayHistoryStore.shared.record(track)
        // Drop the outgoing track's URL immediately, so nothing observing this mid-resolve
        // sees the new track paired with the old track's audio.
        externalStream = nil
        loadTask = Task {
            do {
                let urlString = try await resolveComputerStreamUrl(for: track)
                guard !Task.isCancelled else { return }
                externalStream = ExternalStream(videoId: track.videoId, url: urlString)
                isLoading = false
                isPlaying = true
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                errorMessage = "Couldn't play \"\(track.title)\". Check your connection and try again."
            }
        }
    }

    /// What the browser's `<audio>` element should load for `track` while it's the active
    /// device — a same-origin relative path to LocalControlServer's own
    /// `/api/audio/local` route for a downloaded track (the browser can't reach a
    /// `file://` URL on the phone's disk), or the directly-fetchable resolved stream URL
    /// otherwise.
    private func resolveComputerStreamUrl(for track: Track) async throws -> String {
        if DownloadManager.shared.isDownloaded(track) {
            return "/api/audio/local/\(track.videoId)"
        }
        return try await APIClient.shared.stream(videoId: track.videoId).url
    }

    /// Local (downloaded) files bypass the network entirely — no need to route them
    /// through `StreamingResourceLoader`, and their bytes were already counted at
    /// download time. Everything else goes through the loader so its actual streaming
    /// bytes show up in `NetworkByteCounter` instead of being invisible to it. Falls back
    /// to handing AVFoundation the real URL directly (no byte counting, but playback
    /// still works) if the URL can't be remapped to the loader's custom scheme for any
    /// reason.
    private static func makePlayerItem(for url: URL) -> (item: AVPlayerItem, resourceLoader: StreamingResourceLoader?) {
        guard !url.isFileURL, let playableURL = StreamingResourceLoader.playableURL(for: url) else {
            return (AVPlayerItem(url: url), nil)
        }
        let loader = StreamingResourceLoader(realURL: url)
        let asset = AVURLAsset(url: playableURL)
        asset.resourceLoader.setDelegate(loader, queue: .main)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = forwardBufferDuration
        return (item, loader)
    }

    /// Left to its own devices AVFoundation happily pulls a whole progressive audio file
    /// down as fast as the network allows — so skipping a track twenty seconds in has
    /// usually already paid for all four minutes of it. Capping the read-ahead means a skip
    /// wastes at most this much audio. Kept well above the few seconds of buffer needed to
    /// ride out a bad patch of signal, and tightened further under Data Saver.
    private static var forwardBufferDuration: TimeInterval {
        UserDefaults.standard.bool(forKey: InnerTubeClient.dataSaverDefaultsKey) ? 30 : 60
    }

    private func attach(url: URL, track: Track, resumeAt: Double = 0, autoplay: Bool = true, recordHistory: Bool = true) {
        isResumingAfterDeviceSwitch = false
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        let item = PlayerService.makePlayerItem(for: url)
        activeResourceLoader = item.resourceLoader
        itemStatusObservation = item.item.observe(\.status, options: [.new]) { playerItem, _ in
            if playerItem.status == .failed {
                NSLog("[PlayerService] AVPlayerItem failed: %@", playerItem.error?.localizedDescription ?? "unknown")
            }
        }
        player.replaceCurrentItem(with: item.item)
        if resumeAt > 0 {
            player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
            progress = resumeAt
        }
        if autoplay {
            player.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
        isLoading = false
        if recordHistory { PlayHistoryStore.shared.record(track) }
        updateNowPlayingInfo()

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
    }

    /// Logs how much of the *outgoing* track was actually heard, right before it's
    /// replaced — using elapsed playback position, not the track's nominal length, so
    /// stats reflect real listening instead of crediting a full play for every skip.
    private func recordListeningStats() {
        guard let outgoing = currentTrack, progress > 0 else { return }
        let cap = outgoing.durationSeconds.map(Double.init) ?? progress
        let elapsed = min(progress, cap)
        ListeningStatsStore.shared.record(outgoing, secondsPlayed: Int(elapsed))
    }
}
