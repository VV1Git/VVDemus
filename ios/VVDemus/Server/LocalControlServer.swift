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
    /// Why the server isn't running, when the user asked for it to be. Shown in Library
    /// instead of leaving the toggle on next to a blank address.
    @Published private(set) var startupError: String?
    /// Settable so tests can bind a throwaway port instead of fighting a running app (or
    /// a previous test) for the real one.
    var port: UInt16 = 51825
    /// Generous next to any real playlist or mix, small enough that a bad request can't
    /// turn every broadcast into megabytes.
    static let maximumContextTracks = 2_000
    static let maximumPlaylistNameLength = 200
    /// New on every launch — see `StateSnapshot.serverInstanceId`.
    private let instanceId = UUID().uuidString

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
    /// The last time this app's own timing was unreliable — a missed broadcast tick, or
    /// being sent to the background. Every staleness check here measures wall-clock time,
    /// so during and just after such a moment they all read as overdue at once and would
    /// blame the browser for the phone's own stall.
    private var lastIrregularTickAt: Date?
    private let tickSettlingPeriod: TimeInterval = 10
    /// How long the casting tab's WebSocket heartbeat may be silent before the tab counts
    /// as genuinely gone. The client pings every 15s.
    private let castHeartbeatTimeout: TimeInterval = 20
    private var broadcastTimer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    // MARK: - Background survival

    /// iOS only keeps a backgrounded process alive on the `audio` background mode while
    /// audio is genuinely playing (see `BackgroundKeepAlive`) — this background task just
    /// buys a further, one-time ~30s grace window on top of that for whichever of the two
    /// is already covering the moment backgrounding happens.
    func applicationDidEnterBackground() {
        // Backgrounding stalls the run loop briefly; anything measured in wall-clock time
        // across that moment is not evidence about the browser.
        lastIrregularTickAt = Date()
        guard isRunning, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VVDemusConnect") { [weak self] in
            guard let self else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
    }

    /// Starts a fresh background window. Used when the keep-alive audio is deliberately
    /// given up while backgrounded, so the server isn't left with whatever remained of the
    /// original grace period.
    func renewBackgroundTask() {
        guard isRunning else { return }
        let previous = backgroundTask
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VVDemusConnect") { [weak self] in
            guard let self else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
        if previous != .invalid { UIApplication.shared.endBackgroundTask(previous) }
    }

    func applicationWillEnterForeground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Lifecycle

    /// Largest request body accepted, before a byte of it is read.
    ///
    /// Swifter takes `Content-Length` at face value and calls `allocate(capacity:)` with it
    /// *before* reading the body, so `Content-Length: 4000000000` from anything on the Wi-Fi
    /// makes the app attempt a 4 GB allocation and trap. A `/api/play` carrying the maximum
    /// 2000-track context is a few hundred KB, so this is generous.
    static let maximumRequestBodyBytes = 4 * 1024 * 1024

    /// Rejects requests that didn't come from this server's own page.
    ///
    /// The threat isn't a stranger typing the address in — it's an ordinary web page the
    /// user happens to visit issuing requests to the phone in the background. A form-style
    /// POST needs no preflight, so without this check any page could start playback, queue
    /// downloads, or plant a crafted track that the phone then stores and re-renders.
    /// `Host` is checked for the same reason from the other direction: without it a name the
    /// attacker controls can be re-pointed at the phone's LAN address (DNS rebinding) and
    /// every response becomes readable from their origin.
    ///
    /// Deliberately permissive about a *missing* `Origin`: curl, the phone itself and
    /// non-browser clients send none, and they were never the risk.
    nonisolated static func isAllowedOrigin(_ origin: String?, port: UInt16) -> Bool {
        guard let origin, !origin.isEmpty, origin != "null" else { return true }
        guard let url = URL(string: origin), let host = url.host else { return false }
        guard (url.port ?? -1) == Int(port) else { return false }
        return host == "localhost" || host == "127.0.0.1" || isIPv4Literal(host)
    }

    nonisolated static func isAllowedHost(_ host: String?, port: UInt16) -> Bool {
        guard let host, !host.isEmpty else { return true }
        // Strip the port; IPv6 literals arrive bracketed.
        let name: String
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            name = String(host[host.index(after: host.startIndex)..<close])
        } else {
            name = host.split(separator: ":").first.map(String.init) ?? host
        }
        return name == "localhost" || name == "::1" || isIPv4Literal(name)
    }

    /// An address the user typed or the page was served from — never a name an attacker can
    /// point wherever they like.
    nonisolated static func isIPv4Literal(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isNumber) && (Int(part) ?? 256) <= 255
        }
    }

    private func installGuards() {
        let port = self.port
        server.middleware = [
            { request in
                // Swifter lowercases header names as it parses them.
                if let length = request.headers["content-length"].flatMap(Int.init),
                   length > Self.maximumRequestBodyBytes {
                    return .raw(413, "Payload Too Large", [:], nil)
                }
                guard Self.isAllowedHost(request.headers["host"], port: port) else {
                    return .raw(403, "Forbidden", [:], nil)
                }
                guard Self.isAllowedOrigin(request.headers["origin"], port: port) else {
                    return .raw(403, "Forbidden", [:], nil)
                }
                return nil
            },
        ]
    }

    /// Brings the server back if its accept loop has quietly died.
    ///
    /// Swifter's loop is `while let socket = try? socket.acceptClientSocket()`, so *any*
    /// `accept()` error ends it for good — `ECONNABORTED` when a peer resets between SYN and
    /// accept (routine when a laptop sleeps or Wi-Fi flaps), `EINTR`, or `EMFILE` when the
    /// process is briefly out of descriptors. It then closes the listening socket and marks
    /// itself stopped.
    ///
    /// Nothing noticed. `isRunning` stayed true, no error was surfaced, the Library screen
    /// went on displaying the address, and the broadcast timer kept writing to dead
    /// sockets — the remote was simply unreachable until the user thought to toggle Connect
    /// off and on. Checking Swifter's own state each second and restarting is cheap, and
    /// makes the failure self-healing rather than permanent.
    private func restartIfAcceptLoopDied() {
        guard isRunning, !server.operating else { return }
        NSLog("[Connect] accept loop stopped on its own — restarting")
        do {
            try server.start(port, forceIPv4: true, priority: .userInitiated)
            startupError = nil
        } catch {
            // Left for the next tick: the port is often still in TIME_WAIT for a moment.
            startupError = error.localizedDescription
        }
    }

    func start() {
        guard !isRunning else { return }
        registerRoutes()
        installGuards()
        do {
            // Swifter defaults its accept loop and every connection thread to `.background`
            // QoS, which under any UI load starved `/api/state`, `/api/toggle` and
            // `/api/playback/report` for hundreds of milliseconds — long enough to trip the
            // browser's own staleness timeouts and make playback look stuck.
            try server.start(port, forceIPv4: true, priority: .userInitiated)
            isRunning = true
            startupError = nil
            localAddress = Self.currentWiFiAddress()
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.restartIfAcceptLoopDied()
                    self?.broadcastState()
                }
            }
            // `.common`, not the default mode: while a SwiftUI list is being scrolled the
            // run loop is in tracking mode and a default-mode timer stops firing entirely,
            // so the browser went stale for as long as the user kept their finger down.
            RunLoop.main.add(timer, forMode: .common)
            broadcastTimer = timer
            RadioCacheStore.shared.onUpdate = { [weak self] videoId, tracks in
                self?.broadcastRadioUpdate(videoId: videoId, tracks: tracks)
            }
            PlayerService.shared.onComputerCommand = { [weak self] command in
                self?.broadcastCommand(command)
            }
        } catch {
            isRunning = false
            // Surfaced rather than swallowed: the Library toggle stayed on with no address
            // and no explanation, which looks identical to "still starting up". The usual
            // cause is port 51825 already being held by a previous instance.
            startupError = "Couldn't start on port \(port). Another app may be using it."
            NSLog("[LocalControlServer] failed to start on port %d: %@", port, error.localizedDescription)
        }
    }

    func stop() {
        // Before anything is torn down. Turning Connect off while the computer was the
        // active device used to leave `activeDevice == .computer` with no server to relay
        // to: `togglePlayPause` kept taking the casting branch into a now-nil callback and
        // every new track was routed to the browser, so the phone played nothing at all,
        // permanently, behind a UI that said it was playing. The automatic recovery
        // couldn't help either — it runs on the timer this method invalidates.
        PlayerService.shared.setActiveDevice(.iphone)
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        RadioCacheStore.shared.onUpdate = nil
        PlayerService.shared.onComputerCommand = nil
        server.stop()
        sockets.removeAll()
        socketLastSeen.removeAll()
        socketClientIds.removeAll()
        writeQueues.removeAll()
        castClientId = nil
        castClientMissingSince = nil
        lastComputerReportAt = nil
        lastSeenTrackLoadEpoch = nil
        lastBroadcastTickAt = nil
        // Fallback bookkeeping too, or a stop/start cycle carries a stale reclaim window
        // and queue fingerprint across and the first broadcast after restarting is a
        // partial one that no newly-connected tab can make sense of.
        lastIrregularTickAt = nil
        autoFallbackAt = nil
        lastCastClientId = nil
        lastBroadcastQueueFingerprint = nil
        needsFullBroadcast = true
        startupError = nil
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
                    guard let self else { return }
                    // Each callback hops onto the main actor as its own unstructured task,
                    // and nothing orders them against each other. A `text` task landing
                    // after this session's `disconnected` task used to re-insert liveness
                    // entries for a socket that was no longer in `sockets` — where the
                    // pruner could never see it again, so it leaked for good. Only a
                    // session that is still connected may refresh anything.
                    guard self.sockets.contains(session) else { return }
                    self.socketLastSeen[session] = Date()
                    if let id = Self.clientId(fromFrame: text) {
                        self.socketClientIds[session] = id
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
                    self?.writeQueues.removeValue(forKey: session)
                }
            }
        )

        server.GET["/api/state"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            return self.jsonResponse(self.onMain { self.stateSnapshot() })
        }

        server.POST["/api/play"] = { [weak self] request in
            guard let self, let body: PlayRequestBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
            // Bounded: the context is held in the queue and re-encoded into every state
            // broadcast, so an oversized one is megabytes pushed to every socket, once a
            // second, forever.
            guard (body.context?.count ?? 0) <= Self.maximumContextTracks else {
                return .badRequest(.text("context too large"))
            }
            self.onMain {
                PlayerService.shared.play(
                    track: body.track,
                    context: body.context ?? [],
                    contextTitle: body.contextTitle,
                    contextSeed: body.contextSeed
                )
            }
            return .ok(.text("ok"))
        }
        server.POST["/api/toggle"] = { [weak self] _ in
            self?.onMain { PlayerService.shared.togglePlayPause() }
            return .ok(.text("ok"))
        }
        server.POST["/api/next"] = { [weak self] request in
            guard let self else { return .internalServerError }
            // The browser names the track that ended so a next already handled on the phone
            // isn't applied twice, which skipped a song outright.
            let from: String? = (try? JSONSerialization.jsonObject(with: Data(request.body)) as? [String: Any])?
                .flatMap { $0["videoId"] as? String }
            self.onMain { PlayerService.shared.advanceIfCurrent(from) }
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
            // Claiming "computer" without saying which tab is a guaranteed dead end: no tab
            // would ever match `castClientId`, so nothing would play and nothing would
            // report, and the liveness check would silently haul playback back to the phone
            // about eight seconds later. Better to reject it outright.
            guard body.device != .computer || (body.clientId?.isEmpty == false) else {
                return .badRequest(.text("clientId is required to cast to a computer"))
            }
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
                // Liveness is only refreshed for a report from the tab that actually owns
                // casting. It used to be refreshed for *any* report, before the validity
                // check — so a stale tab (or anything else on the network) could pin
                // playback on "computer" with no browser producing sound, and the fallback
                // to the phone could never fire. The phone stayed silent indefinitely.
                if body.clientId == nil || body.clientId == self.castClientId {
                    self.lastComputerReportAt = Date()
                }
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
            let query = Self.queryValue(request, "q")
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
            let videoId = Self.queryValue(request, "videoId")
            guard !videoId.isEmpty else {
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
            nextStreamUrl: player.activeDevice == .computer ? player.upNextStream?.url : nil,
            serverInstanceId: instanceId,
            librarySignature: Self.librarySignature()
        )
    }

    /// Cheap fingerprint of the library's shape. Deliberately only ids and counts — the
    /// point is to tell the remote *that* something changed, not to ship the contents on
    /// every broadcast.
    @MainActor
    private static func librarySignature() -> Int {
        var hasher = Hasher()
        hasher.combine(RadioHistoryStore.shared.stations.map(\.seedTrack.videoId))
        hasher.combine(PlaylistStore.shared.playlists.map { "\($0.id)-\($0.tracks.count)" })
        hasher.combine(DownloadManager.shared.downloadedTracks.count)
        return hasher.finalize()
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
        // This timer is supposed to fire every second. Even a couple of seconds of drift
        // means the run loop was held up, which is exactly when these checks misfire.
        if gap > 2 { lastIrregularTickAt = Date() }
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
            // Was missed here (only the `disconnected` handler cleaned it up). The key
            // retains the WebSocketSession, which retains the Socket whose deinit is what
            // closes the file descriptor — so every laptop sleep, closed tab or Wi-Fi drop
            // over the app's lifetime leaked one fd, permanently.
            socketClientIds.removeValue(forKey: session)
            writeQueues.removeValue(forKey: session)
            // Actually close it. Dropping our references frees nothing — Swifter's
            // connection thread holds its own strong reference while parked in a blocking
            // read, so the file descriptor and the thread both stay put, and the browser
            // never sees a close so never reconnects. Combined with the "already
            // disconnected" guard in the text handler, that left the tab permanently
            // orphaned: still connected, never broadcast to, no live radio updates and no
            // relayed lock-screen commands until a manual reload.
            session.socket.close()
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
        // Don't judge the browser on measurements taken across a stall of our own.
        if let lastIrregularTickAt, Date().timeIntervalSince(lastIrregularTickAt) < tickSettlingPeriod {
            castClientMissingSince = nil
            return
        }
        // Silence while playback is supposed to be running is conclusive on its own — the
        // timeout is already a generous window, so no further grace is added on top; the
        // grace period exists for the socket check, whose "gone" can mean a reconnect
        // that's a second away from completing.
        guard computerIsReportingPlayback else {
            fallBackToPhone()
            return
        }
        // The socket being gone is, on its own, no more trustworthy than reports being
        // stale: locking the phone can drop the connection for a moment while the browser
        // carries on playing perfectly well, and reacting to that produced the same jump
        // to the phone and back. Both signals have to agree the browser is gone.
        guard !castClientIsConnected, !browserIsStillReporting else {
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
        // Not `setActiveDevice(.iphone)`: this is the phone guessing the browser is gone,
        // and it must come back silent rather than start playing on its own.
        PlayerService.shared.fallBackToPhone()
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
        guard Date().timeIntervalSince(lastComputerReportAt) >= computerReportTimeout else { return true }
        // Progress reports have stopped — but that alone was too eager. Locking the phone
        // interrupts its own networking for a moment, and taking playback back on the
        // strength of that produced a very visible switch to the phone and straight back
        // to the computer. A tab whose heartbeat is still arriving is demonstrably alive
        // and still has the audio; only when that stops too is it really gone.
        return castClientHeartbeatAge < castHeartbeatTimeout
    }

    /// Whether progress reports are still arriving. HTTP can keep working while a
    /// WebSocket is down (and reconnecting), so this is the independent second opinion on
    /// whether the browser is still there.
    private var browserIsStillReporting: Bool {
        guard let lastComputerReportAt else { return false }
        return Date().timeIntervalSince(lastComputerReportAt) < computerReportTimeout
    }

    private var castClientHeartbeatAge: TimeInterval {
        guard let castClientId,
              let session = sockets.first(where: { socketClientIds[$0] == castClientId }),
              let seen = socketLastSeen[session] else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince(seen)
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

    /// Socket writes happen here, never on the main actor.
    ///
    /// `writeText` ends in a blocking `write(2)` loop on a blocking socket. When a peer
    /// stops reading — a laptop suspending with a full TCP receive window, Wi-Fi
    /// degrading — the kernel send buffer fills and that write blocks *indefinitely*. On
    /// the main thread (this is called from a 1 Hz timer and synchronously from
    /// `PlayerService.togglePlayPause`) that froze the UI, wedged every HTTP handler
    /// waiting on `DispatchQueue.main.sync`, and ended in a watchdog kill. A full snapshot
    /// with a 100-track queue is ~100 KB, which is more than enough to fill a socket
    /// buffer nobody is draining.
    /// One queue per socket, not one shared serial queue.
    ///
    /// `writeText` ends in a blocking write with no timeout, so a single peer that stops
    /// draining its socket — a laptop sleeping mid-cast, a backgrounded tab with a full
    /// receive window — blocked the shared queue and stopped state, radio and relayed
    /// transport commands reaching *every other* browser. Per-socket queues confine the
    /// damage to the peer causing it.
    private var writeQueues: [WebSocketSession: DispatchQueue] = [:]

    private func writeQueue(for session: WebSocketSession) -> DispatchQueue {
        if let existing = writeQueues[session] { return existing }
        let queue = DispatchQueue(label: "com.vvdemus.control.write.\(ObjectIdentifier(session).hashValue)")
        writeQueues[session] = queue
        return queue
    }

    private func broadcast<T: Encodable>(_ value: T) {
        guard !sockets.isEmpty,
              let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return }
        for socket in sockets {
            writeQueue(for: socket).async { socket.writeText(text) }
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

    /// Reads a query parameter, undoing Swifter's mangling of it.
    ///
    /// Swifter percent-encodes the whole request path *again* before handing it to
    /// `URLComponents`, so an already-encoded `%20` becomes `%2520` and parses back out as
    /// the literal text "%20". Search terms therefore reached YouTube as one run-together
    /// token — "beauty%20and%20a%20beat" — which is why multi-word searches for well-known
    /// songs returned unrelated tracks while single distinctive words seemed fine, and why
    /// adding the artist's name appeared to "fix" it (a longer query still matched
    /// something by luck).
    private static func queryValue(_ request: HttpRequest, _ name: String) -> String {
        guard let raw = request.queryParams.first(where: { $0.0 == name })?.1 else { return "" }
        return raw.removingPercentEncoding ?? raw
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
    private nonisolated func awaitAsync<T>(_ operation: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
        // `nonisolated` matters: this type is @MainActor, so without it the Task below
        // inherits main-actor isolation and the whole search/recommendation pipeline —
        // network continuations, JSON decoding, building 50-track mixes — runs on the main
        // thread while a Swifter worker blocks on the semaphore. That is what made
        // /api/state and /api/toggle miss the browser's deadline on a phone that was fine.
        precondition(!Thread.isMainThread, "awaitAsync would deadlock on the main thread")
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
