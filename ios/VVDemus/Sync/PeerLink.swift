import Foundation

/// Owns the relationship with the paired device: advertising, periodic sync, and the
/// "continue from…" offer.
///
/// Sync is pull-shaped and driven from here rather than pushed on every edit. Two devices that
/// both push on every like would spend a lot of round trips telling each other things they
/// already know, and the merge is idempotent anyway — so a periodic round plus one on
/// foreground is both simpler and enough.
@MainActor
final class PeerLink: ObservableObject {
    static let shared = PeerLink()

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastError: String?
    /// What the last round brought over, so "synced" is a statement about your library rather
    /// than a spinner that stopped.
    @Published private(set) var lastSummary: SyncSummary?
    /// What is happening right now — shown while `isSyncing`.
    @Published private(set) var phase: String?
    /// Set for a few seconds after pairing succeeds, so the moment is visibly confirmed
    /// instead of the screen just quietly changing shape.
    @Published var justPairedWith: String?
    /// The peer's playback, when it is worth offering to continue from.
    @Published private(set) var resumeOffer: NowPlayingCheckpoint?

    /// Often enough that the two feel connected, rarely enough that it is not chatty. Anything
    /// urgent (a handoff) goes over its own route immediately rather than waiting for this.
    private static let interval: TimeInterval = 60

    private var timer: Timer?

    private init() {}

    var pairedPeer: PairedPeer? { PairedPeerStore.shared.peer }

    /// Shows the "Paired with…" confirmation, then clears it on its own.
    func confirmPaired(with name: String) {
        justPairedWith = name
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if justPairedWith == name { justPairedWith = nil }
        }
    }

    func start() {
        PeerDiscovery.shared.startAdvertising(port: Int(LocalControlServer.shared.port))
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncNow() }
        }
        // `.common`, so scrolling a list does not stall the sync the way it would stall a
        // default-mode timer.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { await syncNow() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        PeerDiscovery.shared.stopAdvertising()
    }

    /// Pushes local library changes to the peer soon, rather than at the next minute boundary.
    ///
    /// Deleting a radio or a playlist is the case that made this necessary: the merge already
    /// resolves it correctly through tombstones, but waiting up to a minute to see it vanish on
    /// the other device reads as the delete not having worked. Debounced, because a burst of
    /// edits — clearing several radios in a row — should still cost one round.
    func libraryDidChange() {
        guard PairedPeerStore.shared.peer != nil else { return }
        pushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.syncNow() }
        }
        pushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pushDelay, execute: work)
    }

    private static let pushDelay: TimeInterval = 2
    private var pushWork: DispatchWorkItem?

    /// One sync round. Safe to call at any time; overlapping calls collapse into one.
    func syncNow() async {
        guard let peer = PairedPeerStore.shared.peer, !isSyncing else { return }
        isSyncing = true
        phase = "Reaching \(peer.name)…"
        defer {
            isSyncing = false
            phase = nil
        }
        do {
            phase = "Exchanging libraries…"
            let summary = try await PeerClient.sync()
            lastSummary = summary
            lastSyncedAt = Date()
            lastError = nil
        } catch {
            // Not surfaced as an alert: the peer being asleep, on cellular, or simply elsewhere
            // is the normal case for a LAN-only link, not a failure worth interrupting anyone
            // over. The Settings screen shows it for anyone who goes looking.
            lastError = error.localizedDescription
        }
    }

    // MARK: - Resume where you left off

    /// Asks the peer where it is, and offers to continue if its playback is the one worth
    /// following. Called on launch and on returning to the foreground.
    func refreshResumeOffer() async {
        guard PairedPeerStore.shared.peer != nil else { return }
        guard let theirs = try? await PeerClient.fetchCheckpoint(), theirs.currentTrack != nil else {
            resumeOffer = nil
            return
        }
        let mine = PlayerService.shared.nowPlayingCheckpoint()
        // Nothing to continue *to* if this device is already playing the same thing.
        if mine.currentTrack?.videoId == theirs.currentTrack?.videoId, mine.isPlaying {
            resumeOffer = nil
            return
        }
        // Nor while the peer's session is already on screen. Mirroring shows that track in the
        // transport bar with working controls, so an offer to "continue" it sat directly above
        // the thing it was offering — two rows saying the same thing, one of them redundant.
        if PeerPlayback.shared.isMirroring {
            resumeOffer = nil
            return
        }
        // The active player wins, and the desktop breaks a tie — so a phone paused in a pocket
        // does not pull a Mac that is mid-song off what it is doing.
        resumeOffer = NowPlayingCheckpoint.preferred(mine, theirs) == theirs ? theirs : nil
    }

    func acceptResumeOffer() {
        guard let offer = resumeOffer else { return }
        // Taking the session, not copying it. Claimed *before* the adopt so the peer sees the
        // newer claim on its next poll and lets its own copy go — otherwise both devices would
        // hold the same queue, which is the state that made handing over a one-way trip.
        SessionOwnership.shared.claimLocally()
        PeerPlayback.shared.claimSession()
        // Deliberately does not start playing by itself — this is reached from a button, and a
        // device that begins making noise on its own when you wake it is worse than the problem
        // it solves.
        PlayerService.shared.adopt(checkpoint: offer, autoplay: false)
        resumeOffer = nil
    }

    func dismissResumeOffer() { resumeOffer = nil }

    /// Offers to continue the session a peer was playing when it disappeared.
    ///
    /// Built from the last snapshot rather than a checkpoint, because there is nobody left to ask
    /// for one — that is the whole situation. Two fields the checkpoint route would have carried
    /// are not on the wire, and both degrade rather than break:
    ///
    /// - `orderedContextQueue` falls back to the shuffled order. If shuffle was on, turning it off
    ///   after continuing gives a different running order than the peer would have restored. The
    ///   alternative is sending a second full copy of the queue in every poll, once a second, to
    ///   cover a case that only arises when a device dies mid-song.
    /// - `progress` is where the peer had reached when it was last heard from, up to a second
    ///   before it went. Resuming a second early is not something anyone notices; the arithmetic
    ///   to guess further is guessing.
    func offerToContinue(from state: StateSnapshot) {
        guard let track = state.currentTrack else { return }
        // Never over the session this device is already playing.
        guard PlayerService.shared.currentTrack == nil else { return }
        resumeOffer = NowPlayingCheckpoint(
            peerId: PairedPeerStore.shared.peer?.peerId ?? "",
            isDesktop: PairedPeerStore.shared.peer?.isDesktop ?? false,
            updatedAt: Date(),
            currentTrack: track,
            progress: state.progress,
            isPlaying: false,
            manualQueue: state.manualQueue ?? [],
            contextQueue: state.contextQueue ?? [],
            orderedContextQueue: state.contextQueue ?? [],
            isShuffling: state.isShuffling,
            queueContextTitle: state.queueContextTitle,
            contextSeed: state.contextSeed
        )
    }

    // MARK: - Handoff

    /// Moves playback to the paired device: it takes the queue and the position, and resolves
    /// its own stream URL from its own `InnerTubeClient`.
    ///
    /// Three steps, in this order, and the order is the whole point. Pause first so the two are
    /// never audible at once. Send, and wait to be told the other device is actually playing.
    /// Only then let the session go — because letting go before the ack could leave the music
    /// nowhere, and *not* letting go at all (which is what this used to do) leaves two devices
    /// each holding a queue, which is the state in which neither can drive the other ever again.
    func handOffToPeer() async {
        guard !isHandingOff else { return }
        // Captured before the pause below, so `isPlaying` says what playback was doing when the
        // user asked — that is what the receiver autoplays from.
        let checkpoint = PlayerService.shared.nowPlayingCheckpoint()
        // Deliberately no `guard checkpoint.currentTrack != nil`. A track-less checkpoint still
        // moves the *session*, which is what the picker's rows mean: where the next play lands.
        // With the guard, the picker's "play here" row — which asks the owner to push, via
        // `pullSession` — did nothing at all whenever the owner happened to be holding an empty
        // queue, which is exactly the state a relaunched owner is in and exactly when the mirror
        // most needs a way back. The receiver's `adopt` ignores a nil track, `claimFromHandoff`
        // transfers ownership regardless, and `releaseSession` on an empty player is a no-op, so
        // this is the same one handshake carrying nothing.
        isHandingOff = true
        defer { isHandingOff = false }
        let wasPlaying = PlayerService.shared.isPlaying
        if wasPlaying { PlayerService.shared.setPlayback(playing: false) }
        do {
            let ack = try await PeerClient.handOff(
                HandoffRequest(
                    checkpoint: checkpoint,
                    senderPaused: true,
                    senderClaim: SessionOwnership.shared.current
                )
            )
            guard ack.accepted else {
                reportHandoffFailure("\(pairedPeer?.name ?? "The other device") didn't take it.")
                if wasPlaying { PlayerService.shared.setPlayback(playing: true) }
                return
            }
            // The ack was awaited, so this device may have claimed the session again in the
            // meantime — a play started here, or a resume offer accepted, while the request was
            // in flight. `concede` writes unconditionally by design, so applying a stale ack over
            // a newer local claim would drive ownership backwards and release a session this
            // device legitimately holds.
            guard SessionOwnership.shared.current.claim <= ack.ownership.claim else {
                PairLog.info("handoff acked, but this device has claimed the session since — keeping it")
                if wasPlaying { PlayerService.shared.setPlayback(playing: true) }
                return
            }
            // Conceded before releasing, so nothing in between can see this device as an owner
            // with an empty queue — which is what the resume offer and the transport bar would
            // both read as "nothing is playing anywhere".
            SessionOwnership.shared.concede(to: ack.ownership)
            PeerPlayback.shared.ownershipChangedLocally()
            PlayerService.shared.releaseSession()
            resumeOffer = nil
            lastError = nil
            PairLog.info("handed off to \(pairedPeer?.name ?? "peer") — session released here")
        } catch {
            reportHandoffFailure("Couldn't move playback to \(pairedPeer?.name ?? "the other device").")
            lastError = error.localizedDescription
            PairLog.error("handoff failed — \(error.localizedDescription)")
            // The request may have been applied and only the reply lost, in which case the other
            // device is already playing and resuming here would make both audible. One poll
            // settles it: if the peer did take the session its claim is higher, and adopting it
            // leaves this device mirroring with nothing to resume.
            await PeerPlayback.shared.refresh(force: true)
            guard !PeerPlayback.shared.isMirroring else {
                PairLog.info("the peer took the session after all — not resuming here")
                return
            }
            if wasPlaying { PlayerService.shared.setPlayback(playing: true) }
        }
    }

    /// One at a time. The button is reachable from two places on each device and a double press
    /// would otherwise send a second checkpoint describing a session already given away.
    @Published private(set) var isHandingOff = false

    /// Why the last attempt to move playback failed, for the few seconds after it did.
    ///
    /// Separate from `lastError`, which every missed sync round also writes to. A peer asleep or
    /// elsewhere is the normal case for a LAN link and is deliberately not surfaced — but a
    /// handoff is a thing the user just *asked for* by name, and it was failing into the same
    /// silent field. Choosing the other device in the picker and having nothing whatsoever
    /// happen is indistinguishable from a dead control.
    @Published private(set) var handoffError: String?

    private func reportHandoffFailure(_ message: String) {
        handoffError = message
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if handoffError == message { handoffError = nil }
        }
    }
}
