import Foundation

/// Which of the two devices owns the session, and therefore what the transport shows and acts on.
///
/// A value type rather than logic inside `PeerPlayback` so the rules can be exercised without two
/// running apps, a network, or any audio — the same reason the merge rules were pulled out of the
/// stores. Getting this wrong is not a crash, it is a bar that shows the wrong song or a pause
/// button that pauses the wrong device, which is exactly the sort of thing a test catches and a
/// glance does not.
struct PlaybackMirror {
    /// The paired device's id, or nil when there is no paired device.
    var pairedPeerId: String?
    /// Whether it answered the last poll. An unreachable owner cannot be driven, so a device that
    /// cannot see its peer falls back to acting on itself.
    var isPeerReachable: Bool
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

    /// True when the peer holds the session and this device should mirror it.
    ///
    /// The rule used to be "the peer has something and we don't", which reads well and is wrong
    /// the moment both devices have ever played anything — which is permanently, after the first
    /// handoff. Ownership is a fact now, exchanged in the state snapshot.
    ///
    /// Note it asks whether the owner is *the paired device*, not merely whether it is somebody
    /// other than this one. Ownership is persisted, so unpairing and pairing with a different
    /// device leaves a record naming a peer that is no longer there — and "not me" would then be
    /// true on both ends at once, which is the one arrangement in which a single press relays
    /// back and forth between the two apps without ever being acted on.
    var isMirroring: Bool {
        guard let pairedPeerId, isPeerReachable, ownerHasSession else { return false }
        return ownerPeerId == pairedPeerId && ownerPeerId != localPeerId
    }

}

/// Which device keeps its session when the two meet and both already have one.
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
