import XCTest
@testable import VVDemus

/// Who owns the session, and therefore which device a button press reaches.
///
/// Cheap to get subtly wrong and expensive to notice: the failure is a transport bar showing the
/// wrong song, or pause acting on the wrong device — neither of which throws, crashes, or looks
/// broken in a screenshot. The rule lives in a value type so it can be pinned down here, with no
/// second app, no network and no audio, which is the only reason the awkward combinations below
/// are cheap enough to cover at all.
@MainActor
final class PlaybackMirrorTests: XCTestCase {
    private let local = PeerFixtures.localPeer
    private let remote = PeerFixtures.remotePeer

    private func mirror(
        owner: String,
        paired: Bool = true,
        pairedWith: String? = nil,
        reachable: Bool = true,
        ownerHasSession: Bool = true
    ) -> PlaybackMirror {
        PlaybackMirror(
            pairedPeerId: paired ? (pairedWith ?? remote) : nil,
            isPeerReachable: reachable,
            ownerPeerId: owner,
            localPeerId: local,
            ownerHasSession: ownerHasSession
        )
    }

    /// The owner quit and reopened its app.
    ///
    /// Ownership is persisted; a player is not — so the relaunched owner reloads a claim naming
    /// itself and an empty queue. Mirroring it hid this device's transport bar (it is keyed on the
    /// owner's now-nil track), and with the bar went the only route to Now Playing and therefore
    /// to the device picker. Every press was relayed to a device playing nothing, and the phone in
    /// your hand could not play a note or get the session back. A claim to a session that does not
    /// exist is not a claim — the same rule `OwnershipClaim.isUnclaimed` applies at claim 0.
    func testNeverMirrorsAnOwnerWithNothingToPlay() {
        let restartedOwner = mirror(owner: remote, ownerHasSession: false)
        XCTAssertFalse(restartedOwner.isMirroring, "there is nothing to mirror, and mirroring it strands this device")
    }

    // MARK: - The rule

    func testTheNonOwnerMirrors() {
        let peerOwns = mirror(owner: remote)
        XCTAssertTrue(peerOwns.isMirroring)
    }

    func testTheOwnerDoesNotMirror() {
        let weOwn = mirror(owner: local)
        XCTAssertFalse(weOwn.isMirroring, "the owner *is* the session — there is nothing to mirror")
    }

    /// The case the old rule got wrong, and the whole reason ownership is now stated rather than
    /// inferred.
    ///
    /// The predicate used to be "the peer has something and this device does not". Both devices
    /// hold a track the moment either has ever played anything, and permanently after a handoff —
    /// the device that gave the session away still had one loaded. So the predicate was false on
    /// both sides at once: neither mirrored, pause reached only the device it was pressed on, and
    /// handing back was impossible. Here both players are non-empty and the non-owner still
    /// mirrors, because what a player happens to contain is no longer part of the question.
    func testMirrorsEvenWhenBothDevicesStillHoldATrack() throws {
        let peerState = PeerFixtures.snapshot(
            currentTrack: PeerFixtures.track("peer-song"),
            sessionOwnerId: remote
        )
        let stillLoadedHere: Track? = PeerFixtures.track("local-song")

        // The old rule, spelled out rather than described, so the difference is visible.
        let oldRuleWouldMirror = peerState.currentTrack != nil && stillLoadedHere == nil
        XCTAssertFalse(oldRuleWouldMirror, "both players hold a track, which is what used to switch mirroring off for good")

        let owner = try XCTUnwrap(peerState.ownership?.ownerPeerId, "the owner rides on the snapshot")
        let peerOwns = PlaybackMirror(
            pairedPeerId: remote,
            isPeerReachable: true,
            ownerPeerId: owner,
            localPeerId: local
        )

        XCTAssertTrue(peerOwns.isMirroring, "ownership is a fact on the wire; a non-empty local player no longer hides it")
    }

    // MARK: - When there is nobody to mirror

    func testNeverMirrorsAnUnreachablePeer() {
        let awayPeerOwns = mirror(owner: remote, reachable: false)
        XCTAssertFalse(awayPeerOwns.isMirroring, "an owner that did not answer the last poll cannot be driven")
    }

    /// Ownership outlives a pairing: it is persisted, and unpairing does not rewrite it. A device
    /// that mirrored a peer it no longer has would show an empty transport and swallow every press
    /// forever, so pairing is checked separately from who the record names.
    func testNeverMirrorsWhenUnpaired() {
        let staleRecord = mirror(owner: remote, paired: false)
        XCTAssertFalse(staleRecord.isMirroring)
    }

    /// Ownership naming a device that is not the one paired with now.
    ///
    /// Reachable by unpairing and pairing with something else: the record is persisted and the
    /// pairing is not part of it. "The owner is not me" would be true on *both* devices at once,
    /// so each would relay every press to the other and a single tap would cross the network
    /// forever without either ever playing it.
    func testNeverMirrorsAnOwnerThatIsNotThePairedDevice() {
        let strangerOwns = mirror(owner: "peer-from-a-previous-pairing")
        XCTAssertFalse(strangerOwns.isMirroring, "there is nobody to relay to — the named owner is not the paired device")
    }

    /// Each condition catches a different failure, and dropping any one of them still passes some
    /// of the cases above — so the table is written out in full.
    func testOnlyAPairedReachablePeerOwnerMirrors() {
        let stranger = "peer-stranger"
        var mirroring: [String] = []
        for paired in [true, false] {
            for reachable in [true, false] {
                for owner in [local, remote, stranger] {
                    let candidate = mirror(owner: owner, paired: paired, reachable: reachable)
                    if candidate.isMirroring {
                        mirroring.append("paired=\(paired) reachable=\(reachable) owner=\(owner)")
                    }
                }
            }
        }
        XCTAssertEqual(mirroring, ["paired=true reachable=true owner=\(remote)"])
    }

    // MARK: - Across a handoff

    /// The round trip, driven through the real ownership record: give the session away, take it
    /// back. This is what the inferred rule could not complete, because after the first leg both
    /// devices held a track and mirroring could never turn on to relay the press that would return
    /// it.
    func testHandingOverAndBackFlipsTheMirrorBothWays() {
        // Named rather than left to the fixture's UUID so it can be removed again: a defaults
        // suite is a real plist in the test process's container.
        let suite = "PlaybackMirrorTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let ownership = PeerFixtures.ownership(localPeerId: local, suite: suite)

        func now() -> PlaybackMirror {
            PlaybackMirror(
                pairedPeerId: remote,
                isPeerReachable: true,
                ownerPeerId: ownership.current.ownerPeerId,
                localPeerId: ownership.localPeerId
            )
        }

        XCTAssertFalse(now().isMirroring, "nothing has moved yet, so this device still owns what it plays")

        let taken = OwnershipClaim(ownerPeerId: remote, claim: 4)
        ownership.concede(to: taken)
        XCTAssertTrue(now().isMirroring)

        ownership.claimFromHandoff(supersedingSenderClaim: taken)
        XCTAssertFalse(now().isMirroring, "taking the session back must put the transport on this device again")
    }
}
