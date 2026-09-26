import Foundation
import Swifter

/// The inbound half of the peer link, served off the same Swifter instance the web remote uses.
///
/// Kept apart from `registerRoutes` because the trust model is different. Every route in there
/// is unauthenticated by design — the browser is trusted for being on the same WiFi, the same
/// way AirPlay is. These routes are not: they carry the whole library in both directions, so
/// they require the bearer token both devices derived when they paired.
extension LocalControlServer {
    func registerPeerRoutes() {
        // Unauthenticated on purpose, and answers nothing but its own name: it exists so a
        // client can tell "the peer is at this address" from "something else is".
        server.GET["/api/peer/hello"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            return self.onMain {
                self.jsonResponse(["peerId": PeerIdentity.shared.peerId, "name": PeerIdentity.shared.name])
            }
        }

        // Also unauthenticated — this is where the token comes from. The six digits are what
        // stand in for authentication here.
        server.POST["/api/pair/begin"] = { [weak self] request in
            guard let self else { return .internalServerError }
            guard let body = try? JSONDecoder().decode(PairRequest.self, from: Data(request.body)),
                  let publicKey = Data(base64Encoded: body.publicKey) else {
                return .badRequest(.text("bad pairing request"))
            }
            PairLog.info("incoming pair request from \(body.name) (peerId \(body.peerId.prefix(8)))")
            return self.onMain {
                let session = PairingSession.shared
                guard let code = session.activeCode else {
                    PairLog.error("rejected pair from \(body.name) — no live code on this device")
                    return .badRequest(.text("No pairing code is showing on this device. Open Settings to start pairing."))
                }
                guard PairingProof.verify(
                    body.proof,
                    code: code,
                    publicKey: publicKey,
                    peerId: body.peerId,
                    responding: false
                ) else {
                    session.recordFailure()
                    PairLog.error("rejected pair from \(body.name) — proof did not verify (wrong code)")
                    return .badRequest(.text("That code didn't match."))
                }

                let identity = PeerIdentity.shared
                PairedPeerStore.shared.save(
                    PairedPeer(
                        peerId: body.peerId,
                        name: body.name,
                        publicKey: publicKey,
                        isDesktop: body.isDesktop,
                        // Filled in on the first outbound call; the inbound connection's address
                        // is the peer's source port, which is not where it listens.
                        lastKnownHost: nil,
                        lastKnownPort: nil,
                        pairedAt: Date()
                    )
                )
                session.recordSuccess()
                PairLog.info("accepted pair from \(body.name) — now paired")

                return self.jsonResponse(
                    PairResponse(
                        peerId: identity.peerId,
                        name: identity.name,
                        isDesktop: identity.isDesktop,
                        publicKey: identity.publicKey.base64EncodedString(),
                        proof: PairingProof.make(
                            code: code,
                            publicKey: identity.publicKey,
                            peerId: identity.peerId,
                            responding: true
                        )
                    )
                )
            }
        }

        server.POST["/api/sync"] = { [weak self] request in
            guard let self else { return .internalServerError }
            guard self.onMain({ self.authorizePeer(request) }) else {
                PairLog.error("rejected /api/sync — bearer token missing or wrong")
                return .raw(401, "Unauthorized", nil, { _ in })
            }
            guard let payload = try? Self.peerDecoder.decode(SyncPayload.self, from: Data(request.body)) else {
                PairLog.error("rejected /api/sync — payload did not decode")
                return .badRequest(.text("bad sync payload"))
            }
            return self.onMain {
                // Merge first, then answer — so the reply already reflects anything the peer
                // just taught us and a second round is not needed to converge.
                let merged = SyncEngine.merge(payload)
                PairLog.info("served /api/sync — merged \(merged.description)")
                let reply = SyncEngine.snapshot(eventsSince: payload.eventsSince)
                guard let data = try? Self.peerEncoder.encode(reply) else { return .internalServerError }
                return .ok(.data(data, contentType: "application/json"))
            }
        }

        // The same snapshot the web remote gets, for the paired device.
        //
        // Reusing `StateSnapshot` rather than inventing a peer-shaped one: it already carries
        // everything a mirror needs — track, position, both queues, shuffle, liked ids, and the
        // epochs that let a stale reply be discarded — and it is already kept correct by every
        // path that touches playback.
        server.GET["/api/peer/state"] = { [weak self] request in
            guard let self else { return .internalServerError }
            guard self.onMain({ self.authorizePeer(request) }) else {
                return .raw(401, "Unauthorized", nil, { _ in })
            }
            return self.onMain {
                guard let data = try? Self.peerEncoder.encode(self.stateSnapshot()) else {
                    return .internalServerError
                }
                return .ok(.data(data, contentType: "application/json"))
            }
        }

        // Transport, from the other device. This is what makes either end able to drive the
        // session: pressing pause on the Mac while the phone is the one playing sends this.
        server.POST["/api/peer/command"] = { [weak self] request in
            guard let self else { return .internalServerError }
            guard self.onMain({ self.authorizePeer(request) }) else {
                return .raw(401, "Unauthorized", nil, { _ in })
            }
            guard let body = try? Self.peerDecoder.decode(PeerCommand.self, from: Data(request.body)) else {
                return .badRequest(.text("bad command"))
            }
            PairLog.info("peer command: \(body.action)")
            return self.onMain {
                let player = PlayerService.shared
                switch body.action {
                // Absolute, so a command that arrives twice — or lands after this device has
                // already changed state — settles on the same answer instead of flipping back.
                // The sender resolves its own toggle against what it had on screen; by the time
                // anything reaches here it says "play" or "pause", never "the other one".
                case "setPlaying":
                    if let playing = body.playing { player.setPlayback(playing: playing) }
                // Kept for a peer running an older build, which sends nothing else.
                case "toggle": player.togglePlayPause()
                // Names the track the press was made against, so a next this device has already
                // handled is a no-op rather than a second skip — the same guard the browser's
                // `/api/next` uses, and for the same reason.
                case "next": player.advanceIfCurrent(body.videoId)
                case "previous": player.previous()
                case "shuffle": player.toggleShuffle()
                case "seek": if let seconds = body.seconds { player.seek(to: seconds) }
                case "volume": if let value = body.value { player.setVolume(value) }
                // The mirror has no player of its own, so pressing a track there means "play this
                // on the device that owns the session" — exactly what the browser's `/api/play`
                // means. The context travels with it so the owner's queue matches the list the
                // track was picked from.
                case "play":
                    guard let track = body.track else { return .badRequest(.text("play needs a track")) }
                    // Capped like `/api/play`: this arrives over the network and a whole library
                    // pasted into one request should be refused, not queued.
                    let context = Array((body.context ?? []).prefix(Self.maximumContextTracks))
                    player.play(
                        track: track,
                        context: context,
                        contextTitle: body.contextTitle,
                        contextSeed: body.contextSeed
                    )
                case "addToQueue":
                    if let track = body.track { player.addToQueue(track) }
                case "playNext":
                    if let track = body.track { player.playNext(track) }
                case "skipTo":
                    if let videoId = body.videoId, let track = player.queuedTrack(videoId: videoId) {
                        player.skipTo(track)
                    }
                case "removeFromQueue":
                    if let videoId = body.videoId, let track = player.queuedTrack(videoId: videoId) {
                        player.removeFromQueue(track)
                    }
                case "moveInQueue":
                    guard let raw = body.queue,
                          let origin = PlayerService.QueueOrigin(rawValue: raw),
                          let from = body.fromIndex,
                          let to = body.toIndex else {
                        return .badRequest(.text("moveInQueue needs a queue and two indices"))
                    }
                    // Both numbers describe the *sender's* copy of this queue, and this one moves
                    // on its own at every track boundary. Correcting only the source — which is
                    // what this did — left the destination describing a list one entry longer
                    // than the one it was applied to, so a drag made while this device was
                    // mid-track landed the row one place late. `QueueMove` re-resolves both, by
                    // identity where the sender named one and by the source's own drift where it
                    // did not.
                    let queue = origin == .manual ? player.manualQueue : player.contextQueue
                    let anchor: QueueMove.Anchor
                    if let anchorVideoId = body.anchorVideoId {
                        anchor = .before(anchorVideoId)
                    } else if body.dropsAtQueueEnd == true {
                        anchor = .end
                    } else {
                        anchor = .unstated
                    }
                    let decision = QueueMove.decide(QueueMove.Inputs(
                        queue: queue.map(\.videoId),
                        movedVideoId: body.videoId,
                        anchor: anchor,
                        from: from,
                        to: to
                    ))
                    // A row that is no longer here has nothing to move, and moving whatever now
                    // stands at `from` instead — which is what the old fallback did — edits a
                    // queue the sender never touched.
                    guard let source = decision.source else { return .ok(.text("ok")) }
                    switch origin {
                    case .manual:
                        player.moveInManualQueue(from: IndexSet(integer: source), to: decision.destination)
                    case .context:
                        player.moveInContextQueue(from: IndexSet(integer: source), to: decision.destination)
                    }
                // "Play on this device" pressed over there: the picker cannot pull a session, so
                // it asks the device that has one to push it. That reuses the acked handoff
                // rather than inventing a second, opposite handshake to keep correct.
                case "pullSession":
                    Task { await PeerLink.shared.handOffToPeer() }
                default: return .badRequest(.text("unknown action"))
                }
                return .ok(.text("ok"))
            }
        }

        // Downloads requested by the other device — the receiving end of "Download to Phone".
        server.POST["/api/peer/download"] = { [weak self] request in
            guard let self else { return .internalServerError }
            guard self.onMain({ self.authorizePeer(request) }) else {
                return .raw(401, "Unauthorized", nil, { _ in })
            }
            guard let tracks = try? Self.peerDecoder.decode([Track].self, from: Data(request.body)) else {
                return .badRequest(.text("bad download request"))
            }
            return self.onMain {
                for track in tracks { DownloadManager.shared.download(track) }
                PairLog.info("peer asked for \(tracks.count) download(s)")
                return .ok(.text("ok"))
            }
        }

        // There is no `/api/peer/report`. It existed for a peer acting as this device's speaker
        // — reporting where it had got to, and vouching for itself while it did, since it holds
        // no WebSocket for `castLiveness` to judge it by. The session now moves whole rather than
        // splitting the queue from the sound, so a mirror never makes a noise, never has a
        // position of its own to report, and there is no output to pull back off it. The browser
        // keeps its own reporting path untouched.

        server.GET["/api/peer/checkpoint"] = { [weak self] request in
            guard let self else { return .internalServerError }
            guard self.onMain({ self.authorizePeer(request) }) else {
                return .raw(401, "Unauthorized", nil, { _ in })
            }
            return self.onMain {
                guard let data = try? Self.peerEncoder.encode(PlayerService.shared.nowPlayingCheckpoint()) else {
                    return .internalServerError
                }
                return .ok(.data(data, contentType: "application/json"))
            }
        }

        server.POST["/api/peer/handoff"] = { [weak self] request in
            guard let self else { return .internalServerError }
            guard self.onMain({ self.authorizePeer(request) }) else {
                return .raw(401, "Unauthorized", nil, { _ in })
            }
            guard let body = try? Self.peerDecoder.decode(HandoffRequest.self, from: Data(request.body)) else {
                return .badRequest(.text("bad handoff"))
            }
            return self.onMain {
                // Autoplay from the checkpoint, not unconditionally. The sender pauses itself
                // before sending so the two are never audible at once, and the checkpoint was
                // captured before that pause — so this is what playback was actually doing when
                // the user asked for the handoff. Handing over a paused session used to start it
                // playing on the other device by itself.
                PlayerService.shared.adopt(checkpoint: body.checkpoint, autoplay: body.checkpoint.isPlaying)
                // Claimed above the sender's counter, so the ack it gets back is unambiguously
                // newer than what it holds and it can let go without the two ending up both
                // believing they own the session.
                SessionOwnership.shared.claimFromHandoff(supersedingSenderClaim: body.senderClaim)
                // Straight away, not on the next poll. For that second this device is playing
                // while still believing it is a mirror, so its own transport presses would be
                // relayed back to the device that has just handed the session over.
                PeerPlayback.shared.ownershipChangedLocally()
                PairLog.info("adopted a handoff: \(body.checkpoint.currentTrack?.title ?? "nothing") at \(String(format: "%.1f", body.checkpoint.progress))s, playing=\(body.checkpoint.isPlaying)")
                guard let data = try? Self.peerEncoder.encode(
                    HandoffAck(accepted: true, ownership: SessionOwnership.shared.current)
                ) else { return .internalServerError }
                return .ok(.data(data, contentType: "application/json"))
            }
        }
    }

    /// Authorizes a peer request, and takes the peer's current address from it on the way past.
    ///
    /// The address half wraps the check rather than sitting beside each caller because it has to
    /// run for every authenticated route and a route added later must not be able to forget it.
    /// It costs no extra main-queue hop: the callers already pay for one around the authorization
    /// check itself — a blocking `DispatchQueue.main.sync` from a Swifter worker — and this rides
    /// inside that same hop.
    ///
    /// This is the direction that was missing. Pairing recorded an address only on the device
    /// that *initiated* it; the device that accepted stored `lastKnownHost: nil` and could find
    /// its peer by Bonjour alone ever after. Two devices on different subnets then had no way to
    /// learn anything about each other, even while one was successfully talking to the other.
    func authorizePeer(_ request: HttpRequest) -> Bool {
        guard isAuthorizedPeer(request) else { return false }
        learnPeerAddress(from: request)
        return true
    }

    /// Records where an authenticated request came from.
    ///
    /// Only the host. A connection's source port is ephemeral and says nothing about where the
    /// peer *listens* — the original reason pairing stored no port at all — so the listening port
    /// has to be told to us, in `x-vvdemus-port`. Absent that, the port already on file is kept
    /// rather than guessed: overwriting a correct port with 51825 would break the very address
    /// this is trying to repair, since a second copy of the app on one machine listens on 51826.
    private func learnPeerAddress(from request: HttpRequest) {
        // Swifter's `address` defaults to the empty string rather than nil, so an absent address
        // arrives as "" and would otherwise be written down as the peer's location.
        guard let host = request.address, !host.isEmpty else { return }
        guard let peer = PairedPeerStore.shared.peer else { return }
        let advertised = (request.headers["x-vvdemus-port"] ?? request.headers["X-VVDemus-Port"])
            .flatMap(Int.init)
            .flatMap { (1...65535).contains($0) ? $0 : nil }
        guard let port = advertised ?? peer.lastKnownPort else { return }
        // Logged because this field is now writable by anything that can authenticate, and a
        // redirect is otherwise the quietest possible change: the link keeps working, against a
        // different machine. `rememberAddress` no-ops when nothing moved, so this stays silent
        // in the steady state and speaks up exactly when the peer's address changes.
        if peer.lastKnownHost != host || peer.lastKnownPort != port {
            PairLog.info("learned \(peer.name) is at \(host):\(port) from an authenticated request")
        }
        PairedPeerStore.shared.rememberAddress(host: host, port: port)
    }

    /// Constant-time check of the bearer token both devices derived from the pairing.
    ///
    /// The token is never transmitted during pairing — only public keys are — so it cannot be
    /// recovered by watching the exchange.
    func isAuthorizedPeer(_ request: HttpRequest) -> Bool {
        guard let expected = PairedPeerStore.shared.sessionToken() else { return false }
        let header = request.headers["authorization"] ?? request.headers["Authorization"]
        guard let provided = header?.replacingOccurrences(of: "Bearer ", with: ""),
              provided.count == expected.count else { return false }
        // Compared byte by byte with no early exit, so a wrong token cannot be narrowed down by
        // timing the rejection.
        var difference: UInt8 = 0
        for (lhs, rhs) in zip(provided.utf8, expected.utf8) { difference |= lhs ^ rhs }
        return difference == 0
    }

    static var peerEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var peerDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
