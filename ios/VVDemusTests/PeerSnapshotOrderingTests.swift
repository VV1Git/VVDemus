import XCTest
@testable import VVDemus

/// The mirror's refusal to go backwards, and the two ways that refusal must never become a
/// permanent one.
///
/// Snapshots do not arrive in order. The 1 Hz poll runs alongside the immediate `refresh()`
/// chased after every command, so a poll issued *before* a press can land *after* the reply that
/// reflects it. Applied unconditionally it puts the previous track back on screen and drags the
/// mirror's epoch backwards, so everything the mirror sends for the next second is rejected by the
/// owner as stale — one press, and both devices spend a second disagreeing about what is playing.
/// `PeerPlayback.isStale(_:)` is what stops that, and it is the browser's `isStaleSnapshot`
/// rewritten against the same counters.
///
/// A guard like that has one catastrophic failure mode of its own: rejecting *everything*. A
/// mirror that decides every incoming snapshot is old shows a frozen screen that looks perfectly
/// healthy — socket up, polls returning 200 — and never updates again. The two tests here are the
/// two doors into that state, and both must stay shut.
///
/// **What is not covered here, and why.** The ordering rules themselves — a lower `playbackEpoch`
/// being stale, an equal `playbackEpoch` with a lower `trackLoadEpoch` being stale, a higher one
/// never being stale — cannot be reached from a test. `isStale(_:)` only *reads* `appliedEpoch`
/// and `appliedTrackLoadEpoch`; the only place they are ever set to a value is `apply(_:)`, which
/// is private and is reached only from `refresh()`, which needs a paired peer and a live network.
/// So in a test process those two are always nil, `guard let appliedEpoch else { return false }`
/// always fires, and `isStale` cannot be made to return true at all — including for the
/// server-instance reset, whose whole job is to clear counters that are already clear. Asserting
/// the ordering rules would mean either priming `PairedPeerStore.shared` (which writes a fake peer
/// into the real app's defaults) or restating the comparison in the test, which asserts nothing
/// about the code. See the report accompanying this file: extracting the bookkeeping into a value
/// type with a `mutating func accepts(_:now:)`, as `PlaybackMirror` and `castLiveness` already
/// were, makes all of it reachable — the 4-second bypass included, which otherwise needs a real
/// four-second wait in the suite.
@MainActor
final class PeerSnapshotOrderingTests: XCTestCase {
    /// A server instance id no other test has used.
    ///
    /// `PeerPlayback` is a singleton and `isStale` carries `seenServerInstanceId` forward, so an
    /// id shared with another test would make one test's first call depend on another's last.
    /// An unrecognised id is the reset case, which is the one piece of state this suite can put
    /// back where it found it.
    private func freshInstanceId() -> String { "instance-\(UUID().uuidString)" }

    /// A peer that has been relaunched restarts `playbackEpoch` and `trackLoadEpoch` at zero.
    ///
    /// Without recognising the new `serverInstanceId`, a mirror holding anything higher rejects
    /// every snapshot the restarted peer will ever send — for the rest of the session, since
    /// nothing else lowers the applied epoch either.
    func testARelaunchedPeerIsBelievedRatherThanRejected() {
        let before = freshInstanceId()
        let after = freshInstanceId()
        let mirror = PeerPlayback.shared

        XCTAssertFalse(
            mirror.isStale(PeerFixtures.snapshot(playbackEpoch: 400, trackLoadEpoch: 90, serverInstanceId: before))
        )
        XCTAssertFalse(
            mirror.isStale(PeerFixtures.snapshot(playbackEpoch: 0, trackLoadEpoch: 0, serverInstanceId: after)),
            "A relaunched peer counts from zero again; rejecting it freezes the mirror for good"
        )
        // And it stays believed — the reset is not a one-snapshot amnesty that the next tick
        // undoes.
        XCTAssertFalse(
            mirror.isStale(PeerFixtures.snapshot(playbackEpoch: 1, trackLoadEpoch: 1, serverInstanceId: after))
        )
    }

    /// The other door into a permanently frozen mirror: treating "I have applied nothing yet" as
    /// "everything I am sent is older than what I have".
    ///
    /// A mirror that has just started, or that has just seen a new server instance, holds no
    /// epoch to compare against. The only correct answer then is to take what arrives, whatever
    /// its counters say — this is deliberately *not* the ordering rule, which cannot apply until
    /// something has actually been applied.
    func testNothingIsStaleUntilSomethingHasBeenApplied() {
        let instance = freshInstanceId()
        let mirror = PeerPlayback.shared

        for epoch in [0, 7, 2, 0] {
            XCTAssertFalse(
                mirror.isStale(PeerFixtures.snapshot(playbackEpoch: epoch, trackLoadEpoch: epoch, serverInstanceId: instance)),
                "A mirror with nothing applied has nothing to call this older than (epoch \(epoch))"
            )
        }
    }
}
