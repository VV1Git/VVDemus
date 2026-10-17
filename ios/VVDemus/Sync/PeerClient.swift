import Foundation

enum PeerError: LocalizedError {
    case notPaired
    case unreachable
    case rejected(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notPaired: return "This device isn't paired yet."
        case .unreachable: return "Couldn't reach the other device. Make sure both are on the same WiFi and the app is open."
        case .rejected(let reason): return reason
        case .badResponse: return "The other device sent something unexpected."
        }
    }
}

/// The outbound half of the peer link: pairing, syncing, and handing playback over — each call
/// to one named member of the group.
@MainActor
enum PeerClient {
    /// One session for the life of the process, not one per request.
    ///
    /// It used to be a computed property, so every call built a fresh `URLSession` — and none of
    /// them were ever invalidated. At a 1 Hz poll that is a session, a connection pool and a TCP
    /// handshake per second, none of them reusable, for as long as the app runs. A single session
    /// keeps the connection to the peer alive between polls, which is the whole point of having
    /// one.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // A peer is on the LAN or it isn't. Waiting 60s to discover that leaves the UI claiming
        // to be syncing long after the answer is known.
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    // MARK: - Pairing

    /// Pairs with `peer` using the six digits shown on *its* screen.
    ///
    /// Joins its group, too: the first sync round after this carries its list of devices, and
    /// this device meets each of them from there — see `PairedPeerStore.merge`.
    @discardableResult
    static func pair(with peer: DiscoveredPeer, code: String) async throws -> PairedPeer {
        PairLog.info("pair() starting — peer=\(peer.name) host=\(peer.host):\(peer.port) code=\(code.count) digits")
        guard let base = peer.baseURL else {
            PairLog.error("pair() aborted — could not build a URL for \(peer.host):\(peer.port)")
            throw PeerError.unreachable
        }
        let identity = PeerIdentity.shared
        let request = PairRequest(
            peerId: identity.peerId,
            name: identity.name,
            isDesktop: identity.isDesktop,
            publicKey: identity.publicKey.base64EncodedString(),
            proof: PairingProof.make(
                code: code,
                publicKey: identity.publicKey,
                peerId: identity.peerId,
                responding: false
            )
        )

        let response: PairResponse = try await post(
            to: base.appendingPathComponent("api/pair/begin"),
            body: request,
            for: nil
        )

        PairLog.info("pair() got a response from \(response.name) (peerId \(response.peerId.prefix(8)))")
        guard let peerKey = Data(base64Encoded: response.publicKey) else {
            PairLog.error("pair() failed — the peer's public key was not valid base64")
            throw PeerError.badResponse
        }
        // The reply is checked against the same code. Without this, anything that could answer
        // on that address could complete the pairing — the proof has to run both ways.
        guard PairingProof.verify(
            response.proof,
            code: code,
            publicKey: peerKey,
            peerId: response.peerId,
            responding: true
        ) else {
            PairLog.error("pair() failed — the peer's response proof did not verify against this code")
            throw PeerError.rejected("That code didn't match. Check the digits on your other device.")
        }

        let paired = PairedPeer(
            peerId: response.peerId,
            name: response.name,
            publicKey: peerKey,
            isDesktop: response.isDesktop,
            lastKnownHost: peer.host,
            lastKnownPort: peer.port,
            pairedAt: Date()
        )
        PairedPeerStore.shared.save(paired)
        PairLog.info("pair() succeeded — now paired with \(response.name) at \(peer.host)")
        return paired
    }

    // MARK: - Sync

    /// One round trip with `peer`: send what we have, merge what comes back.
    @discardableResult
    static func sync(with peer: PairedPeer) async throws -> SyncSummary {
        let base = try await resolveBase(for: peer)
        PairLog.info("sync() starting with \(peer.name)")
        let payload = SyncEngine.snapshot(events: .push(to: peer.peerId), for: peer)
        PairLog.info("sync() sending \(payload.likes.count) likes, \(payload.playlists.count) playlists, \(payload.radios.count) radios, \(payload.events.count) events, \(payload.generated.count) caches")
        let reply: SyncPayload = try await post(
            to: base.appendingPathComponent("api/sync"),
            body: payload,
            for: peer
        )
        // The payload names its sender, and it has to be the device that was asked. That is a
        // consistency check, not authentication: nothing about a reply proves who sent it — the
        // device list inside is signed for that (`PairedPeerStore.signature`).
        guard reply.peerId == peer.peerId else {
            PairLog.error("sync() reply claims to come from \(reply.peerId.prefix(8)), not \(peer.name) — ignored")
            throw PeerError.badResponse
        }
        // And it has to still be a member, under the key it was asked with. The round is slow —
        // a member that is away costs it seconds — and the group can change underneath it: a
        // reply that lands after this device left, or after the sender was removed, would
        // otherwise re-introduce everyone it lists.
        guard PairedPeerStore.shared.peer(id: peer.peerId)?.publicKey == peer.publicKey else {
            PairLog.info("sync() reply from \(peer.name) arrived after it left the group — discarded")
            throw PeerError.notPaired
        }
        PairLog.info("sync() received \(reply.likes.count) likes, \(reply.playlists.count) playlists, \(reply.radios.count) radios, \(reply.events.count) events, \(reply.generated.count) caches")
        let summary = SyncEngine.merge(reply, from: peer.peerId)
        PairLog.info("sync() merged — \(summary.description)")
        return summary
    }

    /// Tells `peer` this device is leaving the group, so it can pass that on to everyone else.
    static func leave(_ peer: PairedPeer) async throws {
        let base = try await resolveBase(for: peer)
        let _: EmptyReply = try await post(
            to: base.appendingPathComponent("api/peer/leave"),
            body: EmptyReply(),
            for: peer
        )
    }

    // MARK: - Playback

    /// A peer's live playback, polled by `PeerPlayback` so every device shows one session.
    static func peerState(of peer: PairedPeer) async throws -> StateSnapshot {
        let base = try await resolveBase(for: peer)
        return try await get(base.appendingPathComponent("api/peer/state"), from: peer)
    }

    /// A transport action for `peer`, which should be the device that owns the session.
    static func send(_ command: PeerCommand, to peer: PairedPeer) async throws {
        let base = try await resolveBase(for: peer)
        let _: EmptyReply = try await post(
            to: base.appendingPathComponent("api/peer/command"),
            body: command,
            for: peer
        )
    }

    /// Asks `peer` to download these tracks onto itself.
    static func requestDownloads(_ tracks: [Track], on peer: PairedPeer) async throws {
        let base = try await resolveBase(for: peer)
        let _: EmptyReply = try await post(
            to: base.appendingPathComponent("api/peer/download"),
            body: tracks,
            for: peer
        )
    }

    static func fetchCheckpoint(from peer: PairedPeer) async throws -> NowPlayingCheckpoint {
        let base = try await resolveBase(for: peer)
        return try await get(base.appendingPathComponent("api/peer/checkpoint"), from: peer)
    }

    /// Hands the session over, and reports back whether the other device actually took it.
    ///
    /// The reply matters: the sender only lets go of its queue once this returns, so a handoff
    /// that never lands leaves the music exactly where it was rather than nowhere at all.
    @discardableResult
    static func handOff(_ request: HandoffRequest, to peer: PairedPeer) async throws -> HandoffAck {
        let base = try await resolveBase(for: peer)
        return try await post(
            to: base.appendingPathComponent("api/peer/handoff"),
            body: request,
            for: peer
        )
    }

    struct EmptyReply: Codable {}

    // MARK: - Addressing

    /// Last known address first, Bonjour only if that fails.
    ///
    /// The cached host is almost always still right, and a direct hit is faster than waiting on
    /// a browse — so discovery is the recovery path for an address that moved, not the hot path.
    /// The address resolved most recently, and when.
    ///
    /// Without this every single request re-probed the peer — a 2s reachability check, and a 3s
    /// Bonjour browse behind it. Once playback reports started going out once a second that was
    /// enough concurrent main-actor network work to starve the embedded server: Swifter's
    /// handlers hop to the main queue via `DispatchQueue.main.sync`, so a saturated main actor
    /// turned *every* route — including the browser's — into a 503. Resolving is the expensive
    /// exception, not the per-request norm.
    ///
    /// One per peer. A single shared slot was right while there was only ever one peer; with
    /// two, every request to the second would be sent to wherever the first was last found.
    private static var cachedBases: [String: (url: URL, at: Date)] = [:]
    private static let baseCacheLifetime: TimeInterval = 30

    /// Dropped whenever a request to that peer fails, so a peer that moved is re-found
    /// immediately rather than after the cache happens to age out.
    static func invalidateCachedBase(for peerId: String) { cachedBases[peerId] = nil }

    /// A device that has left the group: nothing about where it was is worth keeping.
    static func forget(peerId: String) { invalidateCachedBase(for: peerId) }

    private static func resolveBase(for peer: PairedPeer) async throws -> URL {
        if let cached = cachedBases[peer.peerId], Date().timeIntervalSince(cached.at) < baseCacheLifetime {
            return cached.url
        }
        if let host = peer.lastKnownHost,
           let url = URL(string: "http://\(host):\(peer.lastKnownPort ?? Int(LocalControlServer.shared.port))") {
            if await answers(url, as: peer.peerId) {
                PairLog.info("resolveBase: cached address \(host) answered for \(peer.name)")
                cachedBases[peer.peerId] = (url, Date())
                return url
            }
            PairLog.info("resolveBase: cached address \(host) did not answer — falling back to Bonjour")
        }
        PeerDiscovery.shared.startBrowsing()
        // Stopped on every exit, including the throw. Started and never stopped, the first
        // unreachable poll left the app browsing `_vvdemus._tcp` continuously for the rest of the
        // process — a radio that never idles, which is the one thing the poll's own backoff exists
        // to avoid.
        defer { PeerDiscovery.shared.stopBrowsing() }
        // Bonjour resolution is not instant; poll briefly rather than failing on the first look.
        for _ in 0..<10 {
            if let found = PeerDiscovery.shared.peers.first(where: { $0.peerId == peer.peerId }),
               let url = found.baseURL {
                PairedPeerStore.shared.rememberAddress(host: found.host, port: found.port, for: peer.peerId)
                PairLog.info("resolveBase: Bonjour found \(found.name) at \(found.host):\(found.port)")
                cachedBases[peer.peerId] = (url, Date())
                return url
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        // Bluetooth last, and only because the two above have failed. It is the slowest of the
        // three — a scan, a connect and a read — but it is the only one that survives the two
        // devices sitting on different subnets of one network, which is where Bonjour stops:
        // mDNS is multicast with a TTL of 1 and no router forwards it. That is not an exotic
        // setup; it is what a campus or office network does to two devices on one SSID.
        if let found = await PeerBeacon.shared.resolveAddress(for: peer),
           let url = URL(string: "http://\(found.host):\(found.port)") {
            // Probed, not trusted. A beacon is sealed but not necessarily current — the peer may
            // have moved since it sealed one — and this is the cheap way to tell, so the payload
            // carries no expiry of its own.
            if await answers(url, as: peer.peerId) {
                PairedPeerStore.shared.rememberAddress(host: found.host, port: found.port, for: peer.peerId)
                PairLog.info("resolveBase: Bluetooth found \(peer.name) at \(found.host):\(found.port)")
                cachedBases[peer.peerId] = (url, Date())
                return url
            }
            PairLog.error("resolveBase: Bluetooth offered \(found.host):\(found.port) for \(peer.name), but nothing answered there")
        }
        PairLog.error("resolveBase: gave up — \(peer.name) was not found on the network")
        throw PeerError.unreachable
    }

    /// Whether `base` is answered by the device we mean, not merely by *a* device.
    ///
    /// `/api/peer/hello` returns a peerId precisely so this can be checked — its own comment says
    /// it exists to tell "the peer is at this address" from "something else is" — and checking
    /// only the status code threw that away. A remembered address routinely stops belonging to the
    /// peer: DHCP hands it to another machine, or the two apps swap ports when both run on one Mac
    /// and the simulator picks up the port the Mac app had. In the worst case the address resolves
    /// to this very app, and the session is handed to ourselves.
    private static func answers(_ base: URL, as peerId: String) async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("api/peer/hello"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let hello = try? JSONDecoder().decode([String: String].self, from: data)
        else { return false }
        guard hello["peerId"] == peerId else {
            PairLog.error("address answered, but as \(hello["peerId"]?.prefix(8) ?? "someone else") rather than the paired device")
            return false
        }
        return true
    }

    // MARK: - Transport

    private static func post<Body: Encodable, Reply: Decodable>(
        to url: URL,
        body: Body,
        for peer: PairedPeer?
    ) async throws -> Reply {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let peer { try authorize(&request, for: peer) }
        request.httpBody = try encoder.encode(body)
        return try await send(request, to: peer?.peerId)
    }

    private static func get<Reply: Decodable>(_ url: URL, from peer: PairedPeer) async throws -> Reply {
        var request = URLRequest(url: url)
        try authorize(&request, for: peer)
        return try await send(request, to: peer.peerId)
    }

    /// Both peer headers in one place: who we are, and where to call us back.
    ///
    /// The port is here because the other side cannot work it out. It learns this device's
    /// address from the inbound connection, but that connection's source port is ephemeral — so
    /// without this header a peer holds a host it can trust beside a port it has to guess, and
    /// 51825 is only the right guess until two copies of the app on one machine push the second
    /// to 51826.
    private static func authorize(_ request: inout URLRequest, for peer: PairedPeer) throws {
        guard let token = PairedPeerStore.shared.sessionToken(for: peer) else { throw PeerError.notPaired }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(String(LocalControlServer.shared.port), forHTTPHeaderField: "x-vvdemus-port")
    }

    private static func send<Reply: Decodable>(_ request: URLRequest, to peerId: String?) async throws -> Reply {
        let data: Data
        let response: URLResponse
        let target = request.url?.absoluteString ?? "?"
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // The failure that mattered: a `.local` name resolves to an IPv6 link-local address
            // the IPv4-only server never answers on, and the connection is refused here.
            PairLog.error("request to \(target) failed at the transport: \(error.localizedDescription)")
            if let peerId { invalidateCachedBase(for: peerId) }
            throw PeerError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw PeerError.badResponse }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            PairLog.error("request to \(target) was refused: HTTP \(http.statusCode) — \(message)")
            throw PeerError.rejected(message)
        }
        PairLog.info("request to \(target) succeeded (\(data.count) bytes)")
        if Reply.self == EmptyReply.self, let empty = EmptyReply() as? Reply { return empty }
        guard let decoded = try? decoder.decode(Reply.self, from: data) else { throw PeerError.badResponse }
        return decoded
    }

    /// ISO-8601 on the wire. The default strategy encodes a `Date` as seconds since 2001, which
    /// is fine between two builds of this app but impossible to read in a log when a merge goes
    /// wrong — and every merge rule here turns on comparing dates.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
