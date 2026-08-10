import Foundation

/// What the initiating device sends to the device whose code was typed.
struct PairRequest: Codable {
    var peerId: String
    var name: String
    var isDesktop: Bool
    /// Raw X25519 public key, base64. The private half never leaves the device.
    var publicKey: String
    /// HMAC over the above, keyed by the six digits. This is what proves the sender can see the
    /// recipient's screen — the code itself is never transmitted, so watching the exchange
    /// yields neither the code nor the session key.
    var proof: String
}

struct PairResponse: Codable {
    var peerId: String
    var name: String
    var isDesktop: Bool
    var publicKey: String
    var proof: String
}

/// Where the peer is in its current track, and everything needed to carry on from it.
///
/// The queue and the radio seed travel with it deliberately: without the seed a handed-over
/// radio arrives as a loose list of songs with no station behind it, and without the unshuffled
/// order turning shuffle off afterwards could not restore the real one.
struct NowPlayingCheckpoint: Codable, Equatable {
    var peerId: String
    var isDesktop: Bool
    var updatedAt: Date

    var currentTrack: Track?
    var progress: Double
    var isPlaying: Bool
    var manualQueue: [Track]
    var contextQueue: [Track]
    var orderedContextQueue: [Track]
    var isShuffling: Bool
    var queueContextTitle: String?
    /// The track a radio was generated from, when the context is a radio.
    var contextSeed: Track?

    /// Which of two checkpoints should be offered as "continue from…".
    ///
    /// The device actually making sound wins, not the one that wrote most recently — a phone
    /// paused thirty seconds ago should not override a Mac that is mid-song. The desktop breaks
    /// a tie when both are playing.
    static func preferred(_ lhs: NowPlayingCheckpoint, _ rhs: NowPlayingCheckpoint) -> NowPlayingCheckpoint {
        if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying ? lhs : rhs }
        if lhs.isPlaying, lhs.isDesktop != rhs.isDesktop { return lhs.isDesktop ? lhs : rhs }
        return lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
    }
}

/// A request to take over playback. The receiver resolves its own stream URL — it has its own
/// `InnerTubeClient` — so none of the browser-casting machinery (banked URLs, `/api/stream`,
/// stream-failed re-resolution) is involved in a peer handoff.
struct HandoffRequest: Codable {
    var checkpoint: NowPlayingCheckpoint
    /// Whether the sender has already stopped. It pauses itself before sending, so both devices
    /// are never audible at once — which is also why the receiver must autoplay from
    /// `checkpoint.isPlaying` (captured *before* that pause) rather than from what the sender
    /// looks like by the time this arrives.
    var senderPaused: Bool
    /// What the sender believes about ownership right now.
    ///
    /// Carried so the receiver can claim strictly above it. A receiver that has been away holds a
    /// stale counter, and claiming above only its own could land at or below the sender's — which
    /// the sender would then resolve in its own favour, keeping the session it had just given
    /// away while the receiver played on. Both devices owning it is the one state that must be
    /// unreachable.
    var senderClaim: OwnershipClaim?
}

/// The receiver's answer to a handoff.
///
/// The reply used to be a bare `"ok"`, so the sender paused itself and hoped. Nothing told it
/// whether the other device had actually started, and nothing could tell it when it was safe to
/// let the session go — so it never did, and kept a queue that made it a second owner forever.
struct HandoffAck: Codable {
    var accepted: Bool
    /// Who owns the session now, as the receiver sees it. The sender concedes to this verbatim.
    var ownership: OwnershipClaim
}

/// A transport instruction sent to the device that owns the session.
///
/// One shape for every action rather than a route each: these arrive from the other device's
/// buttons, and the set is small and closed.
struct PeerCommand: Codable {
    var action: String
    var seconds: Double?
    var value: Double?
    var videoId: String?
    /// Absolute play/pause. A toggle is resolved against what the sender had on screen *before*
    /// it leaves, so a command that arrives twice — or arrives after the owner has already
    /// changed state — is a no-op instead of flipping playback back.
    var playing: Bool?
    /// For `"play"`, `"addToQueue"` and `"playNext"`, which name a track the owner may not have.
    /// Everything else addresses tracks by `videoId`, because the owner holds the authoritative
    /// copy of every field and echoing it back only invites the two to disagree.
    var track: Track?
    var context: [Track]?
    var contextTitle: String?
    var contextSeed: Track?
    /// Which of the two queues a reorder applies to — "manual" or "context".
    var queue: String?
    var fromIndex: Int?
    var toIndex: Int?
    /// Which row the dragged one should end up in front of.
    ///
    /// The indices above describe the sender's copy of the queue, and the owner's advances at
    /// every track boundary — naming the row survives that, an index does not. Optional for the
    /// reason every field here is: the two apps are built and installed separately, so a peer on
    /// yesterday's build sends neither of these and still has to be understood. See `QueueMove`.
    var anchorVideoId: String?
    /// True when the row was dropped past the last one. Nil rather than false from an older peer,
    /// which is what keeps the indices the fallback for one — "the end of the queue" and "did not
    /// say" want opposite answers, and a bare `false` cannot tell them apart.
    var dropsAtQueueEnd: Bool?
}

// There is no peer progress report. It existed while a paired device could act as the other's
// speaker — holding the audio output, pushing its position back, and vouching for its own liveness
// because it has no WebSocket for `castLiveness` to judge. The session moves whole now, so a
// mirror never makes a sound and has no position of its own to report. The browser's own
// `/api/playback/report` is untouched; it still needs every bit of that.
