import Foundation
import Swifter
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
    /// Ceiling on the hand-queued track list. It is re-encoded into the state broadcast
    /// whenever it changes, so an unbounded one is an unbounded payload pushed to every
    /// connected socket. Far more than anyone queues by hand; low enough that a script
    /// hammering `/api/queue/add` can't grow that payload without limit.
    static let maximumManualQueueTracks = 500
    /// New on every launch — see `StateSnapshot.serverInstanceId`.
    private let instanceId = UUID().uuidString

    private let server = HttpServer()
    /// Swifter only fires its `disconnected` callback once a *blocking* per-connection
    /// socket read throws — which may never happen if a browser tab is killed, a laptop
    /// sleeps, or WiFi drops without a clean TCP close. Left unchecked, this (and the
    /// blocked read thread behind each stale entry) accumulates for the life of the app.
    /// The web client pings every 15s (see app.js); anything silent for longer than
    /// `socketStaleTimeout` gets dropped here instead of being broadcast to forever.
    private let sockets = WebSocketRegistry()
    private let socketStaleTimeout: TimeInterval = 45
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
    static let computerFallbackGrace: TimeInterval = 6
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
    static let computerReportTimeout: TimeInterval = 8
    /// The same window, but for a cast the phone believes is *paused*.
    ///
    /// The browser only POSTs `/api/playback/report` from the audio element's `timeupdate`
    /// event, which does not fire while paused. So within `computerReportTimeout` of a
    /// pause the HTTP signal reads as dead and stays dead, and the "both signals must
    /// agree" protection below collapsed into "is the WebSocket up?". The client backs its
    /// reconnect off to as much as 30s between attempts (see app.js), so any drop that
    /// outlasted `computerFallbackGrace` — a laptop sleeping, Wi-Fi roaming, a backgrounded
    /// tab whose timers are throttled below the heartbeat interval — silently revoked the
    /// cast. The user came back to "Playing on iPhone" and the next play came out of the
    /// phone in their bag.
    ///
    /// Comfortably more than the client's maximum reconnect backoff, so a tab that is only
    /// slow to come back always wins. Nothing is playing, so waiting costs nothing audible,
    /// and it does not weaken the case the fallback exists for: the moment anything
    /// actually plays, a genuinely absent browser is caught by `computerReportTimeout`
    /// instead.
    static let pausedCastLivenessWindow: TimeInterval = 90
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
    static let castHeartbeatTimeout: TimeInterval = 20
    private var broadcastTimer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Injected so the expiration bookkeeping can be tested: the simulator hands out real
    /// identifiers but will not expire one on demand, which is the only moment the bug this
    /// replaces (ending whichever id happened to be current, rather than its own) could
    /// show itself.
    var backgroundTasks: BackgroundTaskVending = UIApplication.shared
    /// Resolves a replacement URL for a stream the casting browser reports as dead.
    ///
    /// The cached URL is dropped first. Without that the "fresh" resolve hands back the very
    /// URL the browser just failed on: `APIClient` caches until a URL's stated expiry, and a
    /// URL that 403s early still looks unexpired on paper.
    nonisolated let freshStreamUrl = UpstreamCall<String, String> { videoId in
        APIClient.shared.invalidateStream(videoId: videoId)
        return try await APIClient.shared.stream(videoId: videoId).url
    }
    /// Resolves a URL for a track the casting browser is banking ahead of time.
    ///
    /// Deliberately not `freshStreamUrl`: that one drops the cached URL first, which is
    /// right when the browser has just told us the URL is dead and wrong here, where the
    /// whole point is to hand back whatever the phone has already resolved.
    nonisolated let upcomingStreamUrl = UpstreamCall<String, String> { videoId in
        try await APIClient.shared.stream(videoId: videoId).url
    }
    /// How far down the queue `/api/stream` will pre-resolve.
    ///
    /// Each one is an InnerTube `player` round trip the phone would otherwise make later,
    /// so this is bounded rather than "the whole queue": four tracks is roughly a quarter of
    /// an hour of playback to coast on, and skipping past a pre-resolved track wastes at
    /// most four calls. `APIClient` caches by video id, so the phone reaching one of these
    /// tracks later costs nothing.
    static let maximumPrefetchDepth = 4

    /// Whether a track is close enough to the front of the queue to be worth pre-resolving.
    /// Pure, so the bound can be tested without a player or a network.
    nonisolated static func isPrefetchable(_ videoId: String, upcoming: [String], depth: Int) -> Bool {
        upcoming.prefix(depth).contains(videoId)
    }
    /// A radio's mix, for the two routes that serve one.
    nonisolated let radioMix = UpstreamCall<String, [Track]> { videoId in
        try await APIClient.shared.radio(videoId: videoId, limit: 50)
    }
    /// The port the request guards compare against.
    ///
    /// The guards run on Swifter's connection threads and are installed exactly once (see
    /// `init`), so they cannot close over the main-actor `port` property — this box is how
    /// `start()` publishes the port they should enforce.
    private let guardPort = LockedValue<UInt16>(51825)
    /// How many times routes have been handed to Swifter's router. Observable so a test can
    /// prove it stays at one across stop/start cycles; see `init`.
    private(set) var routeRegistrations = 0

    private init() {
        // Once, in init, rather than on every `start()`.
        //
        // `HttpRouter.register` mutates its node tree with no synchronization at all, while
        // `HttpRouter.route` reads it under a serial queue — so re-registering while a
        // connection thread was dispatching a request was a Dictionary being mutated during
        // a read. Toggling Connect off and on with a tab open (which the tab's own retries
        // make likely, since it keeps issuing requests throughout) could corrupt the tree or
        // crash outright. `server.middleware` is a plain array read on those same threads and
        // was replaced on every start for the same reason.
        //
        // Neither has to be re-done: `stop()` only stops the accept loop, it does not discard
        // the router, and every handler captures `self` weakly rather than any per-run state.
        registerRoutes()
        installGuards()
    }

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
        backgroundTask = beginBackgroundTask()
    }

    /// Starts a fresh background window. Used when the keep-alive audio is deliberately
    /// given up while backgrounded, so the server isn't left with whatever remained of the
    /// original grace period.
    func renewBackgroundTask() {
        guard isRunning else { return }
        let previous = backgroundTask
        backgroundTask = beginBackgroundTask()
        if previous != .invalid { backgroundTasks.endBackgroundTask(previous) }
    }

    /// Begins one background task whose expiration handler ends *that* task.
    ///
    /// The handlers used to read `self.backgroundTask` instead. `renewBackgroundTask`
    /// replaces that property between beginning a task and the previous one expiring, so an
    /// old task expiring after a renewal ended the brand-new identifier — the one actually
    /// holding the app alive — and left the expired one un-ended for the watchdog to kill
    /// the process over. Capturing the identifier makes each handler responsible only for
    /// its own task.
    private func beginBackgroundTask() -> UIBackgroundTaskIdentifier {
        // A box rather than a local `var`: the expiration handler is `@Sendable` and so
        // cannot capture a mutable local, but it has to see the identifier that
        // `beginBackgroundTask` has not returned yet at the point the closure is written.
        let own = LockedValue<UIBackgroundTaskIdentifier>(.invalid)
        own.value = backgroundTasks.beginBackgroundTask(withName: "VVDemusConnect") { [weak self] in
            guard let self else { return }
            self.backgroundTasks.endBackgroundTask(own.value)
            // Only clear the property if this expiring task is still the current one;
            // otherwise a renewal has already moved on and must not be forgotten.
            if self.backgroundTask == own.value { self.backgroundTask = .invalid }
        }
        return own.value
    }

    func applicationWillEnterForeground() {
        guard backgroundTask != .invalid else { return }
        backgroundTasks.endBackgroundTask(backgroundTask)
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
        let guardPort = self.guardPort
        server.middleware = [
            { request in
                let port = guardPort.value
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
        // Routes and guards are installed once, in `init`; only the port the guards enforce
        // can still change between runs.
        guardPort.value = port
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
        castClientId = nil
        castClientMissingSince = nil
        lastComputerReportAt = nil
        lastSeenTrackLoadEpoch = nil
        lastBroadcastTickAt = nil
        lastStreamRefreshAt = nil
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
        routeRegistrations += 1
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
                    // entries for a socket that was no longer registered — where the
                    // pruner could never see it again, so it leaked for good. Only a
                    // session that is still connected may refresh anything.
                    guard self.sockets.contains(session) else { return }
                    self.sockets.touch(session, at: Date())
                    if let id = Self.clientId(fromFrame: text) {
                        self.sockets.setClientId(id, for: session)
                    }
                }
            },
            pong: { [weak self] session, _ in
                // The reply to `pingIdleSockets`, and the only liveness signal that does not
                // depend on the browser running any JavaScript.
                //
                // The client's own `hello:` heartbeat is a `setInterval`, and browsers
                // throttle timers in a hidden tab to roughly once a minute — well past both
                // `socketStaleTimeout` and the accepted socket's 60s read deadline. So a
                // remote left in a background tab had its connection torn down for no reason
                // but being in the background, and reconnected on a backoff running on those
                // same throttled timers. A pong is answered by the browser's networking
                // stack, so it arrives on time whatever the tab is doing.
                Task { @MainActor in
                    guard let self, self.sockets.contains(session) else { return }
                    self.sockets.touch(session, at: Date())
                }
            },
            connected: { [weak self] session in
                Task { @MainActor in
                    self?.sockets.insert(session, at: Date())
                    self?.needsFullBroadcast = true
                }
            },
            disconnected: { [weak self] session in
                Task { @MainActor in
                    self?.sockets.remove(session)
                }
            }
        )

        server.GET["/api/state"] = { [weak self] request in
            guard let self else { return .internalServerError }
            // Swifter lowercases header names as it parses them.
            let clientId = Self.clientId(
                queryValue: Self.queryValue(request, "clientId"),
                header: request.headers["x-vvdemus-client-id"]
            )
            return self.jsonResponse(self.onMain {
                self.noteClientPolled(clientId)
                return self.stateSnapshot()
            })
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
        // The casting browser's `<audio>` element could not load the URL we gave it —
        // almost always an expired googlevideo URL, which is routine for a track started
        // from a queue built an hour ago. Until this existed the phone was never told, so
        // it kept serving the identical dead URL in every snapshot and the browser retried
        // it every five seconds indefinitely: the music simply never came back.
        server.POST["/api/playback/stream-failed"] = { [weak self] request in
            guard let self, let body: StreamFailedBody = self.decodeBody(request) else {
                return .badRequest(.text("bad body"))
            }
            // Re-resolving costs a YouTube round trip, so it is gated on this being the tab
            // that owns casting, reporting the track it is actually meant to be playing, and
            // not having just asked. `clientId` is optional for the same reason it is on
            // `/api/playback/report` — non-browser clients send none — but a caller that
            // does send one must be the cast tab. Checking and claiming happen in the same
            // main-actor hop, so a browser retrying every five seconds can only ever have
            // one re-resolve in flight.
            let permitted = self.onMain { () -> Bool in
                let now = Date()
                guard PlayerService.shared.activeDevice == .computer,
                      body.clientId == nil || body.clientId == self.castClientId,
                      PlayerService.shared.currentTrack?.videoId == body.videoId else { return false }
                if let last = self.lastStreamRefreshAt, now.timeIntervalSince(last) < Self.streamRefreshDebounce {
                    return false
                }
                // Stamped even for a resolve that goes on to fail: a URL that can't be
                // re-resolved won't start working if it's asked for twice as often.
                self.lastStreamRefreshAt = now
                return true
            }
            guard permitted else {
                // 409, not 404: the route exists, this just isn't what is playing (or the
                // last re-resolve was moments ago). The browser should re-read the snapshot
                // rather than treat it as a bug in its own request.
                return .raw(409, "Conflict", ["Content-Type": "text/plain"], { try $0.write(Data("not the current cast stream".utf8)) })
            }
            // Re-resolved by `PlayerService` itself, into its own `externalStream`.
            //
            // This used to resolve the URL here and hold it in a `reresolvedStream`
            // property that the snapshot preferred over the player's — a workaround for
            // `PlayerService` having no way to refresh the current track's stream in
            // place. It does now, so there is one source of truth again: two mechanisms
            // both claiming to say what the browser should load is precisely how the two
            // drift apart later.
            // Deliberately NOT `PlayerService.refreshExternalStream`, which resolves through
            // the player's own network path. Calling it from here bypasses `freshStreamUrl`
            // — the seam that exists so this route can be tested without a YouTube round
            // trip — and every test of this endpoint started failing with a 500. Resolve
            // through the seam here; let the player publish the result.
            switch self.awaitAsync({ [freshStreamUrl = self.freshStreamUrl] in try await freshStreamUrl(body.videoId) }) {
            case .success(let url):
                let published = self.onMain {
                    PlayerService.shared.adoptRefreshedExternalStream(videoId: body.videoId, url: url)
                }
                // Dropped rather than applied if the track moved on while this was in
                // flight; the new track resolves its own URL.
                guard published == true else {
                    return .raw(409, "Conflict", ["Content-Type": "text/plain"],
                                { try $0.write(Data("track changed while re-resolving".utf8)) })
                }
                // The fresh URL is in the reply as well as in the next snapshot, so the tab
                // that asked can reload straight away instead of waiting for the 1 Hz tick.
                return self.jsonResponse(StreamFailedResponse(videoId: body.videoId, streamUrl: url))
            case .failure:
                return .internalServerError
            }
        }
        // Lets the casting browser bank stream URLs for tracks that are coming up, so it can
        // keep playing through an outage rather than for exactly one more track.
        //
        // The snapshot's `nextStreamUrl` covers a single transition. That is the right
        // design for a blip, but a phone that sleeps, loses Wi-Fi or gets suspended by iOS
        // is away for minutes, and the browser would go quiet at the end of the following
        // track with a full queue on screen and no way to reach any of it. Everything it
        // needs is a URL it could have been given while the phone was still there.
        server.GET["/api/stream"] = { [weak self] request in
            guard let self else { return .internalServerError }
            let videoId = Self.queryValue(request, "videoId")
            guard !videoId.isEmpty else { return .badRequest(.text("missing videoId")) }
            let clientId = Self.clientId(
                queryValue: Self.queryValue(request, "clientId"),
                header: request.headers["x-vvdemus-client-id"]
            )

            // Decided in one main-actor hop so the queue can't move underneath the check.
            enum Resolution {
                case refused
                /// Already on the phone's disk; no round trip needed, and the browser can't
                /// reach a file:// URL anyway.
                case local(String)
                case upstream
            }
            let resolution = self.onMain { () -> Resolution in
                // Gated exactly like `/api/playback/stream-failed`: this costs a YouTube
                // round trip, so it is for the tab that owns casting and for tracks that are
                // actually about to play — not a general-purpose resolver for anything on
                // the network to point at any video id.
                guard PlayerService.shared.activeDevice == .computer,
                      clientId == nil || clientId == self.castClientId else { return .refused }
                let upcoming = (PlayerService.shared.manualQueue + PlayerService.shared.contextQueue)
                    .map(\.videoId)
                guard Self.isPrefetchable(videoId, upcoming: upcoming, depth: Self.maximumPrefetchDepth) else {
                    return .refused
                }
                self.noteClientPolled(clientId)
                if DownloadManager.shared.localFileURL(forVideoId: videoId) != nil {
                    return .local("/api/audio/local/\(videoId)")
                }
                return .upstream
            }

            switch resolution {
            case .refused:
                // 409 rather than 404 for the same reason `/api/playback/stream-failed` uses
                // it: the route is fine, this just isn't a track the browser has any
                // business pre-resolving right now. It should re-read the snapshot.
                return .raw(409, "Conflict", ["Content-Type": "text/plain"],
                            { try $0.write(Data("not an upcoming cast track".utf8)) })
            case .local(let url):
                return self.jsonResponse(ResolvedStreamResponse(videoId: videoId, streamUrl: url))
            case .upstream:
                // Through the same seam `freshStreamUrl` uses, and deliberately *without*
                // invalidating the cache first: the point is to reuse a URL the phone has
                // already resolved, and the phone will want the same one when the track
                // reaches the front of the queue.
                switch self.awaitAsync({ [upcomingStreamUrl = self.upcomingStreamUrl] in
                    try await upcomingStreamUrl(videoId)
                }) {
                case .success(let url):
                    return self.jsonResponse(ResolvedStreamResponse(videoId: videoId, streamUrl: url))
                case .failure:
                    return .internalServerError
                }
            }
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

        // Both queue-growing routes are bounded, and the check runs inside the same main-actor
        // hop as the mutation so two concurrent adds can't both see room for the last slot.
        // Only `/api/play` was bounded before; adds were unlimited, so repeated calls grew
        // `manualQueue` without end and every added track was re-encoded into the broadcast
        // once a second, forever. Bounding `add` alone would have been decoration —
        // `play-next` grows the same list.
        server.POST["/api/queue/add"] = { [weak self] request in
            guard let self, let body: TrackOnlyBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
            let accepted = self.onMain { () -> Bool in
                guard PlayerService.shared.manualQueue.count < Self.maximumManualQueueTracks else { return false }
                PlayerService.shared.addToQueue(body.track)
                return true
            }
            return accepted ? .ok(.text("ok")) : .badRequest(.text("queue is full"))
        }
        server.POST["/api/queue/play-next"] = { [weak self] request in
            guard let self, let body: TrackOnlyBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
            let accepted = self.onMain { () -> Bool in
                guard PlayerService.shared.manualQueue.count < Self.maximumManualQueueTracks else { return false }
                PlayerService.shared.playNext(body.track)
                return true
            }
            return accepted ? .ok(.text("ok")) : .badRequest(.text("queue is full"))
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
            switch self.awaitAsync({ [radioMix = self.radioMix] in try await radioMix(videoId) }) {
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
            switch self.awaitAsync({ [radioMix = self.radioMix] in try await radioMix(body.videoId) }) {
            case .success(let tracks):
                // Storing pushes onUpdate → broadcastRadioUpdate, which is what actually
                // syncs this to the phone (and any other open browser) live.
                //
                // The reply is whatever the store now holds, not what came back: `store`
                // deliberately refuses an empty mix (YouTube's radio endpoint returns one
                // often enough), so answering with `tracks` told the browser to render
                // "Nothing here yet." over a perfectly good station the phone still had —
                // a refresh that changed nothing anywhere looked like it had wiped the list.
                let stored = self.onMain {
                    RadioCacheStore.shared.store(tracks, for: body.videoId)
                    return RadioCacheStore.shared.tracks(for: body.videoId)
                }
                return self.jsonResponse(stored ?? tracks)
            case .failure: return .internalServerError
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
            // `maximumPlaylistNameLength` was declared and then never enforced, so a name of
            // any size at all was persisted and re-rendered in the sidebar of every
            // connected browser. Counted in Characters, so a name is limited by what it
            // looks like rather than by how many bytes its emoji happen to take.
            guard trimmed.count <= Self.maximumPlaylistNameLength else {
                return .badRequest(.text("name too long"))
            }
            self.onMain { PlaylistStore.shared.create(name: trimmed) }
            return .ok(.text("ok"))
        }
        server.POST["/api/library/playlists/:id/add"] = { [weak self] request in
            guard let self,
                  // Only `":id"`. The `?? request.params["id"]` fallback that used to be here
                  // was unreachable: Swifter keys a variable path node by the literal text of
                  // the segment, colon included.
                  let idString = request.params[":id"],
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

    /// A URL re-resolved by `/api/playback/stream-failed`, preferred over PlayerService's
    /// own for as long as it describes the current track.
    ///
    /// It has to live here because PlayerService offers no way to re-resolve the *current*
    /// track's stream in place: `setActiveDevice` returns immediately when the device is
    /// unchanged, and `adoptExternalPlayback` returns immediately for the track already
    /// playing. Its `externalStream` therefore still holds the URL the browser just failed
    /// on, and serving that again is exactly the loop this endpoint exists to break.
    /// When the last re-resolve was accepted, so a browser retrying every five seconds
    /// can't turn into a YouTube round trip every five seconds.
    private var lastStreamRefreshAt: Date?
    private static let streamRefreshDebounce: TimeInterval = 10

    /// What the casting browser should load.
    ///
    /// Straight from the player now. There used to be a `reresolvedStream` override held
    /// here, because `PlayerService` had no way to refresh the current track's stream in
    /// place — so this had to prefer a locally-cached fresh URL over the player's stale
    /// one, and remember to drop it whenever the track or device changed. All of that is
    /// gone: `refreshExternalStream` updates the player directly, and the snapshot reads
    /// the one value everything else reads.
    private func currentExternalStream() -> PlayerService.ExternalStream? {
        PlayerService.shared.externalStream
    }

    private func stateSnapshot() -> StateSnapshot {
        let player = PlayerService.shared
        let external = currentExternalStream()
        return StateSnapshot(
            isPlaying: player.isPlaying,
            isLoading: player.isLoading,
            progress: player.progress,
            duration: player.duration,
            isShuffling: player.isShuffling,
            queueContextTitle: player.queueContextTitle,
            currentTrack: player.currentTrack,
            manualQueue: player.manualQueue,
            contextQueue: player.contextQueue,
            likedVideoIds: LikedSongsStore.shared.tracks.map(\.videoId),
            activeDevice: player.activeDevice,
            streamUrl: external?.url,
            streamVideoId: external?.videoId,
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

    /// How long a socket may be silent before it is probed with a ping.
    ///
    /// Comfortably inside `socketStaleTimeout` so a live-but-quiet tab is always asked
    /// before it is judged, and inside the accepted socket's own read deadline
    /// (`Socket.receiveTimeout`) so the connection thread never times out on a peer that is
    /// perfectly well.
    static let socketPingIdleInterval: TimeInterval = 10

    /// Probes sockets we haven't heard from lately. See the `pong` handler for why this
    /// exists rather than relying on the client's heartbeat.
    private func pingIdleSockets() {
        for (session, queue) in sockets.sessionsNeedingPing(now: Date(), idle: Self.socketPingIdleInterval) {
            // On the socket's own queue, like every other write: `writeFrame` ends in a
            // blocking `write(2)`, and a peer that has stopped reading would otherwise
            // block the main thread here.
            queue.async { session.writeFrame(ArraySlice<UInt8>(), .ping) }
        }
    }

    private func broadcastState() {
        forgiveSuspensionGap()
        pingIdleSockets()
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
        sockets.touchAll(at: Date())
    }

    private func pruneStaleSockets() {
        let now = Date()
        for session in sockets.staleSessions(before: now.addingTimeInterval(-socketStaleTimeout)) {
            // One removal drops the last-seen time, the client id and the write queue with
            // it. They were four parallel collections, so forgetting any one of them here
            // leaked an entry — and the `WebSocketSession` (and file descriptor) it
            // retained — on every laptop sleep, closed tab or Wi-Fi drop.
            sockets.remove(session)
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
        if let lastIrregularTickAt, now.timeIntervalSince(lastIrregularTickAt) < tickSettlingPeriod {
            castClientMissingSince = nil
            return
        }
        switch Self.castLiveness(livenessInput(now: now)) {
        case .present:
            castClientMissingSince = nil
        case .missing:
            castClientMissingSince = castClientMissingSince ?? now
        case .gone:
            fallBackToPhone()
        }
    }

    private func livenessInput(now: Date) -> CastLivenessInput {
        CastLivenessInput(
            isPlaying: PlayerService.shared.isPlaying,
            sinceReport: lastComputerReportAt.map { now.timeIntervalSince($0) },
            heartbeatAge: castClientId.map { sockets.heartbeatAge(clientId: $0, now: now) } ?? .infinity,
            socketConnected: castClientId.map { sockets.hasSession(clientId: $0) } ?? false,
            missingFor: castClientMissingSince.map { now.timeIntervalSince($0) }
        )
    }

    /// Everything the "has the casting browser gone away?" decision depends on, measured at
    /// one instant. Sampled into a value so the decision can be a pure function: driving it
    /// through the 1 Hz timer would mean sleeping through real minutes to reach the cases
    /// that actually matter.
    struct CastLivenessInput: Equatable {
        /// Whether the phone believes audio is currently coming out somewhere.
        var isPlaying: Bool
        /// Seconds since the cast tab last said where playback had got to; nil if it never
        /// has (which is also the state right after a device switch resets the clock).
        var sinceReport: TimeInterval?
        /// Seconds since a frame last arrived on the cast tab's WebSocket; `.infinity` when
        /// it has no socket registered at all.
        var heartbeatAge: TimeInterval
        /// Whether a socket attributed to the cast tab is registered right now.
        var socketConnected: Bool
        /// How long the cast tab has already been counted as missing; nil if it isn't.
        var missingFor: TimeInterval?
    }

    enum CastLivenessDecision: Equatable {
        /// Demonstrably still there.
        case present
        /// Nothing has been heard; keep counting, but don't act yet.
        case missing
        /// Hand playback back to the phone.
        case gone
    }

    /// `nonisolated` because it is pure: nothing here reads the server's state, which is
    /// what makes it testable without a clock or a running server.
    nonisolated static func castLiveness(_ input: CastLivenessInput) -> CastLivenessDecision {
        // Silence while playback is supposed to be running is conclusive on its own — the
        // timeout is already a generous window, so no further grace is added on top; the
        // grace period below exists for the socket check, whose "gone" can mean a reconnect
        // that's a second away from completing. A heartbeat still arriving means the tab is
        // demonstrably alive and still holding the audio, which is why the phone briefly
        // losing its own networking (locking the screen does it) doesn't count.
        if input.isPlaying,
           let sinceReport = input.sinceReport,
           sinceReport >= computerReportTimeout,
           input.heartbeatAge >= castHeartbeatTimeout {
            return .gone
        }
        // Both signals have to agree the tab is gone. The socket dropping is, on its own, no
        // more trustworthy than reports going quiet.
        //
        // How long "quiet" has to last depends on whether anything is playing, because that
        // is what decides whether the HTTP signal exists at all: reports come from the audio
        // element's `timeupdate`, which does not fire while paused. Judging a paused cast on
        // the 8s playing window meant its HTTP signal was always dead and the socket alone
        // decided — see `pausedCastLivenessWindow`.
        let livenessWindow = input.isPlaying ? computerReportTimeout : pausedCastLivenessWindow
        let heardRecently = (input.sinceReport ?? .infinity) < livenessWindow
        if input.socketConnected || heardRecently { return .present }
        if let missingFor = input.missingFor, missingFor >= computerFallbackGrace { return .gone }
        return .missing
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

    /// The tab id carried by an ordinary HTTP request, from either place app.js puts it.
    ///
    /// It sends both — a query parameter and a header — so the server can read whichever it
    /// prefers. It used to read neither, which quietly cost the paused cast its only HTTP
    /// liveness signal: see `noteClientPolled`.
    ///
    /// Takes the two strings rather than the request so it stays a pure function of them,
    /// testable without standing a server up — the same reason `isAllowedOrigin` does.
    nonisolated static func clientId(queryValue: String?, header: String?) -> String? {
        for candidate in [queryValue, header] {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Records that the casting tab asked for state, which is proof it is still there.
    ///
    /// The browser only POSTs `/api/playback/report` from the audio element's `timeupdate`,
    /// which does not fire while paused — so a paused cast's HTTP signal went dead a few
    /// seconds after the pause and stayed dead, leaving `castLiveness` to decide on the
    /// socket alone. app.js has always tagged its 5s poll with the tab id precisely so this
    /// could not happen; nothing here read the tag.
    ///
    /// Only the tab that owns casting counts. Refreshing the clock for any caller is how a
    /// stale tab (or anything else on the network) could pin playback on a computer that
    /// wasn't producing sound — the same reason `/api/playback/report` checks the id.
    private func noteClientPolled(_ clientId: String?) {
        guard let clientId, clientId == castClientId else { return }
        lastComputerReportAt = Date()
    }

    /// When the casting tab was last heard from over HTTP. Exposed so a test can assert
    /// that a poll carrying the tab id counts as evidence — the whole point of
    /// `noteClientPolled`, and unobservable otherwise without sleeping through the
    /// ninety-second paused window.
    var lastComputerReportAtForTesting: Date? { lastComputerReportAt }

    /// Puts the server back to "nothing has been heard from the browser", which is what a
    /// paused cast looks like a few seconds after the pause.
    func forgetComputerReportsForTesting() {
        lastComputerReportAt = nil
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

    /// Socket writes happen off the main actor, on a queue of the socket's own.
    ///
    /// `writeText` ends in a blocking `write(2)` loop on a blocking socket. When a peer
    /// stops reading — a laptop suspending with a full TCP receive window, Wi-Fi
    /// degrading — the kernel send buffer fills and that write blocks *indefinitely*. On
    /// the main thread (this is called from a 1 Hz timer and synchronously from
    /// `PlayerService.togglePlayPause`) that froze the UI, wedged every HTTP handler
    /// waiting on `DispatchQueue.main.sync`, and ended in a watchdog kill. A full snapshot
    /// with a 100-track queue is ~100 KB, which is more than enough to fill a socket
    /// buffer nobody is draining.
    ///
    /// One queue per socket rather than one shared serial queue, so a single peer that
    /// stops draining can't stop state, radio and relayed transport commands reaching
    /// *every other* browser. See `WebSocketRegistry`, which owns them.
    private func broadcast<T: Encodable>(_ value: T) {
        let targets = sockets.broadcastTargets()
        guard !targets.isEmpty,
              let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return }
        for (session, queue) in targets {
            queue.async { session.writeText(text) }
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

// MARK: - Supporting types

/// Per-tab WebSocket bookkeeping: liveness, which browser tab a socket belongs to, and the
/// queue its writes go out on. Keyed by object identity, deliberately.
///
/// Swifter's `Socket` hashes and compares on `socketFileDescriptor` alone, and
/// `WebSocketSession` forwards both to it — so two entirely different sessions are `==`
/// the moment the kernel hands out the same descriptor number twice, which it does at the
/// first opportunity because `accept` always returns the lowest free number. This used to
/// be four collections keyed on the session itself, and the consequence was a live tab
/// being deregistered by a *stale* callback: the pruner closes sockets deliberately, and a
/// `disconnected` callback arriving for one of those after a new browser had picked up its
/// descriptor removed the new session from all four. That tab stayed open, looked healthy,
/// and was never broadcast to again — and because the text handler only refreshes sessions
/// that are still registered, its own heartbeats could not put it back.
///
/// Identity is safe as a key precisely because the entry holds the session strongly: an
/// `ObjectIdentifier` can only be reused once its object is deallocated, which cannot
/// happen while it is in here.
@MainActor
final class WebSocketRegistry {
    private struct Entry {
        let session: WebSocketSession
        var lastSeen: Date
        var clientId: String?
        let writeQueue: DispatchQueue
        /// When this socket was last sent a ping, so an idle one is probed at a steady
        /// interval rather than once per broadcast tick.
        var lastPingAt: Date?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    func insert(_ session: WebSocketSession, at now: Date) {
        let key = ObjectIdentifier(session)
        if var existing = entries[key] {
            existing.lastSeen = now
            entries[key] = existing
            return
        }
        entries[key] = Entry(
            session: session,
            lastSeen: now,
            clientId: nil,
            writeQueue: DispatchQueue(label: "com.vvdemus.control.write.\(key.hashValue)"),
            lastPingAt: nil
        )
    }

    func remove(_ session: WebSocketSession) {
        entries.removeValue(forKey: ObjectIdentifier(session))
    }

    func removeAll() {
        entries.removeAll()
    }

    func contains(_ session: WebSocketSession) -> Bool {
        entries[ObjectIdentifier(session)] != nil
    }

    /// Records a frame arriving. Ignores a session that isn't registered, so a callback
    /// that lost the race with `remove` can't resurrect a half-entry the pruner would
    /// never look at again.
    func touch(_ session: WebSocketSession, at now: Date) {
        guard var entry = entries[ObjectIdentifier(session)] else { return }
        entry.lastSeen = now
        entries[ObjectIdentifier(session)] = entry
    }

    func touchAll(at now: Date) {
        for key in entries.keys {
            entries[key]?.lastSeen = now
        }
    }

    func setClientId(_ clientId: String, for session: WebSocketSession) {
        guard var entry = entries[ObjectIdentifier(session)] else { return }
        entry.clientId = clientId
        entries[ObjectIdentifier(session)] = entry
    }

    func clientId(for session: WebSocketSession) -> String? {
        entries[ObjectIdentifier(session)]?.clientId
    }

    func lastSeen(for session: WebSocketSession) -> Date? {
        entries[ObjectIdentifier(session)]?.lastSeen
    }

    func staleSessions(before cutoff: Date) -> [WebSocketSession] {
        entries.values.filter { $0.lastSeen < cutoff }.map(\.session)
    }

    func hasSession(clientId: String) -> Bool {
        entries.values.contains { $0.clientId == clientId }
    }

    /// How long ago the named tab's socket last carried a frame; `.infinity` when it has no
    /// socket registered. A tab that reconnected has more than one entry only for the
    /// moment before the old one is reaped, so the freshest wins.
    func heartbeatAge(clientId: String, now: Date) -> TimeInterval {
        let seen = entries.values.filter { $0.clientId == clientId }.map(\.lastSeen)
        guard let newest = seen.max() else { return .infinity }
        return now.timeIntervalSince(newest)
    }

    func broadcastTargets() -> [(session: WebSocketSession, queue: DispatchQueue)] {
        entries.values.map { ($0.session, $0.writeQueue) }
    }

    /// Sockets that have said nothing for `idle` seconds and haven't been probed in that
    /// long either, stamping each as pinged so the caller doesn't have to.
    ///
    /// The stamp is separate from `lastSeen` on purpose: pinging a socket is not evidence
    /// that anything is on the other end of it, so a peer that has gone away must keep
    /// ageing towards the pruner rather than being kept alive by our own probes.
    func sessionsNeedingPing(now: Date, idle: TimeInterval) -> [(session: WebSocketSession, queue: DispatchQueue)] {
        // Chosen first, stamped second. Mutating `entries` inside a `for … in entries` loop
        // is safe but leaves the dictionary non-uniquely referenced for the whole loop, so
        // every write copies the whole storage.
        let due = entries.filter { _, entry in
            guard now.timeIntervalSince(entry.lastSeen) >= idle else { return false }
            guard let lastPingAt = entry.lastPingAt else { return true }
            return now.timeIntervalSince(lastPingAt) >= idle
        }
        for key in due.keys {
            entries[key]?.lastPingAt = now
        }
        return due.values.map { ($0.session, $0.writeQueue) }
    }
}

/// One upstream (YouTube) call this server makes on the browser's behalf, held behind a
/// swappable reference so the route that uses it can be exercised without the network.
///
/// Deliberately not the app's `StreamResolving`/`RadioFetching` protocols: both are
/// `@MainActor`, so awaiting one from a route handler would put a YouTube round trip on the
/// main thread while the Swifter worker that asked for it blocks on a semaphore — precisely
/// what `awaitAsync` is `nonisolated` to avoid. Lock-guarded because handlers read it from
/// those worker threads.
final class UpstreamCall<Input, Output>: @unchecked Sendable {
    typealias Perform = @Sendable (Input) async throws -> Output

    private let lock = NSLock()
    private var perform: Perform
    private let original: Perform

    init(_ perform: @escaping Perform) {
        self.perform = perform
        self.original = perform
    }

    func replace(with perform: @escaping Perform) {
        lock.lock()
        self.perform = perform
        lock.unlock()
    }

    /// Puts the real network call back — what a test's `tearDown` uses, so a swapped stub
    /// can't leak into the rest of the suite.
    func restoreDefault() {
        replace(with: original)
    }

    func callAsFunction(_ input: Input) async throws -> Output {
        // The lock is taken and released inside a non-async accessor: holding one across an
        // `await` is unsound, and doing it in an async function is an error under Swift 6.
        try await current()(input)
    }

    private func current() -> Perform {
        lock.lock()
        defer { lock.unlock() }
        return perform
    }
}

/// The slice of `UIApplication`'s background-task API this server uses, so the identifier
/// bookkeeping can be exercised without a real background task — the simulator hands out
/// real identifiers but will not expire one on demand, and expiry is the only moment the
/// wrong-identifier bug could show itself.
@MainActor
protocol BackgroundTaskVending: AnyObject {
    func beginBackgroundTask(
        withName name: String?,
        expirationHandler handler: (@MainActor @Sendable () -> Void)?
    ) -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
}

extension UIApplication: BackgroundTaskVending {}

/// A value read from Swifter's connection threads and written from the main actor.
final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
