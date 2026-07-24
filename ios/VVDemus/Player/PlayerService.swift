import AVFoundation
import Combine

@MainActor
final class PlayerService: ObservableObject {
    static let shared = PlayerService()

    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var errorMessage: String?

    private var queue: [Track] = []
    private var queueIndex = 0

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

    func play(track: Track, queue: [Track]? = nil) {
        let effectiveQueue = queue ?? [track]
        self.queue = effectiveQueue
        self.queueIndex = effectiveQueue.firstIndex(where: { $0.id == track.id }) ?? 0
        load(track)
    }

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
        let next = queueIndex + 1
        guard next < queue.count else { return }
        queueIndex = next
        load(queue[next])
    }

    func previous() {
        if progress > 3 {
            seek(to: 0)
            return
        }
        let prev = queueIndex - 1
        guard prev >= 0 else {
            seek(to: 0)
            return
        }
        queueIndex = prev
        load(queue[prev])
    }

    var hasNext: Bool { queueIndex + 1 < queue.count }
    var hasPrevious: Bool { queueIndex > 0 }

    private func load(_ track: Track) {
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
                attach(url: url)
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                errorMessage = "Couldn't play \"\(track.title)\". Is the backend running?"
            }
        }
    }

    private func attach(url: URL) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        isLoading = false

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
    }
}
