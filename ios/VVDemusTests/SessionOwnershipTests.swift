import XCTest
@testable import VVDemus

/// Which device owns the session, and how the two settle it without a shared clock.
///
/// The failure has no symptom where it happens: two devices come away each believing it owns the
/// session, and what the user sees later is two queues playing at once and presses that land
/// nowhere. Whether that can happen is a pure question about two claims and a resolver, so it is
/// answered here rather than by running two apps and hoping the race shows up.
@MainActor
final class SessionOwnershipTests: XCTestCase {
    private let local = PeerFixtures.localPeer
    private let remote = PeerFixtures.remotePeer

    /// Every defaults suite this file invents, so `tearDown` can remove it.
    ///
    /// `UserDefaults(suiteName:)` writes a real plist into the test process's container — the same
    /// reason `PlayerHarness` cleans up after itself — and a per-test UUID suite would otherwise
    /// leave one behind on every run.
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        suites = []
        try await super.tearDown()
    }

    private func makeOwnership(
        localPeerId: String = PeerFixtures.localPeer,
        suite: String? = nil
    ) -> SessionOwnership {
        let name = suite ?? "SessionOwnershipTests.\(UUID().uuidString)"
        if !suites.contains(name) { suites.append(name) }
        return PeerFixtures.ownership(localPeerId: localPeerId, suite: name)
    }

    // MARK: - Resolving two claims

    func testTheHigherClaimWins() {
        let older = OwnershipClaim(ownerPeerId: "peer-aaa", claim: 3)
        let newer = OwnershipClaim(ownerPeerId: "peer-zzz", claim: 4)

        XCTAssertEqual(OwnershipClaim.resolve(local: older, remote: newer), newer)
        XCTAssertEqual(OwnershipClaim.resolve(local: newer, remote: older), newer, "which side received which must not decide it")
    }

    /// Both devices claiming in the same round is what the tiebreak is for, and both directions
    /// are asserted because agreeing is the entire point. A tiebreak that let each side keep its
    /// own claim would never converge: both would go on owning the session, which is the one state
    /// this type exists to rule out.
    func testEqualClaimsBreakOnTheGreaterPeerIdInBothDirections() {
        let lower = OwnershipClaim(ownerPeerId: "peer-aaa", claim: 7)
        let higher = OwnershipClaim(ownerPeerId: "peer-zzz", claim: 7)

        XCTAssertEqual(OwnershipClaim.resolve(local: lower, remote: higher), higher)
        XCTAssertEqual(OwnershipClaim.resolve(local: higher, remote: lower), higher, "both devices must name the same winner")
    }

    // MARK: - Claiming by playing something

    func testADeviceWithNoRecordOwnsItsOwnSession() {
        let ownership = makeOwnership()
        XCTAssertTrue(ownership.isOwnedLocally, "a device that has never handed anything over is the only device there is")
        XCTAssertEqual(ownership.current.claim, 0)
    }

    /// `claimLocally()` runs at the start of anything this device plays, so it must not renumber
    /// the session once a track — that would inflate the counter and republish to every observing
    /// view for nothing.
    ///
    /// But the very first claim is not a renumbering, and skipping it was a real bug. Both devices
    /// sit at claim 0 on a fresh pair, and claim 0 is unclaimed: staying there leaves the idle
    /// peer's zero an exact equal of this device's, and `resolve`'s peerId tiebreak then hands the
    /// session to whichever id sorts higher. The device actually playing would become the mirror,
    /// and `enforceOwnership` would release the session out from under the music.
    func testTheFirstClaimMovesOffZeroAndLaterOnesDoNot() {
        let ownership = makeOwnership()
        XCTAssertTrue(ownership.current.isUnclaimed, "a device that has never played anything holds no claim")

        ownership.claimLocally()
        let afterFirst = ownership.current
        XCTAssertFalse(afterFirst.isUnclaimed, "starting playback here is a claim, and an unclaimed record cannot win one")
        XCTAssertTrue(ownership.isOwnedLocally)

        ownership.claimLocally()
        ownership.claimLocally()
        XCTAssertEqual(ownership.current, afterFirst, "the owner must not renumber the session at the start of every track")
    }

    /// The sequence the bug above actually broke, end to end.
    func testAnIdlePeerNeverTakesTheSessionFromTheDeviceThatIsPlaying() {
        let ownership = makeOwnership()
        // This device starts playing; the peer has never played anything, so it still reports the
        // unclaimed record every device ships with.
        ownership.claimLocally()
        let idlePeer = OwnershipClaim(ownerPeerId: remote, claim: 0)

        ownership.adoptIfNewer(idlePeer)

        XCTAssertTrue(ownership.isOwnedLocally, "an idle device must not take a session that is playing here")
    }

    /// And the same guarantee before either has played: neither becomes the other's mirror, so a
    /// press on either device plays there rather than being relayed to a device with nothing.
    func testTwoUnclaimedDevicesBothKeepThemselves() {
        let ownership = makeOwnership()
        ownership.adoptIfNewer(OwnershipClaim(ownerPeerId: remote, claim: 0))
        XCTAssertTrue(ownership.isOwnedLocally)

        // Whichever way the peer ids happen to sort.
        let higherId = makeOwnership(localPeerId: "aaa-sorts-below-everything")
        higherId.adoptIfNewer(OwnershipClaim(ownerPeerId: "zzz-sorts-above-everything", claim: 0))
        XCTAssertTrue(higherId.isOwnedLocally, "the tiebreak must not fire between two records that are not claims")
    }

    func testClaimingLocallyTakesTheSessionBackWithAHigherClaim() {
        let ownership = makeOwnership()
        let peerHeldIt = OwnershipClaim(ownerPeerId: remote, claim: 6)
        ownership.adoptIfNewer(peerHeldIt)
        XCTAssertFalse(ownership.isOwnedLocally)

        ownership.claimLocally()

        XCTAssertTrue(ownership.isOwnedLocally)
        XCTAssertGreaterThan(ownership.current.claim, peerHeldIt.claim)
        XCTAssertEqual(
            OwnershipClaim.resolve(local: peerHeldIt, remote: ownership.current),
            ownership.current,
            "the peer must resolve the next poll in the claimer's favour, or it keeps playing too"
        )
    }

    // MARK: - Taking the session as the receiving half of a handoff

    /// The case `claimFromHandoff` exists for. A receiver that has been away carries a stale
    /// counter, so `current.claim + 1` can land at or below the number the sender already holds —
    /// and then the sender resolves the ack in its own favour, keeps the session it just gave
    /// away, and both devices believe they own it.
    func testHandoffClaimsAboveTheSendersEvenFromAStaleCounter() {
        let ownership = makeOwnership()
        XCTAssertEqual(ownership.current.claim, 0, "the stale receiver: it has never seen how far the sender has counted")

        let sender = OwnershipClaim(ownerPeerId: remote, claim: 9)
        ownership.claimFromHandoff(supersedingSenderClaim: sender)

        XCTAssertTrue(ownership.isOwnedLocally)
        XCTAssertGreaterThan(ownership.current.claim, sender.claim)
        XCTAssertEqual(
            OwnershipClaim.resolve(local: sender, remote: ownership.current),
            ownership.current,
            "the sender must read the ack as newer than the claim it sent"
        )
    }

    func testHandoffAlsoClaimsAboveItsOwnCounter() {
        let ownership = makeOwnership()
        ownership.adoptIfNewer(OwnershipClaim(ownerPeerId: remote, claim: 12))
        ownership.claimLocally()
        let reached = ownership.current.claim

        // A sender that has been away hands over carrying a number this device passed long ago.
        ownership.claimFromHandoff(supersedingSenderClaim: OwnershipClaim(ownerPeerId: remote, claim: 5))

        XCTAssertGreaterThan(ownership.current.claim, reached, "the counter is monotonic across both devices, so it never steps back")
    }

    /// A handoff whose snapshot carried no claim at all — an older peer, or a field that did not
    /// survive the wire. Ownership must still move, and still move upwards.
    func testHandoffWithoutASenderClaimStillMovesTheCounterUp() {
        let ownership = makeOwnership()
        ownership.adoptIfNewer(OwnershipClaim(ownerPeerId: remote, claim: 3))

        ownership.claimFromHandoff(supersedingSenderClaim: nil)

        XCTAssertTrue(ownership.isOwnedLocally)
        XCTAssertGreaterThan(ownership.current.claim, 3)
    }

    // MARK: - Adopting what a poll says

    func testAdoptTakesANewerClaim() {
        let ownership = makeOwnership()
        let peerTookIt = OwnershipClaim(ownerPeerId: remote, claim: 1)

        ownership.adoptIfNewer(peerTookIt)

        XCTAssertEqual(ownership.current, peerTookIt)
        XCTAssertFalse(ownership.isOwnedLocally)
    }

    /// Polls arrive once a second, and a slow one can carry a snapshot taken before the handoff —
    /// one that still names this device as the owner. Adopting it would take the session back from
    /// the peer now playing, purely because a reply was late.
    func testAdoptIgnoresAnOlderClaim() {
        let ownership = makeOwnership()
        let peerTookIt = OwnershipClaim(ownerPeerId: remote, claim: 5)
        ownership.adoptIfNewer(peerTookIt)

        ownership.adoptIfNewer(OwnershipClaim(ownerPeerId: local, claim: 2))

        XCTAssertEqual(ownership.current, peerTookIt)
    }

    // MARK: - Conceding

    /// Conceding is deliberately not `adoptIfNewer`. By the time the ack comes back the peer has
    /// adopted the checkpoint and is making the sound, so its claim is the truth even in a tie the
    /// resolver would award here — and awarding it here would leave two devices playing the same
    /// song a second apart.
    func testConcedeTakesThePeersClaimEvenInATieTheResolverWouldWinLocally() {
        // This device's id sorts above the peer's, so an equal claim resolves in its favour.
        let ownership = makeOwnership(localPeerId: "peer-zzz")
        let peer = OwnershipClaim(ownerPeerId: "peer-aaa", claim: ownership.current.claim)
        XCTAssertEqual(
            OwnershipClaim.resolve(local: ownership.current, remote: peer),
            ownership.current,
            "precondition: this is a tie the resolver keeps"
        )

        ownership.concede(to: peer)

        XCTAssertEqual(ownership.current, peer)
        XCTAssertFalse(ownership.isOwnedLocally)
    }

    // MARK: - Persistence

    /// Ownership outlives the process. A relaunch that assumed it owned the session would start a
    /// second one next to the peer's, with its own queue and its own sound.
    func testOwnershipSurvivesAFreshInstanceOverTheSameDefaults() {
        let suite = "SessionOwnershipTests.\(UUID().uuidString)"
        let taken = OwnershipClaim(ownerPeerId: remote, claim: 4)
        let beforeRelaunch = makeOwnership(suite: suite)
        beforeRelaunch.concede(to: taken)

        let relaunched = makeOwnership(suite: suite)

        XCTAssertEqual(relaunched.current, taken)
        XCTAssertFalse(relaunched.isOwnedLocally, "a relaunch must not quietly take the session back from the device playing it")
    }
}
