import Foundation
import Swifter
import Network
import UIKit

/// Manually synchronized (via the caller's semaphore) box for bridging an async result
/// back across a thread boundary — safe despite `@unchecked Sendable` because only one
/// side ever touches it before the semaphore signals.
private final class ResultBox<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}

/// Embeds a tiny HTTP + WebSocket server in the app so a browser on the same WiFi
/// network can browse/search/play — a local "Spotify Connect"-style remote control.
/// No accounts, no auth: same trust model as AirPlay. Anyone on the same network while
/// this is running can control playback, which is an accepted tradeoff for a personal,
/// same-WiFi-only feature (see Library's VVDemus Connect toggle for the on/off switch).
@MainActor
final class LocalControlServer: ObservableObject {
    static let shared = LocalControlServer()

    /// Persisted user preference (separate from `isRunning`, the live state) — read at
    /// launch so the server auto-starts by default instead of requiring the user to
    /// re-enable it every session.
    static let defaultsKey = "vvdemus_connect_enabled"

    @Published private(set) var isRunning = false
    @Published private(set) var localAddress: String?
    let port: UInt16 = 51825

    private let server = HttpServer()
    private var sockets: Set<WebSocketSession> = []
    /// Swifter only fires its `disconnected` callback once a *blocking* per-connection
    /// socket read throws — which may never happen if a browser tab is killed, a laptop
    /// sleeps, or WiFi drops without a clean TCP close. Left unchecked, `sockets` (and the
    /// blocked read thread behind each stale entry) accumulates for the life of the app.
    /// The web client pings every 15s (see app.js); anything silent for longer than this
    /// gets dropped here instead of being broadcast to forever.
    private var socketLastSeen: [WebSocketSession: Date] = [:]
    private let socketStaleTimeout: TimeInterval = 45
    /// Which browser tab each socket belongs to — the client announces its id on connect
    /// and repeats it with every heartbeat (see app.js). Used to tell whether the tab that
    /// actually owns cast playback is still around, as opposed to merely *some* tab being
    /// connected.
    private var socketClientIds: [WebSocketSession: String] = [:]
    /// The tab that chose "This Computer". Exactly one tab may produce sound; this is what
    /// every other tab checks itself against, and what a reloaded tab uses to reclaim
    /// casting (its id survives the reload in sessionStorage).
    private var castClientId: String?
    /// How long the casting tab must be continuously *gone* before falling back to the
    /// iPhone — the web client's own reconnect logic (`app.js`) waits up to ~2s before
    /// retrying after any disconnect, clean or not, so reverting on the very next 1Hz
    /// broadcast tick (zero grace period) was treating a brief network hiccup or a
    /// perfectly normal reconnect-in-progress the same as the tab being closed for good,
    /// which looked like switching to "computer" instantly bouncing back to the phone.
    private let computerFallbackGrace: TimeInterval = 6
    private var castClientMissingSince: Date?
    /// The tab that was casting before an *automatic* fallback to the phone, and when that
    /// happened. A browser that kept playing on its own through the outage can reclaim
    /// playback when it reconnects — the phone only took over because it assumed the
    /// browser had died, and the device actually producing sound should win. Deliberately
    /// not honoured after the user chose the phone themselves.
    private var lastCastClientId: String?
    private var autoFallbackAt: Date?
    private let reclaimWindow: TimeInterval = 120
    /// When the casting browser last told us where playback had got to. A browser that is
    /// genuinely playing reports about once a second, so silence here means playback has
    /// stopped over there whatever the socket says — a laptop that sleeps or drops off
    /// WiFi often leaves a TCP connection that looks alive for far longer than the music
    /// has actually been stopped, which stranded playback on a device producing no sound.
    private var lastComputerReportAt: Date?
    /// Long enough to never fire during the second or two it takes to resolve a stream URL
    /// (and the clock is reset outright whenever a new track starts, or on a device
    /// switch), short enough that a sleeping laptop doesn't leave the music dead for long.
    private let computerReportTimeout: TimeInterval = 8
    /// Watches for the phone starting a new track, which is the one legitimate reason for
    /// reports to pause briefly (nothing is loaded in the browser yet).
    private var lastSeenTrackLoadEpoch: Int?
    /// Lets the periodic broadcast skip re-sending queue contents that haven't moved.
    private var lastBroadcastQueueFingerprint: Int?
    private var needsFullBroadcast = true
    /// When the 1Hz broadcast last ran, used to notice that the app was suspended.
    private var lastBroadcastTickAt: Date?
    private let suspensionGapThreshold: TimeInterval = 5
    private var broadcastTimer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    // MARK: - Background survival

    /// iOS only keeps a backgrounded process alive on the `audio` background mode while
    /// audio is genuinely playing (see `BackgroundKeepAlive`) — this background task just
    /// buys a further, one-time ~30s grace window on top of that for whichever of the two
    /// is already covering the moment backgrounding happens.
    func applicationDidEnterBackground() {
        guard isRunning, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VVDemusConnect") { [weak self] in
            guard let self else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
    }

    func applicationWillEnterForeground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        registerRoutes()
        do {
            try server.start(port, forceIPv4: true)
            isRunning = true
            localAddress = Self.currentWiFiAddress()
            broadcastTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.broadcastState() }
            }
            RadioCacheStore.shared.onUpdate = { [weak self] videoId, tracks in
                self?.broadcastRadioUpdate(videoId: videoId, tracks: tracks)
            }
            PlayerService.shared.onComputerCommand = { [weak self] command in
                self?.broadcastCommand(command)
            }
        } catch {
            isRunning = false
        }
    }

    func stop() {
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        RadioCacheStore.shared.onUpdate = nil
        PlayerService.shared.onComputerCommand = nil
        server.stop()
        sockets.removeAll()
        socketLastSeen.removeAll()
        socketClientIds.removeAll()
        castClientId = nil
        castClientMissingSince = nil
        lastComputerReportAt = nil
        lastSeenTrackLoadEpoch = nil
        lastBroadcastTickAt = nil
        isRunning = false
    }

    // MARK: - Routes

    private func registerRoutes() {
        server["/"] = { [weak self] _ in self?.staticFile("index", "html") ?? .notFound }
        server["/app.js"] = { [weak self] _ in self?.staticFile("app", "js", contentType: "application/javascript") ?? .notFound }
        server["/style.css"] = { [weak self] _ in self?.staticFile("style", "css", contentType: "text/css") ?? .notFound }

        server["/ws"] = websocket(
            text: { [weak self] session, text in
                // Any text frame (the client's heartbeat ping) counts as "still alive".
                // The client tags every frame with `hello:<clientId>` so the socket can be
                // attributed to a specific browser tab.
                Task { @MainActor in
                    self?.socketLastSeen[session] = Date()
                    if let id = Self.clientId(fromFrame: text) {
                        self?.socketClientIds[session] = id
                    }
                }
            },
            connected: { [weak self] session in
                Task { @MainActor in
                    self?.sockets.insert(session)
                    self?.socketLastSeen[session] = Date()
                    self?.needsFullBroadcast = true
                }
            },
            disconnected: { [weak self] session in
                Task { @MainActor in
                    self?.sockets.remove(session)
                    self?.socketLastSeen.removeValue(forKey: session)
                    self?.socketClientIds.removeValue(forKey: session)
                }
            }
        )

        server.GET["/api/state"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            return self.jsonResponse(self.onMain { self.stateSnapshot() })
        }

        server.POST["/api/play"] = { [weak self] request in
            guard let self, let body: PlayRequestBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
            self.onMain {
                PlayerService.shared.play(track: body.track, context: body.context ?? [], contextTitle: body.contextTitle)
            }
            return .ok(.text("ok"))
        }
        server.POST["/api/toggle"] = { [weak self] _ in
            self?.onMain { PlayerService.shared.togglePlayPause() }
            return .ok(.text("ok"))
        }
        server.POST["/api/next"] = { [weak self] _ in
            self?.onMain { PlayerService.shared.advance() }
            return .ok(.text("ok"))
        }
        server.POST["/api/previous"] = { [weak self] _ in
            self?.onMain { PlayerService.shared.previous() }
            return .ok(.text("ok"))
        }
        server.POST["/api/seek"] = { [weak self] request in
            guard let self, let body: SeekRequestBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
            self.onMain { PlayerService.shared.seek(to: body.seconds) }
            return .ok(.text("ok"))
        }
        server.POST["/api/shuffle"] = { [weak self] _ in
            self?.onMain { PlayerService.shared.toggleShuffle() }
            return .ok(.text("ok"))
        }

        server.POST["/api/device"] = { [weak self] request in
            guard let self, let body: DeviceRequestBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
            self.onMain {
                // Recorded before the switch so the very next broadcast already names the
                // owning tab — otherwise the tab that just claimed casting would see
                // itself as "not the cast tab" for up to a second and stay silent.
                self.castClientId = body.device == .computer ? body.clientId : nil
                self.castClientMissingSince = nil
                self.lastComputerReportAt = Date()
                // A deliberate choice, so nothing may quietly undo it later.
                self.autoFallbackAt = nil
                self.lastCastClientId = nil
                PlayerService.shared.setActiveDevice(body.device)
            }
            return .ok(.text("ok"))
        }
        // The browser reporting that it moved on without us — see
        // `PlayerService.adoptExternalPlayback`.
        server.POST["/api/playback/adopt"] = { [weak self] request in
            guard let self, let body: AdoptPlaybackBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
            self.onMain {
                self.lastComputerReportAt = Date()
                // The browser never stopped playing; if we'd given up on it and pulled
                // playback back to the phone, hand it straight back rather than cutting
                // off audio that's been running the whole time.
                if PlayerService.shared.activeDevice == .iphone, self.mayReclaimCasting(body.clientId) {
                    self.castClientId = body.clientId
                    self.castClientMissingSince = nil
                    self.autoFallbackAt = nil
                    self.lastCastClientId = nil
                    PlayerService.shared.setActiveDevice(.computer)
                }
                PlayerService.shared.adoptExternalPlayback(videoId: body.videoId, progress: body.progress)
            }
            return .ok(.text("ok"))
        }
        server.POST["/api/playback/report"] = { [weak self] request in
            guard let self, let body: PlaybackReportBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
            self.onMain {
                // Records liveness even for a report PlayerService goes on to discard as
                // stale — an out-of-date report still proves the browser is alive and
                // playing, which is all this timestamp is for.
                self.lastComputerReportAt = Date()
                PlayerService.shared.applyExternalReport(
                    epoch: body.epoch,
                    videoId: body.videoId,
                    progress: body.progress,
                    duration: body.duration,
                    isPlaying: body.isPlaying
                )
            }
            return .ok(.text("ok"))
        }
        // Serves a downloaded track's audio to the browser when it's the active playback
        // device — it can't reach a file:// URL on the phone's disk otherwise.
        server.GET["/api/audio/local/:videoId"] = { [weak self] request in
            guard let self,
                  let videoId = request.params[":videoId"],
                  let fileURL = self.onMain({ DownloadManager.shared.localFileURL(forVideoId: videoId) })
            else { return .notFound }
            return Self.audioFileResponse(at: fileURL, rangeHeader: request.headers["range"])
        }

        server.POST["/api/queue/add"] = { [weak self] request in
            guard let self, let body: TrackOnlyBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
            self.onMain { PlayerService.shared.addToQueue(body.track) }
            return .ok(.text("ok"))
        }
        server.POST["/api/queue/play-next"] = { [weak self] request in
            guard let self, let body: TrackOnlyBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
            self.onMain { PlayerService.shared.playNext(body.track) }
            return .ok(.text("ok"))
        }
        server.POST["/api/queue/remove"] = { [weak self] request in
            guard let self, let body: TrackOnlyBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
            self.onMain { PlayerService.shared.removeFromQueue(body.track) }
            return .ok(.text("ok"))
        }
        server.POST["/api/queue/skip-to"] = { [weak self] request in
            guard let self, let body: TrackOnlyBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
            self.onMain { PlayerService.shared.skipTo(body.track) }
            return .ok(.text("ok"))
        }

        server.GET["/api/search"] = { [weak self] request in
            guard let self else { return .internalServerError }
            let query = request.queryParams.first(where: { $0.0 == "q" })?.1 ?? ""
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return self.jsonResponse([Track]()) }
            switch self.awaitAsync({ try await APIClient.shared.search(query) }) {
            case .success(let tracks): return self.jsonResponse(tracks)
            case .failure: return .internalServerError
            }
        }

        // Shares the phone's cached Home feed rather than building its own — opening the
        // web remote used to cost a full set of recommendation fetches even when the phone
        // had just built the identical shelves.
        server.GET["/api/home"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            switch self.awaitAsync({ try await HomeFeedStore.shared.refreshIfNeeded() }) {
            case .success(let sections): return self.jsonResponse(sections)
            case .failure: return .internalServerError
            }
        }

        server.GET["/api/radio"] = { [weak self] request in
            guard let self else { return .internalServerError }
            guard let videoId = request.queryParams.first(where: { $0.0 == "videoId" })?.1 else {
                return .badRequest(.text("missing videoId"))
            }
            // Serve the same cached mix the phone would show, so opening a radio from
            // the web shows exactly what's already on the phone instead of a different
            // fresh fetch (YouTube's radio endpoint varies between calls).
            if let cached = self.onMain({ RadioCacheStore.shared.tracks(for: videoId) }) {
                return self.jsonResponse(cached)
            }
            switch self.awaitAsync({ try await APIClient.shared.radio(videoId: videoId, limit: 50) }) {
            case .success(let tracks):
                // `storeIfAbsent` in case another request populated this radio while this
                // one was in flight — first mix fetched wins, and stays put.
                self.onMain { RadioCacheStore.shared.storeIfAbsent(tracks, for: videoId) }
                return self.jsonResponse(self.onMain { RadioCacheStore.shared.tracks(for: videoId) } ?? tracks)
            case .failure: return .internalServerError
            }
        }
        server.POST["/api/radio/refresh"] = { [weak self] request in
            guard let self, let body: VideoIdBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
            switch self.awaitAsync({ try await APIClient.shared.radio(videoId: body.videoId, limit: 50) }) {
            case .success(let tracks):
                // Storing pushes onUpdate → broadcastRadioUpdate, which is what actually
                // syncs this to the phone (and any other open browser) live.
                self.onMain { RadioCacheStore.shared.store(tracks, for: body.videoId) }
                return self.jsonResponse(tracks)
            case .failure: return .internalServerError
            }
        }
        server.POST["/api/radio/play"] = { [weak self] request in
            guard let self, let body: RadioPlayBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
            // Plays the mix this radio actually shows. It used to fetch a fresh one every
            // time, so pressing play on a radio started a different set of songs than the
            // list you pressed it from.
            if let cached = self.onMain({ RadioCacheStore.shared.tracks(for: body.seedTrack.videoId) }), !cached.isEmpty {
                let ordered = (body.shuffled ?? false) ? cached.shuffled() : cached
                self.onMain {
                    PlayerService.shared.play(
                        track: ordered[0],
                        context: ordered,
                        contextTitle: "\(body.seedTrack.title) Radio"
                    )
                    RadioHistoryStore.shared.record(seed: body.seedTrack)
                }
                return .ok(.text("ok"))
            }
            switch self.awaitAsync({ try await APIClient.shared.radio(videoId: body.seedTrack.videoId, limit: 50) }) {
            case .success(let mix):
                let seed = mix.first ?? body.seedTrack
                let ordered = (body.shuffled ?? false) ? mix.shuffled() : mix
                self.onMain {
                    // PlayerService.play finds `track` inside `context` and queues whatever
                    // comes after it — context must include the track itself, not exclude it.
                    PlayerService.shared.play(
                        track: ordered.first ?? seed,
                        context: ordered,
                        contextTitle: "\(body.seedTrack.title) Radio"
                    )
                    RadioHistoryStore.shared.record(seed: body.seedTrack)
                    RadioCacheStore.shared.storeIfAbsent(mix, for: body.seedTrack.videoId)
                }
                return .ok(.text("ok"))
            case .failure:
                return .internalServerError
            }
        }

        server.GET["/api/library/liked"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            return self.jsonResponse(self.onMain { LikedSongsStore.shared.tracks })
        }
        server.POST["/api/library/liked/toggle"] = { [weak self] request in
            guard let self, let body: TrackOnlyBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
            self.onMain { LikedSongsStore.shared.toggle(body.track) }
            return .ok(.text("ok"))
        }

        server.GET["/api/library/playlists"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            return self.jsonResponse(self.onMain { PlaylistStore.shared.playlists })
        }
        server.POST["/api/library/playlists/create"] = { [weak self] request in
            guard let self, let body: CreatePlaylistBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
            let trimmed = body.name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return .badRequest(.text("empty name")) }
            self.onMain { PlaylistStore.shared.create(name: trimmed) }
            return .ok(.text("ok"))
        }
        server.POST["/api/library/playlists/:id/add"] = { [weak self] request in
            guard let self,
                  let idString = request.params[":id"] ?? request.params["id"],
                  let id = UUID(uuidString: idString),
                  let body: AddToPlaylistBody = self.decodeBody(request) else { return .badRequest(.text("bad request")) }
            self.onMain {
                if let playlist = PlaylistStore.shared.playlists.first(where: { $0.id == id }) {
                    PlaylistStore.shared.addTrack(body.track, to: playlist)
                }
            }
            return .ok(.text("ok"))
        }

        server.GET["/api/library/radios"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            return self.jsonResponse(self.onMain { RadioHistoryStore.shared.stations })
        }

        // Downloading is phone-side storage, so the remote can only ask for it — which is
        // all the iOS long-press menu does too.
        server.POST["/api/library/download"] = { [weak self] request in
            guard let self, let body: TrackOnlyBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
            self.onMain { DownloadManager.shared.download(body.track) }
            return .ok(.text("ok"))
        }
        server.POST["/api/library/download/remove"] = { [weak self] request in
            guard let self, let body: TrackOnlyBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
            self.onMain { DownloadManager.shared.remove(body.track) }
            return .ok(.text("ok"))
        }

        server.GET["/api/library/downloads"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            return self.jsonResponse(self.onMain { DownloadManager.shared.downloadedTracks })
        }

        server.GET["/api/library/daylist"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            let snapshot = self.onMain {
                DaylistSnapshot(title: DaylistStore.shared.title, tracks: DaylistStore.shared.tracks)
            }
            return self.jsonResponse(snapshot)
        }
        server.POST["/api/library/daylist/refresh"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            _ = self.awaitAsync({ await DaylistStore.shared.refresh() })
            return .ok(.text("ok"))
        }
    }

    // MARK: - Serving downloaded audio

    /// Byte-range aware file response. Without this a cast downloaded track was served as
    /// a length-less, non-seekable stream: handing playback to the computer mid-song
    /// silently restarted it from 0:00 (the browser discards a `currentTime` it can't
    /// satisfy), and dragging the scrubber did nothing at all. Streaming the requested
    /// slice in chunks also keeps a whole track from being read into memory per request.
    private static func audioFileResponse(at url: URL, rangeHeader: String?) -> HttpResponse {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil,
              size > 0 else { return .notFound }
        let contentType = url.pathExtension == "m4a" ? "audio/mp4" : "video/mp4"

        let requested = rangeHeader.flatMap { parseByteRange($0, fileSize: size) }
        let start = requested?.start ?? 0
        let end = requested?.end ?? size - 1
        let length = end - start + 1

        var headers = [
            "Content-Type": contentType,
            "Accept-Ranges": "bytes",
            // Swifter omits Content-Length for streamed (`.raw`) responses, and a media
            // element with no length can't seek — so it's set explicitly here.
            "Content-Length": String(length),
            // Swifter closes the socket after any `.raw` response; saying so keeps the
            // browser from sending its next range request onto a dying connection.
            "Connection": "close",
        ]
        if requested != nil {
            headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
        }

        let write: (HttpResponseBodyWriter) throws -> Void = { writer in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(start))
            var remaining = length
            while remaining > 0 {
                let chunk = handle.readData(ofLength: min(chunkSize, remaining))
                if chunk.isEmpty { break }
                try writer.write(chunk)
                remaining -= chunk.count
            }
        }
        return requested == nil
            ? .raw(200, "OK", headers, write)
            : .raw(206, "Partial Content", headers, write)
    }

    private static let chunkSize = 256 * 1024

    /// Handles the only form browsers actually send: a single `bytes=start-[end]` range.
    /// Anything else (multiple ranges, suffix ranges, garbage) returns nil, which serves
    /// the whole file — always a valid response to a range request.
    private static func parseByteRange(_ header: String, fileSize: Int) -> (start: Int, end: Int)? {
        guard header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        guard !spec.contains(","), let separator = spec.firstIndex(of: "-") else { return nil }
        guard let start = Int(spec[spec.startIndex..<separator]), start < fileSize else { return nil }
        let endText = spec[spec.index(after: separator)...]
        let end = endText.isEmpty ? fileSize - 1 : (Int(endText).map { min($0, fileSize - 1) } ?? fileSize - 1)
        guard end >= start else { return nil }
        return (start, end)
    }

    // MARK: - State

    private func stateSnapshot() -> StateSnapshot {
        let player = PlayerService.shared
        return StateSnapshot(
            isPlaying: player.isPlaying,
            isLoading: player.isLoading,
            progress: player.progress,
            duration: player.duration,
            isShuffling: player.isShuffling,
            hasPrevious: player.hasPrevious,
            queueContextTitle: player.queueContextTitle,
            currentTrack: player.currentTrack,
            manualQueue: player.manualQueue,
            contextQueue: player.contextQueue,
            likedVideoIds: LikedSongsStore.shared.tracks.map(\.videoId),
            activeDevice: player.activeDevice,
            streamUrl: player.externalStream?.url,
            streamVideoId: player.externalStream?.videoId,
            castClientId: player.activeDevice == .computer ? castClientId : nil,
            playbackEpoch: player.playbackEpoch,
            trackLoadEpoch: player.trackLoadEpoch,
            nextTrack: player.activeDevice == .computer ? player.upNextTrack : nil,
            nextStreamUrl: player.activeDevice == .computer ? player.upNextStream?.url : nil
        )
    }

    private func broadcastCommand(_ command: PlayerService.PlaybackCommand) {
        let message: PlaybackCommandMessage
        switch command {
        case .toggle:
            message = PlaybackCommandMessage(action: "toggle", seconds: nil)
        case .seek(let seconds):
            message = PlaybackCommandMessage(action: "seek", seconds: seconds)
        }
        broadcast(message)
    }

    private func broadcastState() {
        forgiveSuspensionGap()
        pruneStaleSockets()
        guard !sockets.isEmpty else { return }
        let snapshot = stateSnapshot()
        let fingerprint = snapshot.queueFingerprint
        // A tab that just connected hasn't necessarily fetched a full state yet, so the
        // first broadcast after any connection carries everything.
        let sendFull = needsFullBroadcast || fingerprint != lastBroadcastQueueFingerprint
        lastBroadcastQueueFingerprint = fingerprint
        needsFullBroadcast = false
        broadcast(StateMessage(state: sendFull ? snapshot : snapshot.withoutQueues()))
    }

    /// This timer is supposed to fire every second. A much longer gap means the app wasn't
    /// running — iOS suspended or throttled it — rather than that anything went wrong with
    /// the browser.
    ///
    /// Every staleness clock here is wall-clock based, so after such a gap they all read as
    /// long overdue at once: the first tick on waking would decide the casting browser had
    /// gone silent and haul playback back to the phone, cutting off a computer that had
    /// been playing happily the whole time. The clocks are reset instead, giving clients
    /// the same grace they'd get from a fresh start.
    private func forgiveSuspensionGap() {
        defer { lastBroadcastTickAt = Date() }
        guard let lastBroadcastTickAt else { return }
        let gap = Date().timeIntervalSince(lastBroadcastTickAt)
        guard gap > suspensionGapThreshold else { return }
        NSLog("[LocalControlServer] resumed after a %.0fs gap — resetting staleness clocks", gap)
        lastComputerReportAt = Date()
        castClientMissingSince = nil
        for session in sockets {
            socketLastSeen[session] = Date()
        }
    }

    private func pruneStaleSockets() {
        let cutoff = Date().addingTimeInterval(-socketStaleTimeout)
        let stale = sockets.filter { (socketLastSeen[$0] ?? .distantPast) < cutoff }
        for session in stale {
            sockets.remove(session)
            socketLastSeen.removeValue(forKey: session)
        }
        // Nothing left to actually produce the sound — fall back to the phone instead of
        // leaving playback silently stuck on a device nothing is listening on. Keyed on
        // the *casting tab* specifically, not on whether any socket at all is connected:
        // with the old check, closing the casting tab while another tab (or another
        // machine's browser) still had the remote open left playback frozen on "computer"
        // forever, with no tab willing to play it. Gated by a grace period (see
        // `computerFallbackGrace`) so a momentary disconnect that the client is already
        // reconnecting from doesn't get treated as "gone for good."
        guard PlayerService.shared.activeDevice == .computer else {
            castClientId = nil
            castClientMissingSince = nil
            lastSeenTrackLoadEpoch = nil
            return
        }
        // A newly started track means the browser has nothing loaded to report on yet;
        // restart the silence clock rather than counting that gap against it.
        let trackLoadEpoch = PlayerService.shared.trackLoadEpoch
        if lastSeenTrackLoadEpoch != trackLoadEpoch {
            lastSeenTrackLoadEpoch = trackLoadEpoch
            lastComputerReportAt = Date()
        }
        // Silence while playback is supposed to be running is conclusive on its own — the
        // timeout is already a generous window, so no further grace is added on top; the
        // grace period exists for the socket check, whose "gone" can mean a reconnect
        // that's a second away from completing.
        guard computerIsReportingPlayback else {
            fallBackToPhone()
            return
        }
        guard !castClientIsConnected else {
            castClientMissingSince = nil
            return
        }
        let missingSince = castClientMissingSince ?? Date()
        castClientMissingSince = missingSince
        if Date().timeIntervalSince(missingSince) >= computerFallbackGrace {
            fallBackToPhone()
        }
    }

    private func fallBackToPhone() {
        lastCastClientId = castClientId
        autoFallbackAt = Date()
        PlayerService.shared.setActiveDevice(.iphone)
        castClientId = nil
        castClientMissingSince = nil
        lastSeenTrackLoadEpoch = nil
    }

    /// Whether `clientId` is the tab we just took playback away from, recently enough that
    /// it's plausibly still playing the same song.
    private func mayReclaimCasting(_ clientId: String?) -> Bool {
        guard let clientId, clientId == lastCastClientId, let autoFallbackAt else { return false }
        return Date().timeIntervalSince(autoFallbackAt) < reclaimWindow
    }

    private var castClientIsConnected: Bool {
        guard let castClientId else { return false }
        return sockets.contains { socketClientIds[$0] == castClientId }
    }

    /// Whether the browser still sounds alive. Only meaningful while playback is supposed
    /// to be running — a paused browser correctly sends nothing, so silence then says
    /// nothing about whether it's still there.
    private var computerIsReportingPlayback: Bool {
        guard PlayerService.shared.isPlaying else { return true }
        guard let lastComputerReportAt else { return true }
        return Date().timeIntervalSince(lastComputerReportAt) < computerReportTimeout
    }

    /// Frames are `hello:<clientId>` (sent on connect and with every heartbeat).
    private static func clientId(fromFrame text: String) -> String? {
        let prefix = "hello:"
        guard text.hasPrefix(prefix) else { return nil }
        let id = String(text.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    private func broadcastRadioUpdate(videoId: String, tracks: [Track]) {
        guard !sockets.isEmpty else { return }
        broadcast(RadioUpdateMessage(videoId: videoId, tracks: tracks))
    }

    private func broadcast<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return }
        for socket in sockets {
            socket.writeText(text)
        }
    }

    // MARK: - Helpers

    /// `.ok(.data(...))` rather than `.raw`: Swifter only emits a `Content-Length` (and
    /// only then keeps the connection alive) for bodies whose length it knows. A `.raw`
    /// response advertises neither a length nor `Connection: close`, yet Swifter closes
    /// the socket regardless — so a keep-alive client (every browser, and the JS `fetch`
    /// in app.js) could send its next request onto a connection already being torn down
    /// and get a malformed reply. That surfaced as sporadic failed requests from the web
    /// remote whenever traffic was busy.
    private func staticFile(_ name: String, _ ext: String, contentType: String = "text/html") -> HttpResponse {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "WebUI"),
            let data = try? Data(contentsOf: url) else {
            return .notFound
        }
        return .ok(.data(data, contentType: contentType))
    }

    private func decodeBody<T: Decodable>(_ request: HttpRequest) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(request.body))
    }

    /// See `staticFile` for why this is `.ok(.data(...))` and not `.raw`.
    private func jsonResponse<T: Encodable>(_ value: T) -> HttpResponse {
        guard let data = try? JSONEncoder().encode(value) else { return .internalServerError }
        return .ok(.data(data, contentType: "application/json"))
    }

    /// Bridges a synchronous Swifter request-handler thread into MainActor-isolated
    /// code, which almost all of the app's state (PlayerService, stores) lives on.
    private func onMain<T>(_ work: @escaping @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(work)
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated(work)
        }
    }

    /// Bridges an async throwing call (e.g. a network fetch) into a synchronous return,
    /// blocking the calling Swifter worker thread — safe since Swifter uses its own
    /// thread pool, never the app's main thread, for request handling.
    private func awaitAsync<T>(_ operation: @escaping () async throws -> T) -> Result<T, Error> {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                box.value = .success(try await operation())
            } catch {
                box.value = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return box.value ?? .failure(APIError.server("no result"))
    }

    private static func currentWiFiAddress() -> String? {
        var address: String?
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" else { continue }
            var addr = interface.ifa_addr.pointee
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: hostname)
        }
        return address
    }
}
