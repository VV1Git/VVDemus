import Foundation
import UIKit

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

    static let backgroundSessionIdentifier = "com.vvdemus.downloads"

    private let metadataKey = "downloaded_tracks_v1"
    /// Keyed by videoId rather than by `taskIdentifier`. Task identifiers are only unique
    /// within one session instance, so after iOS relaunched the app to hand back a
    /// finished background download, the delegate had no idea where to put the file and
    /// silently dropped it. The videoId round-trips through `URLSessionTask.taskDescription`.
    private var pendingDownloads: [String: Track] = [:] {
        didSet { DefaultsSnapshot.save(Array(pendingDownloads.values), forKey: Self.pendingKey) }
    }
    private static let pendingKey = "downloads_pending_v1"
    /// Set when the system relaunched us purely to deliver background download events; must
    /// be called once they've all been processed or iOS will stop granting us background
    /// time for downloads.
    var backgroundCompletionHandler: (() -> Void)?

    /// A background configuration, not `.default`.
    ///
    /// With a default session the transfers were owned by the app process, so locking the
    /// phone (or just switching apps) with nothing playing suspended them within seconds
    /// and eventually failed them — "download this playlist, put the phone in your pocket"
    /// reliably came back with a handful of tracks done and the rest stuck. A background
    /// session hands the transfers to the system daemon, which finishes them regardless.
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        // The user asked for these now; don't let iOS defer them to a charging window.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        // Without this the default is *seven days*: a half-open connection leaves the task
        // `.running`, so the row spins and `download()` refuses to restart it, across
        // relaunches, for a week.
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    /// Resolved once. It was a computed property doing a `fileExists` (and sometimes a
    /// `createDirectory`) on every access — and `localFileURL(forVideoId:)` accesses it
    /// twice per call, from inside SwiftUI row bodies that re-evaluate twice a second.
    private let downloadsDirectory: URL

    private override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Set unconditionally, not only when the directory is first created: one failed
        // call used to mean every download was backed up to iCloud forever.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        downloadsDirectory = dir

        super.init()
        load()
        // Restored *before* any delegate callback can arrive. iOS relaunches the app into
        // the background purely to hand back a completed transfer, and at that point the
        // in-memory map is empty — so the finished file was dropped on the floor and the
        // track silently never appeared. Assigned directly to avoid the didSet writing
        // back what we just read.
        if let restored = DefaultsSnapshot.load([Track].self, forKey: Self.pendingKey) {
            pendingDownloads = Dictionary(
                restored.map { ($0.videoId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    /// Re-adopts transfers the system kept running while the app was suspended or dead, so
    /// their progress shows up in the UI instead of the rows sitting at 0 until they
    /// suddenly complete.
    func resumeInFlightDownloads() {
        session.getAllTasks { tasks in
            // Only tasks that can still produce a delegate callback. A `.completed` or
            // `.canceling` task never will, so showing a spinner for one leaves the row
            // stuck forever — and `download(_:)` then refuses to restart it, because
            // `isDownloading` is keyed off exactly that spinner.
            var live: [String] = []
            for task in tasks {
                guard let id = task.taskDescription else { continue }
                switch task.state {
                case .running:
                    live.append(id)
                case .suspended:
                    task.resume()
                    live.append(id)
                case .canceling, .completed:
                    continue
                @unknown default:
                    continue
                }
            }
            Task { @MainActor in
                for id in live where self.progress[id] == nil {
                    // Skip anything the delegate has already finished while this hop was
                    // in flight — otherwise a just-completed download gets a spinner back.
                    guard !self.downloadedTracks.contains(where: { $0.videoId == id }) else { continue }
                    self.progress[id] = 0
                }
            }
        }
    }

    /// Backed by a set, not a linear scan plus four `stat` calls. This is called from
    /// every visible row's body, which re-evaluates whenever download progress publishes.
    private var downloadedIds: Set<String> = []

    func isDownloaded(_ track: Track) -> Bool {
        downloadedIds.contains(track.videoId)
    }

    /// Deletes audio files with no metadata entry pointing at them.
    ///
    /// Nothing reconciled in this direction, so a metadata blob that failed to decode left
    /// the files referenced by nothing, listed by nothing, and deletable by nothing short of
    /// deleting the app — potentially gigabytes. Deliberately skipped when the metadata
    /// itself was unreadable, since then "no entry" means "we don't know", not "orphan".
    private func deleteOrphanedFiles() {
        guard !metadataWasUnreadable else {
            NSLog("[DownloadManager] metadata unreadable — skipping orphan sweep")
            return
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where ["m4a", "mp4"].contains(file.pathExtension) {
            let id = file.deletingPathExtension().lastPathComponent
            guard !downloadedIds.contains(id) else { continue }
            NSLog("[DownloadManager] removing orphaned download %@", id)
            try? FileManager.default.removeItem(at: file)
        }
    }

    private var metadataWasUnreadable = false

    func isDownloading(_ track: Track) -> Bool {
        progress[track.id] != nil
    }

    func localFileURL(for track: Track) -> URL? {
        guard downloadedTracks.contains(where: { $0.id == track.id }) else { return nil }
        return localFileURL(forVideoId: track.videoId)
    }

    /// Used by LocalControlServer's `/api/audio/local/:videoId` route, which only has a
    /// videoId (from the URL path) to work with, not a full `Track`.
    func localFileURL(forVideoId videoId: String) -> URL? {
        // Sanitised because this value arrives straight from a URL path segment on an
        // unauthenticated LAN endpoint, and Swifter's router percent-decodes it — so
        // `..%2F..%2F…` would otherwise escape the downloads directory via
        // `appendingPathComponent`, which keeps `..` literally for the OS to resolve.
        guard Self.isValidVideoId(videoId) else { return nil }
        for ext in ["m4a", "mp4"] {
            let url = downloadsDirectory.appendingPathComponent("\(videoId).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    nonisolated static func isValidVideoId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    func download(_ track: Track) {
        guard !isDownloaded(track), !isDownloading(track) else { return }
        progress[track.id] = 0
        pendingDownloads[track.videoId] = track
        Task { await startTransfer(for: track) }
        prewarmArtwork(for: track)
    }

    /// Resolves the stream and hands the transfer to the background session.
    ///
    /// Shared by the single-track path and the bulk queue so both report failures the same
    /// way — and so there is one place that knows a failed resolve has to clear the spinner,
    /// which is what `download()` refuses to restart on.
    private func startTransfer(for track: Track) async {
        do {
            let stream = try await APIClient.shared.stream(videoId: track.videoId)
            guard let remoteURL = URL(string: stream.url) else { throw APIError.invalidURL }
            let task = session.downloadTask(with: remoteURL)
            task.taskDescription = track.videoId
            task.resume()
        } catch {
            progress[track.id] = nil
            pendingDownloads[track.videoId] = nil
            errorMessage = Self.failureMessage(for: track, error: error)
        }
    }

    /// A rate limit is worth naming rather than flattening into "couldn't download".
    ///
    /// Every failure used to produce the same sentence, so the one case where waiting is the
    /// entire fix looked identical to a track that will never download — and the natural
    /// response to a vague failure, tapping download again on the rest of the playlist, is
    /// precisely what makes a rate limit worse.
    nonisolated static func failureMessage(for track: Track, error: Error) -> String {
        if let apiError = error as? APIError, apiError.isRateLimit {
            return "\(apiError.localizedDescription) \"\(track.title)\" wasn't downloaded."
        }
        return "Couldn't download \"\(track.title)\"."
    }

    /// So a downloaded track's own lock-screen artwork never has to hit the network at
    /// playback time — pre-fetches it once, at download time, into the same disk cache
    /// `PlayerService`/`RemoteImage` check first.
    private func prewarmArtwork(for track: Track) {
        guard let thumbnailUrl = track.thumbnailUrl else { return }
        Task {
            let key = PlayerService.artworkCacheKey(for: thumbnailUrl)
            if await DiskImageCache.shared.data(for: key) != nil { return }
            guard let url = URL(string: key),
                  let (data, response) = try? await NetworkSessions.image.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  // Verified to decode before it is stored. A captive-portal page or a 404
                  // body used to be written verbatim under the artwork key, and every later
                  // reader — including the lock screen — took the poisoned disk entry and
                  // failed, forever.
                  UIImage(data: data) != nil else { return }
            await DiskImageCache.shared.store(data, for: key)
        }
    }

    /// Bulk downloads resolve one at a time instead of all at once.
    ///
    /// This was a loop calling `download`, and each of those spawned its own Task to resolve
    /// a stream URL — so "download this playlist" fired one InnerTube player request per
    /// track simultaneously, thirty deep. That is the most reliable way there is to earn the
    /// 429 that `RateLimit` now has to absorb, and the transfers gain nothing from it: the
    /// files are handed to a background session that paces itself regardless.
    ///
    /// Resolving in sequence also makes a rate limit self-correcting rather than fatal. The
    /// first refusal closes `RateLimitGate`, and each remaining track waits out the cool-down
    /// on its way through instead of piling onto it.
    func downloadAll(_ tracks: [Track]) {
        let queued = tracks.filter { !isDownloaded($0) && !isDownloading($0) }
        guard !queued.isEmpty else { return }
        // Marked as queued up front, so a long playlist doesn't sit looking inert while the
        // resolutions trickle through one by one.
        for track in queued {
            progress[track.id] = 0
            pendingDownloads[track.videoId] = track
            prewarmArtwork(for: track)
        }
        Task {
            for track in queued {
                // Skips anything cancelled or deleted while the queue was draining — its
                // progress entry is gone, and starting a transfer now would resurrect it.
                guard progress[track.id] != nil else { continue }
                await startTransfer(for: track)
            }
        }
    }

    /// Stops an in-flight download. Without this, deleting a track that was still
    /// downloading did nothing useful: the row kept its spinner forever (the progress entry
    /// was never cleared, so `download` refused to restart it), and when the transfer
    /// finished minutes later it wrote the file and put the track back in the library —
    /// the user deleted it and it came back.
    func cancel(_ track: Track) {
        pendingDownloads[track.videoId] = nil
        progress[track.id] = nil
        let videoId = track.videoId
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription == videoId {
                task.cancel()
            }
        }
    }

    func remove(_ track: Track) {
        removeAll([track])
    }

    /// Bulk removal — one save() at the end instead of one per track.
    func removeAll(_ tracks: [Track]) {
        for track in tracks {
            if isDownloading(track) { cancel(track) }
            if let url = localFileURL(for: track) {
                try? FileManager.default.removeItem(at: url)
            }
            // Also delete a file whose metadata entry was lost, which `localFileURL(for:)`
            // can't see.
            if let orphan = localFileURL(forVideoId: track.videoId) {
                try? FileManager.default.removeItem(at: orphan)
            }
        }
        let idsToRemove = Set(tracks.map(\.id))
        downloadedTracks.removeAll { idsToRemove.contains($0.id) }
        downloadedIds.subtract(idsToRemove)
        save()
    }

    /// A response worth keeping. `URLSessionDownloadTask` reports success for *any*
    /// completed response, including a 403 whose body is a few hundred bytes of XML — which
    /// used to be moved into place and recorded as a downloaded track. From then on the
    /// track claimed to be available offline, played from disk, and failed every time, with
    /// no way to fix it short of deleting and re-downloading.
    nonisolated static func isAcceptableDownload(response: URLResponse?, fileSize: Int64) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        guard (200..<300).contains(http.statusCode) else { return false }
        // Truncation check. A connection dropping after 2 MB of a 4 MB file still reports
        // 200, so a size floor alone accepted a half-file — which was then marked
        // downloaded, played from disk, and failed every time with no way to repair it.
        let expected = http.expectedContentLength
        if expected > 0, fileSize < expected { return false }
        // Smaller than any real audio track; an error document lands well under this.
        return fileSize > 16 * 1024
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: metadataKey) else { return }
        guard let decoded = try? JSONDecoder().decode([Track].self, from: data) else {
            metadataWasUnreadable = true
            // Do *not* leave `downloadedTracks` empty and carry on: the next mutation calls
            // `save()`, which would overwrite the still-intact blob with an empty array and
            // destroy the user's download list for good. Keep the original under a side key
            // so it's recoverable, and log loudly.
            NSLog("[DownloadManager] download metadata failed to decode — preserving it as %@_corrupt", metadataKey)
            UserDefaults.standard.set(data, forKey: "\(metadataKey)_corrupt")
            return
        }
        // Metadata lives in UserDefaults (which is backed up) while the audio files are
        // explicitly excluded from backup, so a restored device comes back with a full
        // library list and not one playable file. Reconcile rather than lie about it.
        // Filtered for display, but deliberately NOT saved back. A restore-from-backup, a
        // failed directory creation, or any transient reason the files aren't visible at
        // launch would otherwise erase the record of what was downloaded — leaving the user
        // unable to even see what to fetch again. The next genuine mutation persists the
        // reconciled list; until then the original is preserved.
        let present = decoded.filter { localFileURL(forVideoId: $0.videoId) != nil }
        if present.count != decoded.count {
            NSLog("[DownloadManager] %d of %d downloads have no file on disk — hidden, not deleted",
                  decoded.count - present.count, decoded.count)
        }
        downloadedTracks = present
        downloadedIds = Set(present.map(\.videoId))
        deleteOrphanedFiles()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(downloadedTracks) else { return }
        UserDefaults.standard.set(data, forKey: metadataKey)
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let videoId = downloadTask.taskDescription else { return }
        let track = pendingDownloads[videoId] ?? downloadedTracks.first { $0.videoId == videoId }
        pendingDownloads[videoId] = nil
        progress[videoId] = nil
        guard let track else { return }

        let attributes = try? FileManager.default.attributesOfItem(atPath: location.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard Self.isAcceptableDownload(response: downloadTask.response, fileSize: size) else {
            try? FileManager.default.removeItem(at: location)
            // Drop the cached URL, or every retry resolves to the same dead one and the
            // download can never succeed until the entry expires hours later.
            APIClient.shared.invalidateStream(videoId: track.videoId)
            let http = downloadTask.response as? HTTPURLResponse
            if http?.statusCode == 429 {
                // The media host can rate-limit us too, and a bulk download is exactly when
                // it does. Recorded on the shared gate so the *resolutions* still queued
                // behind this one wait it out rather than adding to it.
                let retryAfter = RateLimit.retryAfter(http?.value(forHTTPHeaderField: "Retry-After"))
                RateLimitGate.shared.recordRateLimit(retryAfter: retryAfter)
                errorMessage = Self.failureMessage(
                    for: track,
                    error: APIError.rateLimited(retryAfter: retryAfter ?? RateLimit.defaultCooldown)
                )
            } else {
                errorMessage = "Couldn't download \"\(track.title)\"."
            }
            return
        }

        let ext = Self.fileExtension(for: downloadTask.response)
        let destination = downloadsDirectory.appendingPathComponent("\(track.videoId).\(ext)")
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            downloadedTracks.removeAll { $0.id == track.id }
            downloadedTracks.append(track)
            downloadedIds.insert(track.videoId)
            save()
        } catch {
            errorMessage = "Couldn't save \"\(track.title)\"."
        }
    }

    nonisolated static func fileExtension(for response: URLResponse?) -> String {
        let mime = (response as? HTTPURLResponse)?.mimeType ?? response?.mimeType ?? ""
        if mime.hasPrefix("audio") { return "m4a" }
        return "mp4"
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let videoId = downloadTask.taskDescription else { return }
        NetworkByteCounter.shared.record(bytesWritten, for: .download)
        guard totalBytesExpectedToWrite > 0 else { return }
        progress[videoId] = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let videoId = task.taskDescription else { return }
        let track = pendingDownloads[videoId]
        guard let error else { return }
        pendingDownloads[videoId] = nil
        progress[videoId] = nil
        // A cancel is the user's own doing, not a failure to report at them.
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        APIClient.shared.invalidateStream(videoId: videoId)
        errorMessage = "Download failed for \"\(track?.title ?? videoId)\": \(error.localizedDescription)"
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
