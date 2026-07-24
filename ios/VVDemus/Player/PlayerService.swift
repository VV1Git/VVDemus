import AVFoundation
import Combine

@MainActor
final class PlayerService: ObservableObject {
    static let shared = PlayerService()

    @Published private(set) var currentTrack: Track?
    @Published private(set) var upNext: [Track] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var queueContextTitle: String?
    @Published var errorMessage: String?

    var autoplayEnabled = true

    private var backStack: [Track] = []
    private let recentRadioAvoidCount = 12

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?

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
        }
    }

    // MARK: - Playback entry points

    /// Play `track`, queuing up whatever comes after it in `context` (the list it was tapped from).
    func play(track: Track, context: [Track] = [], contextTitle: String? = nil) {
        if let index = context.firstIndex(where: { $0.id == track.id }) {
            upNext = Array(context[(index + 1)...])
        } else {
            upNext = []
        }
        queueContextTitle = contextTitle
        load(track)
    }

    /// Start this track's radio: the track itself, followed by similar songs.
    func playRadio(for track: Track) {
        isLoading = true
        errorMessage = nil
        loadTask?.cancel()
        loadTask = Task {
            do {
                let mix = try await APIClient.shared.radio(videoId: track.videoId, limit: 30)
                guard !Task.isCancelled else { return }
                let seed = mix.first ?? track
                upNext = Array(mix.dropFirst())
                queueContextTitle = "\(track.title) Radio"
                load(seed)
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                errorMessage = "Couldn't start radio for \"\(track.title)\"."
            }
        }
    }

    // MARK: - Queue manipulation

    func addToQueue(_ track: Track) {
        upNext.append(track)
    }

    func playNext(_ track: Track) {
        upNext.removeAll { $0.id == track.id }
        upNext.insert(track, at: 0)
    }

    func removeFromQueue(at offsets: IndexSet) {
        upNext.remove(atOffsets: offsets)
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        upNext.move(fromOffsets: source, toOffset: destination)
    }

    /// Jump straight to an item already in the queue, dropping whatever preceded it.
    func skipTo(_ track: Track) {
        guard let index = upNext.firstIndex(where: { $0.id == track.id }) else { return }
        upNext.removeFirst(index + 1)
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
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        progress = seconds
    }

    func advance() {
        if !upNext.isEmpty {
            let next = upNext.removeFirst()
            load(next)
        } else if autoplayEnabled, let seed = currentTrack {
            continueAutoplay(from: seed)
        } else {
            isPlaying = false
        }
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
                let mix = try await APIClient.shared.radio(videoId: seed.videoId, limit: 30)
                guard !Task.isCancelled else { return }
                let recent = Set(PlayHistoryStore.shared.recentSeeds(recentRadioAvoidCount).map(\.id))
                let fresh = mix.filter { $0.id != seed.id && !recent.contains($0.id) }
                guard let next = fresh.first else {
                    isLoading = false
                    isPlaying = false
                    return
                }
                upNext = Array(fresh.dropFirst())
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

        loadTask = Task {
            do {
                let stream = try await APIClient.shared.stream(videoId: track.videoId)
                guard !Task.isCancelled else { return }
                guard let url = URL(string: stream.url) else { throw APIError.invalidURL }
                attach(url: url, track: track)
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                errorMessage = "Couldn't play \"\(track.title)\". Is the backend running?"
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

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
    }
}
