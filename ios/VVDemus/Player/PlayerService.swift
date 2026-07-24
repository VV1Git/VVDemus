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
    private var artworkCache: [String: MPMediaItemArtwork] = [:]

    private init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
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

    private func loadArtwork(for track: Track) {
        guard artworkCache[track.id] == nil, let urlString = track.thumbnailUrl, let url = URL(string: urlString) else { return }
        artworkTask?.cancel()
        artworkTask = Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            guard !Task.isCancelled else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            artworkCache[track.id] = artwork
            if currentTrack?.id == track.id {
                updateNowPlayingInfo()
            }
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

    func addToQueue(_ track: Track) {
        manualQueue.append(track)
    }

    func playNext(_ track: Track) {
        manualQueue.removeAll { $0.id == track.id }
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
        manualQueue.removeAll()
        let skipped = contextQueue.prefix(index + 1).map(\.id)
        contextQueue.removeFirst(index + 1)
        orderedContextQueue.removeAll { skipped.contains($0.id) }
        load(track)
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
        updateNowPlayingInfo()
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        progress = seconds
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
        orderedContextQueue.removeAll { $0.id == next.id }
        return next
    }

    func previous() {
        if progress > 3 {
            seek(to: 0)
            return
        }
        guard let prev = backStack.popLast() else {
            seek(to: 0)
            return
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
                let mix = try await APIClient.shared.radio(videoId: seed.videoId, limit: 50)
                guard !Task.isCancelled else { return }
                let recent = Set(PlayHistoryStore.shared.recentSeeds(recentRadioAvoidCount).map(\.id))
                let fresh = mix.filter { $0.id != seed.id && !recent.contains($0.id) }
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
        currentTrack = track
        isLoading = true
        errorMessage = nil
        progress = 0
        duration = 0
        updateNowPlayingInfo()

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

    private func attach(url: URL, track: Track) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        isLoading = false
        PlayHistoryStore.shared.record(track)
        updateNowPlayingInfo()

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
    }
}
