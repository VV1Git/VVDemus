import Foundation

/// Who owns the session — the device holding the queue, deciding what plays next, and making the
/// sound. The other device mirrors it and sends it commands.
///
/// Ownership used to be *inferred*: "the peer has a track and we don't". That is only ever true
/// before the mirroring device has played anything, and after a handoff both devices held a track
/// — so neither mirrored, permanently. Every cross-device behaviour was gated on a predicate that
/// could never become true again, which is why the two showed different songs, pause reached only
/// the device it was pressed on, and handing over was a one-way trip.
///
/// So it is named rather than guessed, and ordered by a counter rather than a clock. The objection
/// the old code raised — that anything cleverer needs the two devices to agree about time — is an
/// objection to *timestamps*. A monotonic claim with a deterministic tiebreak needs no such
/// agreement, and it is exactly how `EditStamp` already orders library edits between the same two
/// devices.
struct OwnershipClaim: Codable, Equatable {
    var ownerPeerId: String
    /// Monotonic across *both* devices, not just this one: adopting the peer's claim carries its
    /// value over, so the next claim made anywhere is higher than anything either side has seen.
    var claim: Int

    /// Claim zero means *nobody has started anything*, which is not a claim at all.
    ///
    /// Both devices hold one on a fresh install, and letting the tiebreak below pick a winner
    /// there hands the session to whichever peer id sorts higher — an idle device becoming the
    /// owner of a session that does not exist. The other device then mirrors it, so the first
    /// press goes over the network to a device with nothing to play, and if anything *was*
    /// already playing here `enforceOwnership` would stop it mid-song.
    var isUnclaimed: Bool { claim == 0 }

    /// Which of two claims wins.
    ///
    /// Ties break on the peer id rather than on arrival order. Two devices that claim in the same
    /// round otherwise each prefer their own and never converge — both would think they owned the
    /// session, which is the one state this whole type exists to make impossible.
    static func resolve(local: OwnershipClaim, remote: OwnershipClaim) -> OwnershipClaim {
        // An unclaimed record never takes ownership from anyone, including from another
        // unclaimed one — see `isUnclaimed`.
        if remote.isUnclaimed { return local }
        if remote.claim > local.claim { return remote }
        if remote.claim == local.claim, remote.ownerPeerId > local.ownerPeerId { return remote }
        return local
    }
}

@MainActor
final class SessionOwnership: ObservableObject {
    static let shared = SessionOwnership()

    @Published private(set) var current: OwnershipClaim

    private let defaults: UserDefaults
    let localPeerId: String

    private static let ownerKey = "session_owner_peer_id_v1"
    private static let claimKey = "session_owner_claim_v1"

    private convenience init() {
        self.init(defaults: .standard, localPeerId: PeerIdentity.shared.peerId)
    }

    /// Injectable so the rules can be exercised without touching the app's real defaults — the
    /// same reason `PlayerService` takes a `UserDefaults`.
    init(defaults: UserDefaults, localPeerId: String) {
        self.defaults = defaults
        self.localPeerId = localPeerId
        // Owning it is the default. A device that has never handed anything over — including one
        // that has never been paired — is the only device there is.
        current = OwnershipClaim(
            ownerPeerId: defaults.string(forKey: Self.ownerKey) ?? localPeerId,
            claim: defaults.integer(forKey: Self.claimKey)
        )
    }

    var isOwnedLocally: Bool { current.ownerPeerId == localPeerId }

    /// The highest claim the peer has been seen holding, whether or not it won.
    ///
    /// Kept because a claim has to beat the peer's, and the peer's is only ever learned from a
    /// poll. Without it a device that owns the session at claim 3 while the peer sits at claim 7
    /// would claim 4 on its next play and lose — quietly handing its own music to the other side.
    private(set) var lastSeenPeerClaim = 0

    /// This device started playing something of its own, so it owns the session.
    ///
    /// Skipped only when this device already owns it *and* its claim already beats anything the
    /// peer has shown — bumping on every track start would inflate the counter and republish to
    /// every observing view for no benefit. The `<=` is doing real work: on a fresh pair both
    /// devices sit at claim 0, so the first play here must still move to 1 or the peer's own
    /// zero remains its equal.
    func claimLocally() {
        guard !isOwnedLocally || current.claim <= lastSeenPeerClaim else { return }
        apply(OwnershipClaim(ownerPeerId: localPeerId, claim: max(current.claim, lastSeenPeerClaim) + 1))
    }

    /// Takes the session as the receiving half of a handoff.
    ///
    /// Claims above the *sender's* counter as well as this device's own. A receiver that has been
    /// away has a stale counter, and `current.claim + 1` could land at or below what the sender
    /// already holds — so the sender would resolve the ack in its own favour and keep the session
    /// it had just given away, leaving both devices believing they owned it.
    func claimFromHandoff(supersedingSenderClaim sender: OwnershipClaim?) {
        let ceiling = max(current.claim, sender?.claim ?? 0)
        apply(OwnershipClaim(ownerPeerId: localPeerId, claim: ceiling + 1))
    }

    /// Accepts the peer's view of who owns the session when it is newer than this one's.
    ///
    /// Records the peer's counter either way, including when it loses: `claimLocally` needs to
    /// know what it has to beat, and a claim that lost is still evidence of how high the other
    /// side has counted.
    func adoptIfNewer(_ remote: OwnershipClaim) {
        lastSeenPeerClaim = max(lastSeenPeerClaim, remote.claim)
        apply(OwnershipClaim.resolve(local: current, remote: remote))
    }

    /// Hands the session over, having been told by the peer that it has taken it.
    ///
    /// Deliberately not `adoptIfNewer`: the peer has already adopted the checkpoint and is
    /// playing, so its claim is the truth even in a tie the resolver would award to this device.
    func concede(to remote: OwnershipClaim) {
        apply(remote)
    }

    /// The peer is gone for good, so there is nobody to mirror and nobody to hand back to.
    func resetToLocal() {
        apply(OwnershipClaim(ownerPeerId: localPeerId, claim: current.claim + 1))
    }

    private func apply(_ next: OwnershipClaim) {
        guard next != current else { return }
        current = next
        defaults.set(next.ownerPeerId, forKey: Self.ownerKey)
        defaults.set(next.claim, forKey: Self.claimKey)
        PairLog.info("session owner -> \(next.ownerPeerId == localPeerId ? "this device" : next.ownerPeerId) (claim \(next.claim))")
    }
}
