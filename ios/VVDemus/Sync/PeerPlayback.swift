import Foundation

/// Keeps the two devices showing the same session, and lets either one drive it.
///
/// The model is the web remote's, extended to a second full app. One device *owns* the session —
/// it holds the queue, decides what plays next, and makes the sound — and the other mirrors it: a
/// remote with an empty player of its own, exactly as a browser tab is. Ownership is recorded
/// rather than guessed (see `OwnershipClaim`), and the only thing that moves it is a handoff.
///
/// The emptiness of the mirror's player is the invariant everything rests on. It is what makes
/// "pause" unambiguous, what stops two queues drifting apart, and what `enforceOwnership` exists
/// to restore whenever a poll reveals this device is no longer in charge.
@MainActor
final class PeerPlayback: ObservableObject, SessionOwning {
    static let shared = PeerPlayback()

    /// The peer's playback, refreshed while both are connected. `nil` when the peer is
    /// unreachable.
    @Published private(set) var peerState: StateSnapshot?
    @Published private(set) var isPeerReachable = false

    /// Whether the peer holds the session, so this device is a remote for it.
    ///
    /// Published rather than computed on demand because it gates what every transport control
    /// shows and does, and it changes from three unrelated places — a poll, a handoff, and this
    /// device starting something of its own.
    @Published private(set) var isMirroring = false

    /// A poll, not a socket. The server's own broadcast is a WebSocket because a browser tab is
    /// long-lived and cheap to push to; here both ends are the same app and a 1s GET keeps the
    /// whole thing inside the authenticated HTTP surface that already exists, with no second
    /// liveness mechanism to keep correct.
    private static let interval: TimeInterval = 1
    private var timer: Timer?

    private init() {}

    /// The rules themselves, as a value — see `PlaybackMirror`.
    private var mirror: PlaybackMirror {
        PlaybackMirror(
            pairedPeerId: PairedPeerStore.shared.peer?.peerId,
            isPeerReachable: isPeerReachable,
            ownerPeerId: SessionOwnership.shared.current.ownerPeerId,
            localPeerId: SessionOwnership.shared.localPeerId,
            // Safe to read straight off the snapshot: `currentTrack` is cleared in exactly one
            // place — `releaseSession()`, i.e. only when a device gives the session up — and
            // `beginLoad` sets it synchronously, so a live session always reports a track and
            // this cannot flicker mid-song.
            ownerHasSession: peerState?.currentTrack != nil
        )
    }

    // MARK: - What the transport shows

    /// What the transport should show: the peer's session when mirroring, otherwise this
    /// device's own.
    var displayedTrack: Track? {
        isMirroring ? peerState?.currentTrack : PlayerService.shared.currentTrack
    }

    /// Play/pause as the user should see it — what they last asked for, until the owner is seen to
    /// agree. See `pendingPlayIntent`.
    ///
    /// A plain read of a value settled once per snapshot, deliberately. Resolving the latch here
    /// instead would mean expiring an intent and possibly re-sending a command from inside
    /// SwiftUI's `body` evaluation, which is both a mutation during view update and a send whose
    /// rate depends on how many views happen to read it. The browser hit the same trap and pinned
    /// the same rule: evaluate it exactly once per snapshot.
    var displayedIsPlaying: Bool {
        isMirroring ? mirroredIsPlaying : PlayerService.shared.isPlaying
    }

    /// The settled answer for the current snapshot.
    @Published private(set) var mirroredIsPlaying = false

    var displayedProgress: Double {
        isMirroring ? (peerState?.progress ?? 0) : PlayerService.shared.progress
    }

    var displayedDuration: Double {
        isMirroring ? (peerState?.duration ?? 0) : PlayerService.shared.duration
    }

    var displayedIsShuffling: Bool {
        isMirroring ? (peerState?.isShuffling ?? false) : PlayerService.shared.isShuffling
    }

    var displayedIsLoading: Bool {
        isMirroring ? (peerState?.isLoading ?? false) : PlayerService.shared.isLoading
    }

    /// The volume trim of the device actually making the sound — which is the only one a slider
    /// here can meaningfully move.
    var displayedVolume: Double {
        isMirroring ? (peerState?.volume ?? 1) : PlayerService.shared.volume
    }

    var displayedManualQueue: [Track] {
        isMirroring ? (peerState?.manualQueue ?? []) : PlayerService.shared.manualQueue
    }

    var displayedContextQueue: [Track] {
        isMirroring ? (peerState?.contextQueue ?? []) : PlayerService.shared.contextQueue
    }

    var displayedContextTitle: String? {
        isMirroring ? peerState?.queueContextTitle : PlayerService.shared.queueContextTitle
    }

    /// The name of the device actually playing, when it isn't this one — for the "Playing on …"
    /// line the mirroring device shows.
    var owningDeviceName: String? {
        isMirroring ? PairedPeerStore.shared.peer?.name : nil
    }

    // MARK: - Lifecycle

    func start() {
        recomputeMirroring()
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private var isRefreshing = false
    /// When the next attempt is allowed. Backs off while the peer is away.
    private var nextAttemptAt = Date.distantPast
    private var backoff: TimeInterval = 0

    /// A failed poll is expensive — a 2s probe of the cached address, then a 3s Bonjour browse —
    /// so retrying every second while the other device is asleep or elsewhere means the radio is
    /// never idle and the search never stops. That is the *normal* state for a LAN link, not an
    /// exceptional one, so it has to be the cheap path. Success drops straight back to 1s.
    private static let maximumBackoff: TimeInterval = 30

    /// Polls the peer.
    ///
    /// `force` skips the backoff, and the callers that need it are the ones that just did
    /// something and want to know the result. The backoff exists for the idle case — a peer that
    /// is asleep is normal, and re-probing every second means a 2s reachability check plus a 3s
    /// Bonjour browse, forever. But it is armed by exactly the outage that a recovery path is
    /// trying to recover from: after a handoff whose reply was lost, "one poll settles it" polled
    /// nothing at all, because the failure that lost the reply had already pushed the next attempt
    /// 5 to 30 seconds out.
    func refresh(force: Bool = false) async {
        // Not folded into the guard below. Unpairing does not arrive on a poll, so returning here
        // without recomputing left `isMirroring` latched true for the rest of the process: every
        // press was then relayed to a device that no longer existed and silently swallowed, and
        // the app could not play a note until it was relaunched.
        guard PairedPeerStore.shared.peer != nil else {
            forgetPeer()
            return
        }
        guard !isRefreshing, force || Date() >= nextAttemptAt else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let state = try await PeerClient.peerState()
            isPeerReachable = true
            backoff = 0
            nextAttemptAt = .distantPast
            apply(state)
        } catch {
            // Not logged on every tick: a peer that is asleep or away is the normal case for a
            // LAN link, and a line a second about it would bury everything else.
            let wasReachable = isPeerReachable
            if wasReachable {
                PairLog.info("peer went away — \(error.localizedDescription)")
            }
            // `peerState` is deliberately kept. It used to be cleared, which left the remaining
            // device showing nothing at all the moment the one making the sound quit or slept —
            // the music stopped and the screen went blank, with no way to pick it back up. The
            // last snapshot is exactly what "continue from where it stopped" needs, so it is
            // retained and `isPeerReachable` alone says the peer is gone.
            isPeerReachable = false
            // The next connection is a fresh meeting: both sides may have moved on separately
            // while they were out of touch, so the rule has to run again.
            hasSettledWithPeer = false
            recomputeMirroring()
            // Only on the edge. Offered on every failed poll it was rebuilt a second after being
            // dismissed, and again a second after that, for as long as the peer stayed away — so
            // the ✕ did nothing and the bar sat over the screen indefinitely.
            if wasReachable { offerToContinueFromLastSeen() }
            backoff = backoff == 0 ? 5 : min(backoff * 2, Self.maximumBackoff)
            nextAttemptAt = Date().addingTimeInterval(backoff)
        }
    }

    /// True once the two have agreed who owns the session on this connection.
    private var hasSettledWithPeer = false

    /// Settles the first poll of a connection, which the claim counters cannot.
    ///
    /// Both devices may have been playing separately — each the legitimate owner of its own
    /// session, with neither record newer than the other, because neither had heard of the other
    /// when it claimed. Ordering by counter is meaningless across that gap.
    ///
    /// Only the *winner* acts. It claims above everything either side has counted, and the loser
    /// adopts that on its next poll a second later and releases its own session through
    /// `enforceOwnership`. Both devices evaluate the same rule on the same two facts, so they
    /// cannot both conclude they won — which is the only outcome that would leave two sessions
    /// running.
    private func settleFirstMeeting(with state: StateSnapshot) {
        guard PlayerService.shared.currentTrack != nil else {
            // Nothing of ours to defend. If the peer has a session its claim makes us the mirror;
            // if neither has one there is nothing to settle.
            return
        }
        guard state.currentTrack != nil else {
            // Ours is the only session there is, so make sure it is the one named as owner —
            // the peer may still be holding a stale record from before it went away.
            SessionOwnership.shared.claimLocally()
            return
        }

        let localIsDesktop = PeerIdentity.shared.isDesktop
        let meeting = FirstMeeting(
            localIsPlaying: PlayerService.shared.isPlaying,
            peerIsPlaying: state.isPlaying,
            localIsDesktop: localIsDesktop,
            peerIsDesktop: PairedPeerStore.shared.peer?.isDesktop ?? !localIsDesktop,
            localPeerId: SessionOwnership.shared.localPeerId,
            peerPeerId: PairedPeerStore.shared.peer?.peerId ?? ""
        )

        PairLog.info("first meeting: local playing=\(meeting.localIsPlaying) desktop=\(localIsDesktop), peer playing=\(state.isPlaying) — \(meeting.localKeepsSession ? "keeping the session here" : "yielding to the peer")")
        if meeting.localKeepsSession { SessionOwnership.shared.claimLocally() }
    }

    private func apply(_ state: StateSnapshot) {
        guard !isStale(state) else { return }
        appliedEpoch = state.playbackEpoch
        appliedTrackLoadEpoch = state.trackLoadEpoch
        lastAppliedAt = Date()
        let previous = peerState
        peerState = state
        logTransition(from: previous, to: state)
        if let ownership = state.ownership {
            SessionOwnership.shared.adoptIfNewer(ownership)
        }
        // The two have just met, and the counters alone cannot settle it — both may have been
        // playing separately, each legitimately the owner of its own session, with neither record
        // newer than the other. See `settleFirstMeeting`.
        //
        // Tracked with a flag rather than `previous == nil`, because the last snapshot is now kept
        // when the peer goes away (it is what the "continue from…" offer is built from), so
        // `peerState` is no longer nil between connections.
        if !hasSettledWithPeer {
            hasSettledWithPeer = true
            settleFirstMeeting(with: state)
        }
        recomputeMirroring()
        enforceOwnership()
        // Once per snapshot, after ownership is settled: whether a press is still outstanding is
        // only meaningful once we know whether we are still the one waiting on it.
        if isMirroring { _ = settlePlayState(reported: state.isPlaying) }
    }

    private func recomputeMirroring() {
        let next = mirror.isMirroring
        guard next != isMirroring else { return }
        isMirroring = next
        // A press waiting on the old owner means nothing now, and neither does the answer it was
        // waiting for — the session on screen has changed underneath both.
        pendingPlayIntent = nil
        mirroredIsPlaying = next ? (peerState?.isPlaying ?? false) : false
        // An offer to "continue from…" the peer, while its session is right there on screen with
        // working controls, is a bar offering the thing directly beneath it — and accepting it
        // takes the session back using a checkpoint that may be minutes old.
        if next { PeerLink.shared.dismissResumeOffer() }
    }

    /// A device that does not own the session must not be holding one.
    ///
    /// The backstop for every path that moves ownership — a handoff this device sent, a "continue
    /// from…" the peer accepted, or a claim that simply arrived on a poll. Without it the loser of
    /// a claim keeps its queue and carries on playing, which is two sessions and two songs at
    /// once; and because it still has a `currentTrack`, it is exactly the state the old inferred
    /// rule could never recover from.
    private func enforceOwnership() {
        guard isMirroring, PlayerService.shared.currentTrack != nil else { return }
        PairLog.info("the peer owns the session now — releasing the one held here")
        PlayerService.shared.releaseSession()
    }

    // MARK: - Refusing to go backwards

    /// The newest `(playbackEpoch, trackLoadEpoch)` already applied, and when.
    private var appliedEpoch: Int?
    private var appliedTrackLoadEpoch: Int?
    private var lastAppliedAt: Date?
    private var seenServerInstanceId: String?

    /// How long with nothing applied before a snapshot is taken whatever its epoch says. Polls
    /// arrive at 1 Hz, so four seconds of silence means something is wrong with the ordering
    /// itself — and no ordering guard is worth a permanently frozen screen.
    private static let staleBypass: TimeInterval = 4

    /// Whether this snapshot describes a moment the mirror has already moved past.
    ///
    /// Snapshots do not arrive in order. The 1 Hz poll runs alongside the immediate `refresh()`
    /// chased after every command, so a poll issued *before* a press can land *after* the reply
    /// that reflects it — and applied unconditionally it puts the previous track back on screen
    /// and drags the epoch backwards, so everything sent for the next second is rejected by the
    /// owner as stale. This is the browser's `isStaleSnapshot`, which was written for exactly the
    /// same race against exactly the same counters.
    func isStale(_ state: StateSnapshot) -> Bool {
        // A relaunched peer restarts its counters at zero. Without noticing that, a mirror
        // holding a high epoch rejects everything it sends, forever — a screen that looks
        // perfectly healthy and never updates again.
        if seenServerInstanceId != state.serverInstanceId {
            seenServerInstanceId = state.serverInstanceId
            appliedEpoch = nil
            appliedTrackLoadEpoch = nil
            return false
        }
        if let lastAppliedAt, Date().timeIntervalSince(lastAppliedAt) > Self.staleBypass { return false }
        guard let appliedEpoch else { return false }
        if state.playbackEpoch > appliedEpoch { return false }
        if state.playbackEpoch < appliedEpoch { return true }
        // Same playback epoch: a lower load epoch is still from before the current track was
        // (re)started, which is the one change a videoId alone cannot show.
        guard let appliedTrackLoadEpoch else { return false }
        return state.trackLoadEpoch < appliedTrackLoadEpoch
    }

    /// Logs the things that change, and only when they change.
    ///
    /// The poll runs at 1 Hz, so logging a snapshot per tick buries everything; but a handoff that
    /// goes wrong is a sequence of *transitions*, and without them the log said only that the
    /// sound had ended up somewhere unexpected, never through which steps.
    private func logTransition(from previous: StateSnapshot?, to state: StateSnapshot) {
        guard let previous else {
            PairLog.info("peer state first seen: owner=\(state.sessionOwnerId?.prefix(8) ?? "none") playing=\(state.isPlaying) track=\(state.currentTrack?.title ?? "none")")
            return
        }
        if previous.sessionOwnerId != state.sessionOwnerId {
            PairLog.info("peer says the owner is now \(state.sessionOwnerId?.prefix(8) ?? "none") (claim \(state.sessionClaim ?? 0))")
        }
        if previous.isPlaying != state.isPlaying {
            PairLog.info("peer is now \(state.isPlaying ? "playing" : "paused") — epoch=\(state.playbackEpoch)")
        }
        if previous.currentTrack?.videoId != state.currentTrack?.videoId {
            PairLog.info("peer track: \(state.currentTrack?.title ?? "none")")
        }
    }

    // MARK: - Holding a press until the owner agrees

    /// What this device last asked playback to do, until the owner is seen doing it.
    ///
    /// Without it the glyph flips back for a tick after every press: the reply to a pause is
    /// chased by a poll, but a snapshot already in flight still says "playing", and applying it
    /// undoes what the user just did in front of them. The owner runs the mirror image of this
    /// for the browser (`PlayerService.pendingPlayIntent`); this is the remote's half.
    private var pendingPlayIntent: PendingPlayIntent?
    static let playIntentTimeout: TimeInterval = 5
    /// When to assume the request was simply lost and send it once more. A press that vanishes
    /// leaves audio running that the user has stopped, which is worse than a duplicate — and the
    /// command is absolute, so a duplicate changes nothing.
    static let playIntentRetry: TimeInterval = 2.5

    /// Settles what the transport should show, given what the owner has just reported.
    ///
    /// Called once per applied snapshot, and it is genuinely stateful: it expires the intent and
    /// can re-send the command. `now` is a parameter so the windows can be exercised without
    /// waiting them out in real time.
    ///
    /// Split out as a pure decision plus its effects for the same reason `PlaybackMirror` and
    /// `castLiveness` are values: the interesting cases are a command that never lands and one
    /// that lands late, and reaching either through two running apps and a network means waiting
    /// out real seconds for a decision made in microseconds.
    func settlePlayState(reported: Bool, now: Date = Date()) -> Bool {
        guard let intent = pendingPlayIntent else {
            mirroredIsPlaying = reported
            return reported
        }
        let decision = Self.resolveIntent(intent, reported: reported, now: now)
        pendingPlayIntent = decision.keep
        if decision.resend {
            PairLog.info("re-sending \(intent.playing ? "play" : "pause") — the owner never came round")
            deliver(PeerCommand(action: "setPlaying", playing: intent.playing))
        }
        mirroredIsPlaying = decision.shown
        return decision.shown
    }

    struct IntentDecision: Equatable {
        /// What the transport shows.
        var shown: Bool
        /// The intent to carry forward, or nil once it is settled or has expired.
        var keep: PendingPlayIntent?
        /// Whether to put the command on the wire once more.
        var resend: Bool
    }

    struct PendingPlayIntent: Equatable {
        var playing: Bool
        var at: Date
        var retried: Bool
    }

    static func resolveIntent(_ intent: PendingPlayIntent, reported: Bool, now: Date) -> IntentDecision {
        // The owner has come round. Nothing left to hold.
        if reported == intent.playing {
            return IntentDecision(shown: reported, keep: nil, resend: false)
        }
        let age = now.timeIntervalSince(intent.at)
        // Checked before the retry, so an intent that has already had its one retry expires
        // rather than sending a third.
        if age > playIntentTimeout {
            // The owner never agreed and the window is up. It is the one making the sound, so
            // believe it.
            return IntentDecision(shown: reported, keep: nil, resend: false)
        }
        if !intent.retried, age > playIntentRetry {
            // `at` is deliberately not carried forward changed — bumping it would push the expiry
            // back too, letting a stale intent outlive the window it was given.
            var retriedIntent = intent
            retriedIntent.retried = true
            return IntentDecision(shown: intent.playing, keep: retriedIntent, resend: true)
        }
        return IntentDecision(shown: intent.playing, keep: intent, resend: false)
    }

    // MARK: - SessionOwning

    /// Sends the intent to the device that owns the session, when that is not this one.
    ///
    /// Returns false — meaning "handle it locally" — whenever this device is the owner, or there
    /// is no reachable peer to send to. Every transport method on `PlayerService` opens with this,
    /// so the views, the lock screen and the web routes all route correctly without knowing that
    /// pairing exists.
    func relay(_ intent: PlayerService.PlaybackIntent) -> Bool {
        guard isMirroring else { return false }
        guard let command = command(for: intent) else { return false }
        deliver(command)
        return true
    }

    func claimSession() {
        SessionOwnership.shared.claimLocally()
        recomputeMirroring()
    }

    /// Asks the device holding the session to hand it over.
    ///
    /// The picker's "play here" row. There is no pull handshake: this tells the owner to run the
    /// push it already has, so the session arrives through the one acked path — capture, pause,
    /// send, and release only once this device has confirmed it took it.
    func requestSessionFromPeer() async {
        guard isMirroring else { return }
        do {
            try await PeerClient.send(PeerCommand(action: "pullSession"))
            // Its reply is only "I heard you"; the session arrives on `/api/peer/handoff` a moment
            // later. Poll straight away so the change shows without waiting out the tick.
            await refresh(force: true)
        } catch {
            PairLog.error("could not ask the peer for the session — \(error.localizedDescription)")
        }
    }

    /// Ownership just moved without a poll having told us — a handoff accepted here, or a resume
    /// offer taken. Recomputed straight away because until it is, this device goes on relaying its
    /// own presses to the device it has just taken the session *from*.
    func ownershipChangedLocally() {
        recomputeMirroring()
    }

    /// There is no paired device any more, so there is nothing to mirror and nothing to relay to.
    ///
    /// Idempotent, and that matters more than it looks. An unpaired device reaches this from the
    /// poll once a second, forever, and `@Published` sends on every *assignment* — not on every
    /// change — so writing the same nils back was republishing to every observer at 1 Hz. Rows
    /// observe this object to know which track the session is on, so an idle phone parked on a
    /// list was re-evaluating every visible row once a second for nothing.
    func forgetPeer() {
        guard peerState != nil || isPeerReachable || hasSettledWithPeer else { return }
        peerState = nil
        isPeerReachable = false
        hasSettledWithPeer = false
        appliedEpoch = nil
        appliedTrackLoadEpoch = nil
        seenServerInstanceId = nil
        recomputeMirroring()
    }

    /// The device that was making the sound has gone, so offer to pick it up here.
    ///
    /// Playback stops — deliberately, rather than this device starting to play on its own in a
    /// room nobody is in — but stopping silently with a blank screen is what made it feel broken.
    /// The last snapshot says exactly what was playing and where it had got to, which is all the
    /// existing "continue from…" bar needs.
    ///
    /// Only when the peer was the one playing. A peer that was merely idle when it went away has
    /// nothing worth continuing, and an offer to resume a paused song nobody asked for is noise.
    private func offerToContinueFromLastSeen() {
        guard let state = peerState, let track = state.currentTrack, state.isPlaying else { return }
        PairLog.info("peer vanished while playing \(track.title) — offering to continue here")
        PeerLink.shared.offerToContinue(from: state)
    }

    /// Turns an intent into the absolute instruction that goes on the wire.
    ///
    /// Toggles and bare "next"es are resolved *here*, against what is actually on screen, because
    /// this device's own player is empty while mirroring — negating its `isPlaying` would send
    /// "play" every single time. Resolving before sending is also what makes the command safe to
    /// arrive twice.
    private func command(for intent: PlayerService.PlaybackIntent) -> PeerCommand? {
        switch intent {
        case let .play(track, context, contextTitle, contextSeed):
            return PeerCommand(
                action: "play",
                track: track,
                context: context,
                contextTitle: contextTitle,
                contextSeed: contextSeed
            )
        case let .setPlaying(playing):
            noteIntent(playing)
            return PeerCommand(action: "setPlaying", playing: playing)
        case .togglePlaying:
            let playing = !displayedIsPlaying
            noteIntent(playing)
            return PeerCommand(action: "setPlaying", playing: playing)
        case let .next(from):
            return PeerCommand(action: "next", videoId: from ?? displayedTrack?.videoId)
        case .previous:
            return PeerCommand(action: "previous")
        case let .seek(seconds):
            return PeerCommand(action: "seek", seconds: seconds)
        case .toggleShuffle:
            return PeerCommand(action: "shuffle")
        case let .skipTo(videoId):
            return PeerCommand(action: "skipTo", videoId: videoId)
        case let .removeFromQueue(videoId):
            return PeerCommand(action: "removeFromQueue", videoId: videoId)
        case let .addToQueue(track):
            return PeerCommand(action: "addToQueue", track: track)
        case let .playNext(track):
            return PeerCommand(action: "playNext", track: track)
        case let .setVolume(value):
            return PeerCommand(action: "volume", value: value)
        case let .moveInQueue(origin, from, to, track):
            // The track is resolved here when the caller could not supply it: on a mirror
            // `PlayerService`'s own queues are empty, so the row that was dragged only exists in
            // the displayed one. The owner uses it to find the row again if the index has moved.
            let displayed = origin == .manual ? displayedManualQueue : displayedContextQueue
            let moved = track ?? (displayed.indices.contains(from) ? displayed[from] : nil)
            // `to` is SwiftUI's pre-removal offset, so the row standing at it in the queue as
            // drawn is precisely the one the drop should land in front of. Naming it is what
            // lets the owner honour the drop after consuming a track while the request was in
            // flight — the correction the route could not make from `to` alone, having no way
            // to tell a stale index from a deliberate one. `relayed()` runs before any local
            // mutation, and on a mirror there is none at all, so `displayed` here is exactly
            // the pre-move array the drag was measured against.
            return PeerCommand(
                action: "moveInQueue",
                videoId: moved?.videoId,
                queue: origin.rawValue,
                fromIndex: from,
                toIndex: to,
                anchorVideoId: displayed.indices.contains(to) ? displayed[to].videoId : nil,
                dropsAtQueueEnd: to >= displayed.count
            )
        }
    }

    private func noteIntent(_ playing: Bool) {
        pendingPlayIntent = PendingPlayIntent(playing: playing, at: Date(), retried: false)
        // Shown immediately, so the glyph follows the press rather than the next poll. The owner
        // is still the authority — its snapshot is what settles this a moment later.
        mirroredIsPlaying = playing
    }

    private func deliver(_ command: PeerCommand) {
        Task {
            do {
                try await PeerClient.send(command)
                // Pull straight away rather than waiting up to a second, so a press feels
                // immediate instead of laggy.
                await refresh(force: true)
            } catch {
                PairLog.error("command \(command.action) to peer failed: \(error.localizedDescription)")
            }
        }
    }
}
