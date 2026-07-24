import Foundation
import Swifter
import Network

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
/// same-WiFi-only feature (see Library's Remote Control toggle for the on/off switch).
@MainActor
final class LocalControlServer: ObservableObject {
    static let shared = LocalControlServer()

    @Published private(set) var isRunning = false
    @Published private(set) var localAddress: String?
    let port: UInt16 = 51825

    private let server = HttpServer()
    private var sockets: Set<WebSocketSession> = []
    private var broadcastTimer: Timer?

    private init() {}

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
        } catch {
            isRunning = false
        }
    }

    func stop() {
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        server.stop()
        sockets.removeAll()
        isRunning = false
    }

    // MARK: - Routes

    private func registerRoutes() {
        server["/"] = { [weak self] _ in self?.staticFile("index", "html") ?? .notFound }
        server["/app.js"] = { [weak self] _ in self?.staticFile("app", "js", contentType: "application/javascript") ?? .notFound }
        server["/style.css"] = { [weak self] _ in self?.staticFile("style", "css", contentType: "text/css") ?? .notFound }

        server["/ws"] = websocket(
            text: { _, _ in },
            connected: { [weak self] session in
                Task { @MainActor in self?.sockets.insert(session) }
            },
            disconnected: { [weak self] session in
                Task { @MainActor in self?.sockets.remove(session) }
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

        server.GET["/api/home"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            switch self.awaitAsync({ try await APIClient.shared.home() }) {
            case .success(let tracks): return self.jsonResponse(tracks)
            case .failure: return .internalServerError
            }
        }

        server.GET["/api/radio"] = { [weak self] request in
            guard let self else { return .internalServerError }
            guard let videoId = request.queryParams.first(where: { $0.0 == "videoId" })?.1 else {
                return .badRequest(.text("missing videoId"))
            }
            switch self.awaitAsync({ try await APIClient.shared.radio(videoId: videoId, limit: 50) }) {
            case .success(let tracks): return self.jsonResponse(tracks)
            case .failure: return .internalServerError
            }
        }
        server.POST["/api/radio/play"] = { [weak self] request in
            guard let self, let body: RadioPlayBody = self.decodeBody(request) else { return .badRequest(.text("bad body")) }
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
            likedVideoIds: LikedSongsStore.shared.tracks.map(\.videoId)
        )
    }

    private func broadcastState() {
        guard !sockets.isEmpty else { return }
        let snapshot = stateSnapshot()
        guard let data = try? JSONEncoder().encode(snapshot), let text = String(data: data, encoding: .utf8) else { return }
        for socket in sockets {
            socket.writeText(text)
        }
    }

    // MARK: - Helpers

    private func staticFile(_ name: String, _ ext: String, contentType: String = "text/html") -> HttpResponse {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "WebUI"),
            let data = try? Data(contentsOf: url) else {
            return .notFound
        }
        return .raw(200, "OK", ["Content-Type": contentType], { try $0.write(data) })
    }

    private func decodeBody<T: Decodable>(_ request: HttpRequest) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(request.body))
    }

    private func jsonResponse<T: Encodable>(_ value: T) -> HttpResponse {
        guard let data = try? JSONEncoder().encode(value) else { return .internalServerError }
        return .raw(200, "OK", ["Content-Type": "application/json"], { try $0.write(data) })
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
