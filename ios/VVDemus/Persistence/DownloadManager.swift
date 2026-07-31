import Foundation
import UIKit

/// Downloads a track's resolved audio to disk for offline playback later. Delegate runs
/// on the main queue so download callbacks can touch @Published state directly without
/// hopping actors — downloads are infrequent/low-volume enough that this is fine.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var downloadedTracks: [Track] = []
    /// videoId -> live entry. Present while queued/resolving/transferring, and retained after
    /// a failure until the user retries, dismisses, or relaunches.
    ///
    /// Replaces a `[String: Double]` of raw fractions. That dictionary could only say "in
    /// flight, this far along", so "queued behind thirty-eight other resolves", "asking
    /// InnerTube for a URL right now" and "downloading, 0% done" were the same value — and a
    /// failure was indistinguishable from never having been asked for.
    @Published private(set) var active: [String: DownloadEntry] = [:]
    /// Most-recent-first, capped at `maximumRetainedBatches`. Pruned as members finish.
    @Published private(set) var batches: [DownloadBatch] = []
    /// When the parked resolutions expect to be let through, or nil when nothing is parked.
    ///
    /// Mirrors `RateLimitGate` into published state: the gate is a lock-protected global with
    /// no change notification, so a view reading it directly shows whatever was true at its
    /// last render — and during a gated batch there are no renders. A batch waiting out a 429
    /// is otherwise indistinguishable from a hung one, and the user's response to a hang is to
    /// back out and tap Download again, which is precisely what extends the cool-down.
    ///
    /// Written *only* by `awaitRateLimitGate`, which is the only code that actually waits. A
    /// media host 429ing one transfer used to set this too, from a delegate callback with no
    /// loop behind it and nothing to clear it — so a lone refused download left the header
    /// captioned "Paused — resuming in 0:00" indefinitely, and a 429 mid-batch captioned a
    /// queue "Paused" while thirty other transfers kept landing underneath the word.
    @Published private(set) var rateLimitedUntil: Date?
    /// Which downloads are parked, so a collection only claims to be paused when one of its own
    /// tracks is the thing waiting. Also the lifetime of `rateLimitedUntil`: it is non-nil
    /// exactly while this is non-empty, which is what makes two overlapping drain loops safe —
    /// the `defer` this replaced let whichever loop finished first clear a date the other was
    /// still waiting on.
    @Published private(set) var rateLimitedIds: Set<String> = []
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
    private static let batchesKey = "downloads_batches_v1"
    /// Bounded because nothing else prunes a batch whose members all failed and were then
    /// dismissed; without a cap the list is append-only for the life of the install.
    private static let maximumRetainedBatches = 8
    /// Source of truth for `batches`; mirrored and persisted by `setBatches(_:)`.
    private var batchRecords: [DownloadBatch] = []
    /// Insertion order for `activeEntries`. A dictionary's own iteration order changes as it
    /// rehashes, so a list built from it reshuffles while the user is watching it.
    private var nextOrder = 0
    /// Byte counts land here per chunk and fold into `active` at most every `flushInterval` —
    /// see `scheduleFlush()`.
    private var pendingBytes: [String: (received: Int64, expected: Int64?)] = [:]
    /// videoId -> size of the file it left on disk, for downloads that finished during this
    /// run. Without it a collection's byte readout was the sum of the *live* transfers only, so
    /// each completion subtracted its own several megabytes in the same publish that
    /// incremented "N of M" — the number sawtoothed downwards for the length of an album.
    ///
    /// In-memory and session-scoped on purpose: it exists to keep one collection's readout
    /// monotonic while the user is watching it, not to be a size index. A track downloaded in an
    /// earlier run simply contributes nothing, which is honest — that traffic didn't happen now.
    /// Cleared with the file in `removeAll`.
    private var completedBytes: [String: Int64] = [:]
    private var flushTask: Task<Void, Never>?
    private static let flushInterval: Duration = .milliseconds(250)
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
        // Same constraint, same reason: assigned to both fields directly rather than through
        // `setBatches`, which would write straight back what was just read.
        if let restoredBatches = DefaultsSnapshot.load([DownloadBatch].self, forKey: Self.batchesKey) {
            batchRecords = restoredBatches
            batches = restoredBatches
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
            var live: [(id: String, received: Int64, expected: Int64)] = []
            for task in tasks {
                guard let id = task.taskDescription else { continue }
                switch task.state {
                case .running:
                    break
                case .suspended:
                    task.resume()
                case .canceling, .completed:
                    continue
                @unknown default:
                    continue
                }
                live.append((id, task.countOfBytesReceived, task.countOfBytesExpectedToReceive))
            }
            Task { @MainActor in
                let batchIndex = self.batchIndexByVideoId()
                for entry in live where self.active[entry.id] == nil {
                    // Skip anything the delegate has already finished while this hop was
                    // in flight — otherwise a just-completed download gets an indicator back.
                    guard !self.downloadedIds.contains(entry.id) else { continue }
                    guard let track = self.pendingDownloads[entry.id] else { continue }
                    // Seeded from the task's own counters, not from zero. A transfer the
                    // system took 80% of the way while the app was dead used to come back
                    // reading nothing and stay there until the next chunk landed.
                    self.insert(track, batchId: batchIndex[entry.id], state: .transferring(
                        received: entry.received,
                        expected: entry.expected > 0 ? entry.expected : nil
                    ))
                }
                self.pruneBatches()
            }
        }
    }

    /// videoId -> owning batch, for re-adopting a relaunched transfer into the batch card it
    /// belongs to instead of stranding it as a loose download.
    private func batchIndexByVideoId() -> [String: UUID] {
        var index: [String: UUID] = [:]
        for batch in batchRecords {
            for videoId in batch.videoIds where index[videoId] == nil {
                index[videoId] = batch.id
            }
        }
        return index
    }

    private func setBatches(_ records: [DownloadBatch]) {
        let capped = Array(records.prefix(Self.maximumRetainedBatches))
        batchRecords = capped
        batches = capped
        DefaultsSnapshot.save(capped, forKey: Self.batchesKey)
    }

    /// A batch exists to group live transfers; once none of its members are in `active` it has
    /// nothing left to show and its card would sit on the Downloads screen forever.
    ///
    /// A member counts as alive if it is in `active` *or* still has a pending record. `active`
    /// alone was wrong on exactly the launch this persistence exists for: `init()` restores
    /// batch records but seeds no entries, and adoption only happens on a later main-actor hop
    /// out of `getAllTasks`. A transfer that finished while the app was dead has its
    /// `didFinishDownloadingTo` waiting on the same main queue with no ordering guarantee
    /// against that hop — so it landed first, found `active` empty, pruned every restored batch,
    /// and the thirty still-running members were then adopted as loose anonymous downloads with
    /// no card and no batch-level Stop.
    private func pruneBatches() {
        let surviving = batchRecords.filter { batch in
            batch.videoIds.contains { active[$0] != nil || pendingDownloads[$0] != nil }
        }
        guard surviving.count != batchRecords.count else { return }
        setBatches(surviving)
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

    /// Deliberately false for a retained `.failed` entry: `download(_:)` guards on this, and
    /// treating a failure as "still downloading" is what would make the retry path refuse.
    func isDownloading(_ track: Track) -> Bool {
        active[track.id]?.state.isInFlight == true
    }

    func state(for track: Track) -> DownloadState? {
        active[track.id]?.state
    }

    /// Stable insertion order; a dictionary's own order reshuffles on every publish.
    var activeEntries: [DownloadEntry] {
        active.values.sorted { $0.order < $1.order }
    }

    func collectionProgress(for tracks: [Track]) -> CollectionDownloadProgress {
        collectionProgress(forVideoIds: tracks.map(\.videoId))
    }

    /// O(N) over the collection, called from view bodies — which is affordable only because
    /// byte updates publish at most four times a second (see `scheduleFlush()`).
    func collectionProgress(forVideoIds ids: [String]) -> CollectionDownloadProgress {
        guard !ids.isEmpty else { return .empty }
        var completed = 0, failed = 0, activeCount = 0
        var partial = 0.0
        var bytes: Int64 = 0
        var preparing: String?
        var limitedUntil: Date?
        for id in ids {
            if let entry = active[id] {
                // Only a track of *this* collection being parked makes this collection paused.
                if rateLimitedIds.contains(id) { limitedUntil = rateLimitedUntil }
                switch entry.state {
                case .failed:
                    failed += 1
                case .queued:
                    activeCount += 1
                case .resolving:
                    activeCount += 1
                    if preparing == nil { preparing = entry.track.title }
                case .transferring:
                    activeCount += 1
                    partial += entry.state.fraction ?? 0
                    bytes += entry.state.receivedBytes
                }
            } else if downloadedIds.contains(id) {
                completed += 1
                // Carried over from the transfer that put it there, so a completion adds to the
                // byte total in the same publish that it stops contributing as a live one.
                bytes += completedBytes[id] ?? 0
            }
        }
        return CollectionDownloadProgress(
            total: ids.count, completed: completed, failed: failed, active: activeCount,
            partial: partial, bytesReceived: bytes, preparingTitle: preparing,
            rateLimitedUntil: limitedUntil
        )
    }

    /// The batch any member of `tracks` belongs to, so a collection header's Stop control can
    /// cancel the whole job rather than only the tracks that happen to be on screen.
    func batch(for tracks: [Track]) -> DownloadBatch? {
        let ids = Set(tracks.map(\.videoId))
        return batchRecords.first { $0.videoIds.contains(where: ids.contains) }
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

    /// Also the retry path. `isDownloading` is false for a retained `.failed` entry, so this
    /// gets through and `insert` overwrites the failure — there is no separate `retry(_:)` to
    /// keep in sync with it.
    func download(_ track: Track) {
        guard !isDownloaded(track), !isDownloading(track) else { return }
        // `.resolving`, not `.queued`: a single tap resolves immediately, and showing a
        // "waiting its turn" state for something with no queue in front of it is a lie.
        insert(track, batchId: nil, state: .resolving)
        pendingDownloads[track.videoId] = track
        Task { await startTransfer(for: track) }
        prewarmArtwork(for: track)
    }

    /// Overwrites any existing entry, carrying nothing over from it — a retry that inherited
    /// the old entry's buffered byte counts would render the previous attempt's fraction.
    private func insert(_ track: Track, batchId: UUID?, state: DownloadState) {
        nextOrder += 1
        pendingBytes[track.videoId] = nil
        active[track.videoId] = DownloadEntry(
            track: track, batchId: batchId, order: nextOrder, state: state
        )
    }

    /// Every path that stops tracking a download goes through here, because forgetting the
    /// buffered bytes is not optional: a flush landing after the entry was dropped would
    /// otherwise resurrect a finished row.
    private func clearEntry(_ videoId: String) {
        active[videoId] = nil
        pendingBytes[videoId] = nil
        pruneBatches()
    }

    /// Parks the caller for as long as `RateLimitGate` says requests are refused, re-checking
    /// that the download still exists on each pass so a cancel isn't waited out first.
    ///
    /// Belongs here rather than in `InnerTubeClient.send`, which only absorbs
    /// `RateLimit.maximumWait` (10s) and throws past that: without this a single 429 carrying
    /// a 300s window turned the rest of a forty-track batch into thirty-nine `.failed` rows
    /// inside half a second.
    private func awaitRateLimitGate(whileTracking videoId: String) async {
        // `defer`, because every exit — gate open, download cancelled, task cancelled — has to
        // give the claim back. A parked id left behind is a permanent "Paused" caption.
        defer {
            rateLimitedIds.remove(videoId)
            if rateLimitedIds.isEmpty { rateLimitedUntil = nil }
        }
        while let remaining = RateLimitGate.shared.remainingCooldown() {
            guard active[videoId] != nil else { break }
            rateLimitedIds.insert(videoId)
            rateLimitedUntil = Date().addingTimeInterval(remaining)
            // The sleep ending is itself the publish that retires the caption, so the countdown
            // reaching zero and the UI recovering are the same event rather than two.
            try? await Task.sleep(for: .seconds(remaining))
        }
    }

    /// Resolves the stream and hands the transfer to the background session.
    ///
    /// Shared by the single-track path and the bulk queue so both report failures the same
    /// way — and so there is one place that knows a failed resolve has to leave the entry in a
    /// state `download()` will restart from.
    private func startTransfer(for track: Track) async {
        do {
            let stream = try await APIClient.shared.stream(videoId: track.videoId)
            guard let remoteURL = URL(string: stream.url) else { throw APIError.invalidURL }
            let task = session.downloadTask(with: remoteURL)
            task.taskDescription = track.videoId
            task.resume()
            // Deliberately still `.resolving`: no bytes have arrived and no Content-Length is
            // known, so a `.transferring` here would render as a hard zero until the first
            // chunk lands.
        } catch {
            // The entry is *kept*, marked failed, so the row carries a retry. The pending
            // record is cleared: there is no transfer for a relaunch to adopt.
            pendingDownloads[track.videoId] = nil
            let message = Self.failureMessage(for: track, error: error)
            active[track.id]?.state = .failed(reason: message)
            // Deliberately does *not* publish a cool-down. `InnerTubeClient` has already closed
            // `RateLimitGate`, so the next track through `awaitRateLimitGate` parks and says so
            // — and if this was the last one, nothing is waiting and nothing should claim to be.
            errorMessage = message
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
    func downloadAll(_ tracks: [Track], title: String, artworkURL: String? = nil) {
        let queued = tracks.filter { !isDownloaded($0) && !isDownloading($0) }
        guard !queued.isEmpty else { return }

        let batch = DownloadBatch(
            id: UUID(), title: title, artworkURL: artworkURL,
            // The whole collection, not just what needs fetching, so the card reads "10 of 40"
            // rather than "0 of 30" when ten were already on disk.
            videoIds: tracks.map(\.videoId), startedAt: Date()
        )
        setBatches([batch] + batchRecords)

        // Marked as queued up front, so a long playlist doesn't sit looking inert while the
        // resolutions trickle through one by one. One `pendingDownloads` assignment for the
        // whole batch: its didSet encodes and writes the entire array to UserDefaults, so a
        // per-track assignment meant forty JSON encodes and forty synchronous defaults writes
        // back to back on the main actor.
        var pending = pendingDownloads
        for track in queued {
            insert(track, batchId: batch.id, state: .queued)
            pending[track.videoId] = track
            prewarmArtwork(for: track)
        }
        pendingDownloads = pending

        Task {
            for track in queued {
                // Skips anything cancelled or deleted while the queue was draining — its
                // entry is gone, and starting a transfer now would resurrect it.
                guard active[track.id] != nil else { continue }
                await awaitRateLimitGate(whileTracking: track.id)
                guard active[track.id] != nil else { continue }
                active[track.id]?.state = .resolving
                await startTransfer(for: track)
            }
        }
    }

    /// Restarts every retained failure in a collection. Deliberately not `downloadAll`, which
    /// would mint a second batch record over the same tracks and leave two cards for one job.
    func retryFailed(in videoIds: [String]) {
        let entries = videoIds.compactMap { active[$0] }.filter { $0.state.isFailed }
        guard !entries.isEmpty else { return }
        var pending = pendingDownloads
        for entry in entries {
            insert(entry.track, batchId: entry.batchId, state: .queued)
            pending[entry.track.videoId] = entry.track
        }
        pendingDownloads = pending
        Task {
            for entry in entries {
                guard active[entry.id] != nil else { continue }
                await awaitRateLimitGate(whileTracking: entry.id)
                guard active[entry.id] != nil else { continue }
                active[entry.id]?.state = .resolving
                await startTransfer(for: entry.track)
            }
        }
    }

    /// Drops retained failures without retrying them, so a batch that will never succeed can
    /// be cleared off the Downloads screen.
    func dismissFailed(in videoIds: [String]) {
        for id in videoIds where active[id]?.state.isFailed == true {
            active[id] = nil
            pendingBytes[id] = nil
        }
        pruneBatches()
    }

    /// Stops an in-flight download. Without this, deleting a track that was still
    /// downloading did nothing useful: the row kept its spinner forever (the progress entry
    /// was never cleared, so `download` refused to restart it), and when the transfer
    /// finished minutes later it wrote the file and put the track back in the library —
    /// the user deleted it and it came back.
    func cancel(_ track: Track) {
        pendingDownloads[track.videoId] = nil
        clearEntry(track.videoId)
        cancelTasks(for: [track.videoId])
    }

    /// One pass, not a loop over `cancel(_:)` — that fires one `getAllTasks` per track, each
    /// of which walks every task in the session, so cancelling a forty-track batch is 1600
    /// comparisons spread over forty async callbacks that interleave with the drain loop.
    func cancelAll(_ tracks: [Track]) {
        cancelIds(Set(tracks.map(\.videoId)))
    }

    func cancelBatch(_ id: UUID) {
        guard let batch = batchRecords.first(where: { $0.id == id }) else { return }
        cancelIds(Set(batch.videoIds))
    }

    private func cancelIds(_ ids: Set<String>) {
        var pending = pendingDownloads
        for id in ids where active[id] != nil || pending[id] != nil {
            pending[id] = nil
            active[id] = nil
            pendingBytes[id] = nil
        }
        pendingDownloads = pending
        pruneBatches()
        // Clearing `active` synchronously above is what stops a still-draining `downloadAll`
        // from resolving the rest, so cancel is instant even though the URLSession side of it
        // only lands on a later callback.
        cancelTasks(for: ids)
    }

    private func cancelTasks(for ids: Set<String>) {
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription.map(ids.contains) == true {
                task.cancel()
            }
        }
    }

    func remove(_ track: Track) {
        removeAll([track])
    }

    /// Bulk removal — one save() at the end instead of one per track.
    func removeAll(_ tracks: [Track]) {
        // One sweep before the deletions. `if isDownloading(track) { cancel(track) }` both
        // missed retained `.failed` entries — which would have survived the delete as ghost
        // rows — and fired one `getAllTasks` per track.
        cancelIds(Set(tracks.map(\.videoId)))
        for track in tracks {
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
        for id in idsToRemove { completedBytes[id] = nil }
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
        let track = pendingDownloads[videoId] ?? active[videoId]?.track
            ?? downloadedTracks.first { $0.videoId == videoId }
        // Captured before the buffers are dropped: whatever figure the strip was last showing
        // for this track is the floor its completed contribution must not fall below, or the
        // total dips at the moment of success — the exact regression `completedBytes` exists to
        // stop. A resumed transfer can leave a high-water mark above the final file size.
        let lastShownBytes = max(
            pendingBytes[videoId]?.received ?? 0,
            active[videoId]?.state.receivedBytes ?? 0
        )
        pendingDownloads[videoId] = nil
        pendingBytes[videoId] = nil
        guard let track else { clearEntry(videoId); return }

        let attributes = try? FileManager.default.attributesOfItem(atPath: location.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard Self.isAcceptableDownload(response: downloadTask.response, fileSize: size) else {
            try? FileManager.default.removeItem(at: location)
            // Drop the cached URL, or every retry resolves to the same dead one and the
            // download can never succeed until the entry expires hours later.
            APIClient.shared.invalidateStream(videoId: track.videoId)
            let http = downloadTask.response as? HTTPURLResponse
            let message: String
            if http?.statusCode == 429 {
                // The media host can rate-limit us too, and a bulk download is exactly when
                // it does. Recorded on the shared gate so the *resolutions* still queued
                // behind this one wait it out rather than adding to it.
                //
                // Closing the gate is all this does. It does *not* publish a cool-down: this
                // runs on a delegate callback with no queue behind it, so a lone 429'd track
                // used to leave the whole header captioned "Paused — resuming in 0:00" forever,
                // and a 429 partway through a batch captioned it "Paused" while the other
                // thirty transfers carried on landing. Whatever is still waiting to resolve will
                // park in `awaitRateLimitGate` and report it from there.
                let retryAfter = RateLimit.retryAfter(http?.value(forHTTPHeaderField: "Retry-After"))
                RateLimitGate.shared.recordRateLimit(retryAfter: retryAfter)
                message = Self.failureMessage(
                    for: track,
                    error: APIError.rateLimited(retryAfter: retryAfter ?? RateLimit.defaultCooldown)
                )
            } else {
                message = "Couldn't download \"\(track.title)\"."
            }
            // Kept as a failure rather than cleared: a rejected response is exactly the case
            // where the row has to offer a retry, and it is the one the user most needs told
            // apart from "never asked for".
            active[videoId]?.state = .failed(reason: message)
            errorMessage = message
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
            completedBytes[videoId] = max(size, lastShownBytes)
            save()
            clearEntry(videoId)
        } catch {
            let message = "Couldn't save \"\(track.title)\"."
            active[videoId]?.state = .failed(reason: message)
            errorMessage = message
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
        guard let entry = active[videoId] else { return }

        // `NSURLSessionTransferSizeUnknown` is carried as nil rather than dropped. The old
        // `guard totalBytesExpectedToWrite > 0 else { return }` discarded every update for a
        // server that sent no Content-Length, pinning that transfer at zero for its whole life.
        let expected: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        var received = totalBytesWritten
        let previous: (received: Int64, expected: Int64?)
        if let buffered = pendingBytes[videoId] {
            previous = buffered
        } else if case .transferring(let priorReceived, let priorExpected) = entry.state {
            previous = (priorReceived, priorExpected)
        } else {
            previous = (0, nil)
        }
        // A background-session retry restarts `totalBytesWritten` from a lower value against
        // the same expected size. Left alone the ring sweeps backwards, which reads as a bug;
        // a *different* expected size means a genuinely new response, so that case is taken
        // verbatim.
        if previous.expected == expected { received = max(received, previous.received) }

        pendingBytes[videoId] = (received, expected)
        scheduleFlush()
    }

    /// `didWriteData` fires per received chunk — several hundred times a second across a batch
    /// — and every one of them republished the progress dictionary, re-running the body of
    /// every visible row and every collection aggregate that reads it. A quarter second is
    /// well under the eye's threshold for a progress bar and two orders of magnitude fewer
    /// layout passes.
    ///
    /// A `Task.sleep` rather than `Timer.scheduledTimer`: a scheduled timer installs in the
    /// `.default` run-loop mode, which stops firing while a `List` is being dragged — progress
    /// would freeze precisely while the user scrolls to watch it.
    ///
    /// Only the *fraction* is coalesced. Changes of phase (queued→resolving, →failed,
    /// completion, cancel) write `active` directly and publish immediately, because those are
    /// the changes the user is waiting on.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            self?.flushBytes()
        }
    }

    private func flushBytes() {
        flushTask = nil
        let buffered = pendingBytes
        pendingBytes.removeAll()
        for (videoId, bytes) in buffered {
            // Only into entries that still exist — a completion or cancel between the last
            // chunk and this flush must not resurrect a finished row.
            guard active[videoId] != nil else { continue }
            active[videoId]?.state = .transferring(received: bytes.received, expected: bytes.expected)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let videoId = task.taskDescription else { return }
        guard let error else { return }
        let track = active[videoId]?.track ?? pendingDownloads[videoId]
        pendingDownloads[videoId] = nil
        pendingBytes[videoId] = nil
        // A cancel is the user's own doing, not a failure to report at them — and its entry
        // was already dropped synchronously by `cancel`/`cancelIds`.
        guard (error as NSError).code != NSURLErrorCancelled else { clearEntry(videoId); return }
        APIClient.shared.invalidateStream(videoId: videoId)
        let message = "Download failed for \"\(track?.title ?? videoId)\": \(error.localizedDescription)"
        active[videoId]?.state = .failed(reason: message)
        errorMessage = message
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
