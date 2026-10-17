import Foundation

/// Owns the relationship with the group: advertising, periodic sync with every member, and the
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
    /// The last time any member answered a round.
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastError: String?
    /// What the last round brought over from everyone together, so "synced" is a statement about
    /// your library rather than a spinner that stopped.
    @Published private(set) var lastSummary: SyncSummary?

    /// How the last round went with one member.
    struct MemberStatus: Equatable {
        var lastSyncedAt: Date?
        var lastError: String?
    }

    /// Per member, because with more than one the group-wide line cannot say the thing worth
    /// knowing — that the Mac synced a minute ago and the iPad has not been seen since Tuesday.
    @Published private(set) var memberStatus: [String: MemberStatus] = [:]
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
        PeerBeacon.shared.startAdvertising(port: Int(LocalControlServer.shared.port))
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
        PeerBeacon.shared.stopAdvertising()
    }

    /// Pushes local library changes to the peer soon, rather than at the next minute boundary.
    ///
    /// Deleting a radio or a playlist is the case that made this necessary: the merge already
    /// resolves it correctly through tombstones, but waiting up to a minute to see it vanish on
    /// the other device reads as the delete not having worked. Debounced, because a burst of
    /// edits — clearing several radios in a row — should still cost one round.
    func libraryDidChange() {
        guard PairedPeerStore.shared.hasPeers else { return }
        pushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.syncNow() }
        }
        pushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pushDelay, execute: work)
    }

    private static let pushDelay: TimeInterval = 2
    private var pushWork: DispatchWorkItem?

    /// Someone joined or left: tells the rest of the group soon, the same way a library edit does.
    ///
    /// The member who accepted a pairing is the only one that knows about the newcomer, and it
    /// would otherwise sit on that for up to a minute — during which the newcomer's own first
    /// round has already introduced it to the others it can see, while the device it just paired
    /// with has introduced it to nobody.
    ///
    /// The beacon is resealed here too: its value holds one copy per member, and a member added
    /// since it was sealed would find nothing in it that its key opens.
    func groupDidChange() {
        PeerBeacon.shared.groupDidChange()
        libraryDidChange()
    }

    /// One round with every member. Safe to call at any time; overlapping calls collapse into one.
    ///
    /// One member at a time rather than all at once. Every round carries the whole library and
    /// rewrites the same stores, and reaching a member that is away costs a probe, a browse and a
    /// Bluetooth scan — run side by side, they would contend for the one radio the scan needs.
    /// Members that answered their last poll go first, so a phone asleep in a bag does not hold
    /// up the Mac on the desk.
    func syncNow() async {
        guard PairedPeerStore.shared.hasPeers else { return }
        // Collapsed into the round already running, but not dropped: a round asked for while one
        // is under way may be asking because of something that round has already passed — a
        // member it reached before learning of a newcomer — and would otherwise wait out the
        // minute for the timer.
        guard !isSyncing else {
            wantsAnotherRound = true
            return
        }
        // This device may have moved since the last round. Re-sealing here rather than on a timer
        // of the beacon's own: a round is already the heartbeat that notices everything else
        // about the link, and an address nobody is asking about costs nothing to leave stale.
        PeerBeacon.shared.refreshAdvertisedAddress()
        isSyncing = true
        defer {
            isSyncing = false
            phase = nil
        }
        repeat {
            wantsAnotherRound = false
            await syncRound()
        } while wantsAnotherRound && PairedPeerStore.shared.hasPeers
    }

    private var wantsAnotherRound = false

    private func syncRound() async {
        var combined = SyncSummary()
        var anyAnswered = false
        var failures: [String] = []
        var done: Set<String> = []
        // Re-read every pass rather than captured once: a round can introduce a new member, and
        // meeting it straight away is the whole point of being introduced.
        while let peer = nextToSync(skipping: done) {
            done.insert(peer.peerId)
            phase = "Reaching \(peer.name)…"
            do {
                let summary = try await PeerClient.sync(with: peer)
                combined.add(summary)
                // The members already met this round heard the old list; one more round soon
                // carries the new one to them.
                if summary.devices > 0 { groupDidChange() }
                anyAnswered = true
                memberStatus[peer.peerId] = MemberStatus(lastSyncedAt: Date(), lastError: nil)
            } catch {
                // Not surfaced as an alert: a member being asleep, on cellular, or simply
                // elsewhere is the normal case for a LAN-only link, not a failure worth
                // interrupting anyone over. The pairing screen shows it for anyone who looks.
                memberStatus[peer.peerId, default: MemberStatus()].lastError = error.localizedDescription
                failures.append("\(peer.name): \(error.localizedDescription)")
            }
        }
        // Members that have left since the last round have nothing left to report.
        memberStatus = memberStatus.filter { PairedPeerStore.shared.peer(id: $0.key) != nil }
        if anyAnswered {
            lastSummary = combined
            lastSyncedAt = Date()
        }
        lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private func nextToSync(skipping done: Set<String>) -> PairedPeer? {
        let remaining = PairedPeerStore.shared.peers.filter { !done.contains($0.peerId) }
        return remaining.first { PeerPlayback.shared.isReachable($0.peerId) } ?? remaining.first
    }

    // MARK: - Joining and leaving

    /// Takes `peer` out of the group, here and — at their next round — on every other member.
    func remove(_ peer: PairedPeer) async {
        PairedPeerStore.shared.remove(peerId: peer.peerId)
        PairLog.info("removed \(peer.name) from the group")
        await syncNow()
    }

    /// This device leaves the group.
    ///
    /// Each member is told first, while this device still holds the keys to say it with, and each
    /// passes the removal on to the rest. A member that cannot be reached is not waited for: it
    /// will hear from the others, and if it hears from nobody its requests here simply go
    /// unanswered from now on.
    func leaveGroup() async {
        let members = PairedPeerStore.shared.peers
        await withTaskGroup(of: Void.self) { group in
            for member in members {
                group.addTask { @MainActor in
                    do {
                        try await PeerClient.leave(member)
                        PairLog.info("told \(member.name) this device is leaving")
                    } catch {
                        PairLog.error("could not tell \(member.name) this device is leaving — \(error.localizedDescription)")
                    }
                }
            }
        }
        PairedPeerStore.shared.forgetAll()
        memberStatus = [:]
        lastSummary = nil
        lastSyncedAt = nil
        lastError = nil
        resumeOffer = nil
    }

    // MARK: - Resume where you left off

    /// Asks the peer where it is, and offers to continue if its playback is the one worth
    /// following. Called on launch and on returning to the foreground.
    func refreshResumeOffer() async {
        let members = PairedPeerStore.shared.peers
        guard !members.isEmpty else { return }
        // Every member is asked, and the one most worth following is the one offered — by the
        // same rule that compares it with this device below.
        let checkpoints = await withTaskGroup(of: NowPlayingCheckpoint?.self) { group in
            for member in members {
                group.addTask { @MainActor in try? await PeerClient.fetchCheckpoint(from: member) }
            }
            var found: [NowPlayingCheckpoint] = []
            for await checkpoint in group {
                if let checkpoint, checkpoint.currentTrack != nil { found.append(checkpoint) }
            }
            return found
        }
        guard let theirs = checkpoints.dropFirst().reduce(checkpoints.first, { best, next in
            best.map { NowPlayingCheckpoint.preferred($0, next) } ?? next
        }) else {
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
    func offerToContinue(from state: StateSnapshot, peer: PairedPeer) {
        guard let track = state.currentTrack else { return }
        // Never over the session this device is already playing.
        guard PlayerService.shared.currentTrack == nil else { return }
        resumeOffer = NowPlayingCheckpoint(
            peerId: peer.peerId,
            isDesktop: peer.isDesktop,
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

    /// Moves playback to `target`: it takes the queue and the position, and resolves its own
    /// stream URL from its own `InnerTubeClient`.
    ///
    /// Three steps, in this order, and the order is the whole point. Pause first so the two are
    /// never audible at once. Send, and wait to be told the other device is actually playing.
    /// Only then let the session go — because letting go before the ack could leave the music
    /// nowhere, and *not* letting go at all (which is what this used to do) leaves two devices
    /// each holding a queue, which is the state in which neither can drive the other ever again.
    func handOff(to target: PairedPeer) async {
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
                ),
                to: target
            )
            guard ack.accepted else {
                reportHandoffFailure("\(target.name) didn't take it.")
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
            PairLog.info("handed off to \(target.name) — session released here")
        } catch {
            reportHandoffFailure("Couldn't move playback to \(target.name).")
            lastError = error.localizedDescription
            PairLog.error("handoff failed — \(error.localizedDescription)")
            // The request may have been applied and only the reply lost, in which case the other
            // device is already playing and resuming here would make both audible. One poll
            // settles it: if the target did take the session its claim is higher, and adopting it
            // leaves this device mirroring with nothing to resume.
            await PeerPlayback.shared.refresh(target, force: true)
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
