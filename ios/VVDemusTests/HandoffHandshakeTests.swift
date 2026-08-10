import XCTest
@testable import VVDemus

/// Moving the session from one device to the other, in the pieces the handshake is built from.
///
/// The property the whole thing exists for is that the sender lets go of its session *only* once
/// the other device has said it took it. Letting go early leaves the music nowhere; not letting go
/// at all — which is what this used to do — leaves two devices each holding a queue, and two
/// devices each holding a queue is the state in which neither can be told it is mirroring, so
/// handing over was a one-way trip.
///
/// `PeerLink.handOffToPeer()` composes that from four steps: capture the checkpoint, pause, send,
/// and on the ack concede and release. The send is the static `PeerClient.handOff`, which nothing
/// can stand in for, so the sequence as a whole is out of reach from a test — see the report
/// accompanying this file. Each step it is made of is not, and they are what is asserted here: the
/// request and the ack surviving the wire, the ack being one the sender can safely concede to, the
/// checkpoint timestamp now meaning something, and the receiving side not starting a paused
/// session by itself.
@MainActor
final class HandoffHandshakeTests: XCTestCase {
    private var harness: PlayerHarness!

    private let sender = "peer-sender"
    private let receiver = "peer-receiver"

    /// Whole seconds, because the peer coder is `.iso8601` — see
    /// `testTheWireCarriesTheCheckpointTimestampOnlyToTheSecond`.
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        harness = PlayerHarness()
    }

    private func checkpoint(playing: Bool, updatedAt: Date? = nil) -> NowPlayingCheckpoint {
        NowPlayingCheckpoint(
            peerId: sender,
            isDesktop: false,
            updatedAt: updatedAt ?? stamp,
            currentTrack: PeerFixtures.track("a"),
            progress: 42.5,
            isPlaying: playing,
            manualQueue: [PeerFixtures.track("m1")],
            contextQueue: [PeerFixtures.track("c2"), PeerFixtures.track("c1")],
            orderedContextQueue: [PeerFixtures.track("c1"), PeerFixtures.track("c2")],
            isShuffling: true,
            queueContextTitle: "Some Radio",
            contextSeed: PeerFixtures.track("seed")
        )
    }

    // MARK: - What crosses the wire

    /// The request, through the coder the route actually decodes it with.
    ///
    /// The queues and the seed travel with it deliberately: without the seed a handed-over radio
    /// arrives as a loose list of songs with no station behind it, and without the unshuffled
    /// order turning shuffle off afterwards could not restore the real one.
    func testAHandoffRequestSurvivesTheWireWithItsQueuesAndItsSeed() throws {
        let original = HandoffRequest(
            checkpoint: checkpoint(playing: true),
            senderPaused: true,
            senderClaim: OwnershipClaim(ownerPeerId: sender, claim: 8)
        )

        let data = try LocalControlServer.peerEncoder.encode(original)
        let decoded = try LocalControlServer.peerDecoder.decode(HandoffRequest.self, from: data)

        XCTAssertEqual(decoded.checkpoint, original.checkpoint)
        XCTAssertTrue(decoded.senderPaused)
        XCTAssertEqual(
            decoded.senderClaim, original.senderClaim,
            "Without the sender's claim the receiver cannot claim above it, and both end up owners"
        )
    }

    /// A sender running an older build sends no claim at all. It must still decode: the two apps
    /// are built and installed separately, and a Mac on yesterday's build failing to hand over is
    /// a worse outcome than the receiver claiming only above its own counter.
    func testAHandoffRequestWithNoClaimStillDecodes() throws {
        let original = HandoffRequest(checkpoint: checkpoint(playing: false), senderPaused: true, senderClaim: nil)

        let data = try LocalControlServer.peerEncoder.encode(original)
        let decoded = try LocalControlServer.peerDecoder.decode(HandoffRequest.self, from: data)

        XCTAssertNil(decoded.senderClaim)
        XCTAssertEqual(decoded.checkpoint, original.checkpoint)
    }

    /// The ack used to be a bare `"ok"`, so the sender paused itself and hoped. What makes it safe
    /// to let go is the ownership riding back on it.
    func testTheAckCarriesTheOwnershipTheSenderConcedesTo() throws {
        let original = HandoffAck(accepted: true, ownership: OwnershipClaim(ownerPeerId: receiver, claim: 9))

        let data = try LocalControlServer.peerEncoder.encode(original)
        let decoded = try LocalControlServer.peerDecoder.decode(HandoffAck.self, from: data)

        XCTAssertTrue(decoded.accepted)
        XCTAssertEqual(decoded.ownership, original.ownership)
    }

    /// `.iso8601` is second-resolution, so `updatedAt` loses its fraction on the way across.
    ///
    /// Worth pinning rather than discovering: it is the field `NowPlayingCheckpoint.preferred`
    /// breaks ties on, so two devices whose playback changed within the same second reach that
    /// comparison already tied. Benign today — a tie means neither offers to continue from the
    /// other — and it stops being benign the moment anything starts deciding on it.
    func testTheWireCarriesTheCheckpointTimestampOnlyToTheSecond() throws {
        let fractional = checkpoint(playing: true, updatedAt: Date(timeIntervalSince1970: 1_700_000_000.75))
        let fractionalData = try LocalControlServer.peerEncoder.encode(fractional)
        let decodedFraction = try LocalControlServer.peerDecoder.decode(NowPlayingCheckpoint.self, from: fractionalData)

        XCTAssertNotEqual(decodedFraction.updatedAt, fractional.updatedAt, "the coder is .iso8601, not fractional")
        XCTAssertLessThan(abs(decodedFraction.updatedAt.timeIntervalSince(fractional.updatedAt)), 1)

        // A whole second survives intact, which is what the equality assertions above rely on.
        let whole = checkpoint(playing: true)
        let wholeData = try LocalControlServer.peerEncoder.encode(whole)
        let decodedWhole = try LocalControlServer.peerDecoder.decode(NowPlayingCheckpoint.self, from: wholeData)
        XCTAssertEqual(decodedWhole.updatedAt, whole.updatedAt)
    }

    // MARK: - An ack the sender can safely let go on

    /// The handshake's ordering property, minus the network: after the receiver claims and the
    /// sender concedes, exactly one device owns the session — and the sender's own stale view of
    /// itself, arriving on the very next poll, does not take it back.
    ///
    /// The receiver claims above the *sender's* counter, not merely its own. A receiver that has
    /// been away holds a low claim, and `current.claim + 1` can land at or below what the sender
    /// already has; the sender would then resolve the ack in its own favour and keep the session
    /// it had just given away, while the receiver played on.
    func testAReceiverThatHasBeenAwayStillClaimsAboveTheSender() {
        let senderOwnership = PeerFixtures.ownership(localPeerId: sender)
        // A device with some history: it handed over once and took it back, so its counter sits
        // well above a fresh install's.
        senderOwnership.adoptIfNewer(OwnershipClaim(ownerPeerId: receiver, claim: 7))
        senderOwnership.claimLocally()
        let senderClaim = senderOwnership.current
        XCTAssertEqual(senderClaim, OwnershipClaim(ownerPeerId: sender, claim: 8))

        // The receiving half of `/api/peer/handoff`, on a device whose own counter is at zero.
        let receiverOwnership = PeerFixtures.ownership(localPeerId: receiver)
        receiverOwnership.claimFromHandoff(supersedingSenderClaim: senderClaim)
        let ack = HandoffAck(accepted: true, ownership: receiverOwnership.current)

        XCTAssertGreaterThan(
            ack.ownership.claim, senderClaim.claim,
            "Claiming only above its own counter lands below the sender's, and the sender keeps the session"
        )

        // The sender's half, once the ack arrives.
        senderOwnership.concede(to: ack.ownership)
        XCTAssertFalse(senderOwnership.isOwnedLocally)
        XCTAssertTrue(receiverOwnership.isOwnedLocally)

        // The poll that was already in flight when it conceded, still naming the sender as owner.
        senderOwnership.adoptIfNewer(senderClaim)
        XCTAssertFalse(
            senderOwnership.isOwnedLocally,
            "A snapshot from before the handoff must not hand the session back"
        )
    }

    // MARK: - What the sender is left holding

    /// Releasing is not pausing, and the difference is the bug the handshake exists to fix: a
    /// paused device still holds a track and a queue, which is what made it a second owner.
    func testReleasingTheSessionLeavesTheSenderWithNothing() async {
        let list = Fixtures.tracks(["a", "b", "c"])
        await harness.startPlaying(list[0], context: list)
        harness.player.addToQueue(Fixtures.track("q"))
        harness.engine.tick(to: 30)

        harness.player.releaseSession()

        XCTAssertNil(harness.player.currentTrack)
        XCTAssertTrue(harness.player.manualQueue.isEmpty)
        XCTAssertTrue(harness.player.contextQueue.isEmpty)
        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertEqual(
            harness.engine.events.last, .detach,
            "A paused engine still holds its item and resumes on the next play()"
        )
        // Credited before the track is forgotten. Stats are otherwise recorded when one track
        // replaces another, and the track handed to the other device is never replaced here — so
        // the seconds listened to before the handoff would simply vanish.
        XCTAssertEqual(harness.sideEffects.listening.count, 1)
        XCTAssertEqual(harness.sideEffects.listening.last?.track.videoId, "a")
        XCTAssertEqual(harness.sideEffects.listening.last?.seconds, 30)
    }

    /// The failure path's half of the same distinction: a handoff that is refused or never
    /// answered has only ever paused, so putting playback back is enough to leave the device
    /// exactly as it was.
    func testAHandoffThatWasNeverAckedLeavesThePausedSessionIntact() async {
        let list = Fixtures.tracks(["a", "b", "c"])
        await harness.startPlaying(list[0], context: list)
        harness.engine.tick(to: 30)

        // What `handOffToPeer` does before it sends, and what it undoes when the send fails.
        harness.player.setPlayback(playing: false)
        harness.player.setPlayback(playing: true)

        XCTAssertEqual(harness.player.currentTrack?.videoId, "a")
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["b", "c"])
        XCTAssertEqual(harness.player.progress, 30, accuracy: 0.001, "the position must not move")
        XCTAssertTrue(harness.player.isPlaying)
        XCTAssertFalse(harness.engine.events.contains(.detach), "nothing was given away")
    }

    // MARK: - What the receiver does with it

    /// A session handed over while paused must not start playing on its own.
    ///
    /// The route autoplays from `checkpoint.isPlaying`, not unconditionally. The sender pauses
    /// itself before sending so the two are never audible at once, and the checkpoint was captured
    /// *before* that pause — so it is what playback was actually doing when the user asked. Read
    /// from the sender's live state instead, every handoff looks paused; autoplayed
    /// unconditionally, a paused session starts making noise on a device nobody touched.
    func testAPausedSessionHandedOverDoesNotStartPlayingByItself() async {
        let paused = checkpoint(playing: false)

        // Spelled as the route spells it, since the flag is the whole decision.
        harness.player.adopt(checkpoint: paused, autoplay: paused.isPlaying)
        await harness.settle { !self.harness.player.isLoading }

        XCTAssertEqual(harness.player.currentTrack?.videoId, "a")
        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertFalse(harness.engine.didPlayAfterLastAttach, "It woke up and started playing")
        XCTAssertEqual(harness.player.progress, paused.progress, accuracy: 0.001)
        // The queue still arrives — a paused handoff is a whole session, just a silent one.
        XCTAssertEqual(harness.player.manualQueue.map(\.videoId), ["m1"])
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["c2", "c1"])
        XCTAssertTrue(harness.player.isShuffling)
    }

    /// And the ordinary case, so the rule above is not simply "never play".
    func testAPlayingSessionHandedOverPicksUpWhereItLeftOff() async {
        let playing = checkpoint(playing: true)

        harness.player.adopt(checkpoint: playing, autoplay: playing.isPlaying)
        await harness.settle { !self.harness.player.isLoading }

        XCTAssertTrue(harness.player.isPlaying)
        XCTAssertTrue(harness.engine.didPlayAfterLastAttach)
        XCTAssertEqual(harness.engine.currentTimeSeconds, playing.progress, accuracy: 0.001)
    }

    // MARK: - The timestamp the resume offer decides on

    /// `updatedAt` is when playback last *changed*, not when the checkpoint was read.
    ///
    /// Stamped at read time — which is what it used to be — `NowPlayingCheckpoint.preferred`
    /// compared "now" against "now", since both checkpoints are built within a round trip of each
    /// other. Its timestamp tiebreak therefore decided nothing, and the resume offer between two
    /// idle devices was a coin flip.
    func testTheCheckpointStampsWhenPlaybackChangedNotWhenItWasRead() async {
        await harness.startPlaying(Fixtures.track("a"))

        let first = harness.player.nowPlayingCheckpoint()
        await harness.drain()
        let second = harness.player.nowPlayingCheckpoint()

        XCTAssertEqual(first.updatedAt, second.updatedAt, "reading the checkpoint is not a change")
        XCTAssertLessThan(first.updatedAt, Date(), "the stamp belongs to the load, not to the read")
    }

    /// …and it does still move when playback actually changes, so it is not merely frozen.
    func testPausingMovesTheCheckpointStamp() async {
        await harness.startPlaying(Fixtures.track("a"))
        let whilePlaying = harness.player.nowPlayingCheckpoint().updatedAt

        harness.player.setPlayback(playing: false)

        XCTAssertGreaterThan(harness.player.nowPlayingCheckpoint().updatedAt, whilePlaying)
    }

    /// The tiebreak deciding something, which is the point of the change: two devices with nothing
    /// playing, told apart by which one stopped more recently.
    func testTheTimestampDecidesBetweenTwoIdleDevices() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.setPlayback(playing: false)
        let mine = harness.player.nowPlayingCheckpoint()
        XCTAssertFalse(mine.isPlaying, "the tiebreak is only reached once neither device is playing")

        let older = checkpoint(playing: false, updatedAt: mine.updatedAt.addingTimeInterval(-30))
        let newer = checkpoint(playing: false, updatedAt: mine.updatedAt.addingTimeInterval(30))

        XCTAssertEqual(NowPlayingCheckpoint.preferred(mine, older), mine)
        XCTAssertEqual(NowPlayingCheckpoint.preferred(mine, newer), newer)
    }
}
