import Foundation

/// Which device in the group owns the session, and therefore what the transport shows and acts on.
///
/// A value type rather than logic inside `PeerPlayback` so the rules can be exercised without
/// several running apps, a network, or any audio — the same reason the merge rules were pulled
/// out of the stores. Getting this wrong is not a crash, it is a bar that shows the wrong song or
/// a pause button that pauses the wrong device, which is exactly the sort of thing a test catches
/// and a glance does not.
struct PlaybackMirror {
    /// The ids of every device this one is paired with.
    var pairedPeerIds: Set<String>
    /// Which of them answered their last poll. An unreachable owner cannot be driven, so a device
    /// that cannot see the owner falls back to acting on itself.
    var reachablePeerIds: Set<String>
    /// Who owns the session — see `OwnershipClaim`.
    var ownerPeerId: String
    /// This device's own id.
    var localPeerId: String
    /// Whether the named owner actually has something to be the owner *of*.
    ///
    /// Ownership is persisted; a player is not. So quitting and reopening the owning app — logging
    /// out, rebooting, closing it at night — reloads a claim naming a device whose queue is now
    /// empty. Without this the other device went on mirroring it: its transport bar is keyed on
    /// `displayedTrack`, which is the owner's nil, so the bar vanished, and with it the only route
    /// to Now Playing and therefore to the device picker. Every press was relayed to a device
    /// playing nothing, and the phone in your hand could not play a note.
    ///
    /// The same shape as `OwnershipClaim.isUnclaimed`: a claim to a session that does not exist is
    /// not a claim.
    var ownerHasSession: Bool = true

    /// A link with exactly one other device — what every caller was before groups.
    init(
        pairedPeerId: String?,
        isPeerReachable: Bool,
        ownerPeerId: String,
        localPeerId: String,
        ownerHasSession: Bool = true
    ) {
        let paired: Set<String> = pairedPeerId.map { [$0] } ?? []
        self.init(
            pairedPeerIds: paired,
            reachablePeerIds: isPeerReachable ? paired : [],
            ownerPeerId: ownerPeerId,
            localPeerId: localPeerId,
            ownerHasSession: ownerHasSession
        )
    }

    init(
        pairedPeerIds: Set<String>,
        reachablePeerIds: Set<String>,
        ownerPeerId: String,
        localPeerId: String,
        ownerHasSession: Bool = true
    ) {
        self.pairedPeerIds = pairedPeerIds
        self.reachablePeerIds = reachablePeerIds
        self.ownerPeerId = ownerPeerId
        self.localPeerId = localPeerId
        self.ownerHasSession = ownerHasSession
    }

    /// True when another device holds the session and this one should mirror it.
    ///
    /// The rule used to be "the peer has something and we don't", which reads well and is wrong
    /// the moment both devices have ever played anything — which is permanently, after the first
    /// handoff. Ownership is a fact now, exchanged in the state snapshot.
    ///
    /// Note it asks whether the owner is *a paired device*, not merely whether it is somebody
    /// other than this one. Ownership is persisted, so removing a device from the group leaves a
    /// record naming a peer that is no longer there — and "not me" would then be true on both
    /// ends at once, which is the one arrangement in which a single press relays back and forth
    /// between two apps without ever being acted on.
    var isMirroring: Bool {
        guard ownerPeerId != localPeerId,
              pairedPeerIds.contains(ownerPeerId),
              reachablePeerIds.contains(ownerPeerId),
              ownerHasSession else { return false }
        return true
    }
}

/// Which device keeps its session when two meet and both already have one.
///
/// The claim counters cannot answer this. Both devices may have been playing separately, each the
/// legitimate owner of its own session, having claimed while it had never heard of the other —
/// so neither record is newer in any meaningful sense.
///
/// A value type, and the same reason as `PlaybackMirror`: the interesting cases are two devices
/// in states that are awkward to arrange for real (both playing, both paused, one of each), and
/// the cost of getting it wrong is music stopping mid-song on the device someone is listening to.
///
/// The rule must be *symmetric*: both devices evaluate it independently, on their own view of the
/// same two facts, and they must not both conclude they won. Each clause below is therefore an
/// antisymmetric comparison, never a preference for "me".
struct FirstMeeting {
    var localIsPlaying: Bool
    var peerIsPlaying: Bool
    var localIsDesktop: Bool
    var peerIsDesktop: Bool
    var localPeerId: String
    var peerPeerId: String

    var localKeepsSession: Bool {
        // The device actually making sound wins. Interrupting it to resume something that was
        // paused is the one outcome nobody wants.
        if localIsPlaying != peerIsPlaying { return localIsPlaying }
        // Both playing, or both paused: the desktop takes it. It is the device you are sat in
        // front of, and the one whose session you can see.
        if localIsDesktop != peerIsDesktop { return localIsDesktop }
        // Two devices of the same kind — two Macs, or a phone paired to a phone. Any answer will
        // do provided it is the *same* answer on both, and ids sort oppositely from either side.
        return localPeerId > peerPeerId
    }
}

/// What a device holding a session should do on meeting a peer that has none of its own.
///
/// Before groups this was "claim, so the peer's stale record is overruled" — the peer was the
/// only other device there was. With three, the peer in front of you being empty says nothing
/// about the *owner*, which may be a third device playing right now: claiming on the strength of
/// an empty mirror would take the session from it, and the owner would then stop mid-song when
/// it saw the higher claim. So the claim is made only when the recorded owner is this device or
/// is known not to have a session to defend — and is otherwise left to the meeting with the
/// owner itself, which `FirstMeeting` settles properly.
struct EmptyPeerMeeting {
    var ownerPeerId: String
    var localPeerId: String
    /// Whether the recorded owner holds a session, or nil unless it is answering this device
    /// right now.
    ///
    /// Unreachable is deliberately as good as unknown. With two devices the owner being out of
    /// reach meant it was out of everyone's reach; with three it may be playing for the one in
    /// the next room, which would take a claim made here as the user's and stop.
    var ownerHasSession: Bool?
    /// Whether the recorded owner is a device this one is paired with.
    var ownerIsPaired: Bool
    /// Whether a higher claim than this device's own has been seen and *not* adopted — one
    /// heard second-hand while this device held a session (see `PeerPlayback.adopt`).
    ///
    /// That claim's owner is a device this one has not met yet on this connection, and it may be
    /// playing. Renewing over it here would put this device above a session it never weighed
    /// itself against: the owner, already settled with this device, would then adopt the higher
    /// claim on its next poll and stop mid-song for a session that was only paused.
    var higherClaimSeen: Bool = false

    var claims: Bool {
        if ownerPeerId == localPeerId { return !higherClaimSeen }
        // A record naming a device that is not in the group protects nobody.
        guard ownerIsPaired else { return true }
        // Not heard from yet: its own meeting decides, when it answers.
        guard let ownerHasSession else { return false }
        return !ownerHasSession
    }
}
