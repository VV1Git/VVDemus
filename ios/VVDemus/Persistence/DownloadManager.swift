import Foundation

/// Downloads a track's resolved audio to disk for offline playback later. Delegate runs
/// on the main queue so download callbacks can touch @Published state directly without
/// hopping actors — downloads are infrequent/low-volume enough that this is fine.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var downloadedTracks: [Track] = []
    /// videoId -> 0...1 while a download is in flight; absent once finished or failed.
    @Published private(set) var progress: [String: Double] = [:]
    @Published var errorMessage: String?

    private let metadataKey = "downloaded_tracks_v1"
    private var pendingDestinations: [Int: (destination: URL, track: Track)] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    private var downloadsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }

    private override init() {
        super.init()
        load()
    }

    func isDownloaded(_ track: Track) -> Bool {
        localFileURL(for: track) != nil
    }

    func isDownloading(_ track: Track) -> Bool {
        progress[track.id] != nil
    }

    func localFileURL(for track: Track) -> URL? {
        guard downloadedTracks.contains(where: { $0.id == track.id }) else { return nil }
        for ext in ["m4a", "mp4"] {
            let url = downloadsDirectory.appendingPathComponent("\(track.videoId).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func download(_ track: Track) {
        guard !isDownloaded(track), !isDownloading(track) else { return }
        progress[track.id] = 0
        Task {
            do {
                let stream = try await APIClient.shared.stream(videoId: track.videoId)
                guard let remoteURL = URL(string: stream.url) else { throw APIError.invalidURL }
                let ext = stream.mimeType.hasPrefix("audio") ? "m4a" : "mp4"
                let destination = downloadsDirectory.appendingPathComponent("\(track.videoId).\(ext)")
                let task = session.downloadTask(with: remoteURL)
                pendingDestinations[task.taskIdentifier] = (destination, track)
                task.resume()
            } catch {
                progress[track.id] = nil
                errorMessage = "Couldn't download \"\(track.title)\"."
            }
        }
    }

    func downloadAll(_ tracks: [Track]) {
        for track in tracks { download(track) }
    }

    func remove(_ track: Track) {
        if let url = localFileURL(for: track) {
            try? FileManager.default.removeItem(at: url)
        }
        downloadedTracks.removeAll { $0.id == track.id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: metadataKey),
              let decoded = try? JSONDecoder().decode([Track].self, from: data) else { return }
        downloadedTracks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(downloadedTracks) else { return }
        UserDefaults.standard.set(data, forKey: metadataKey)
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (destination, track) = pendingDestinations.removeValue(forKey: downloadTask.taskIdentifier) else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            downloadedTracks.removeAll { $0.id == track.id }
            downloadedTracks.append(track)
            save()
        } catch {
            errorMessage = "Couldn't save \"\(track.title)\"."
        }
        progress[track.id] = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, let track = pendingDestinations[downloadTask.taskIdentifier]?.track else { return }
        progress[track.id] = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let entry = pendingDestinations.removeValue(forKey: task.taskIdentifier) else { return }
        progress[entry.track.id] = nil
        errorMessage = "Download failed for \"\(entry.track.title)\": \(error.localizedDescription)"
    }
}
