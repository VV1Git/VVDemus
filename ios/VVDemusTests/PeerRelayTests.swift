import XCTest
@testable import VVDemus

/// The funnel every transport method opens with: `if relayed(...) { return }`.
///
/// It is what makes a pause pressed on the phone reach the Mac that is actually making the sound,
/// and a method that forgets to open with it is a silent hole: the button animates, the app looks
/// fine, and nothing happens on either device. One deleted line brings that back, and nothing
/// about it shows up in a crash log, so every method that can relay is checked here by name.
///
/// Two things are asserted for each: the exact intent that reached the owner, and that this
/// device changed nothing. The second half matters as much as the first — a method that relays
/// *and* acts locally starts a second session, which is precisely what the pairing exists to
/// prevent.
@MainActor
final class PeerRelayTests: XCTestCase {
    // MARK: - Starting playback

    func testPlayRelaysTheTrackWithItsWholeContext() {
        let track = PeerFixtures.track("a")
        let context = [PeerFixtures.track("z"), track, PeerFixtures.track("b")]
        let seed = PeerFixtures.track("seed")

        assertRelays(.play(track, context: context, contextTitle: "Some Radio", contextSeed: seed)) {
            $0.play(track: track, context: context, contextTitle: "Some Radio", contextSeed: seed)
        }
    }

    /// Tapping a song in a plain list, with no radio behind it.
    func testPlayRelaysAContextlessTrack() {
        let track = PeerFixtures.track("a")

        assertRelays(.play(track, context: [], contextTitle: nil, contextSeed: nil)) {
            $0.play(track: track)
        }
    }

    // MARK: - Transport

    /// The toggle stays a toggle all the way to the owner, and this is the one intent where that
    /// is a deliberate decision rather than an oversight.
    ///
    /// On a mirror this device's `isPlaying` is false because its player is empty, so resolving
    /// the toggle here would negate false and send "play" on every single press — including the
    /// press meant to stop music that is audibly coming out of the other device. Only the relay
    /// can see what is on screen, so only the relay can turn this into an absolute instruction,
    /// which it does before anything goes on the wire.
    func testTogglePlayPauseRelaysTheToggleRatherThanAResolvedInstruction() {
        let harness = mirroring()

        harness.player.togglePlayPause()

        XCTAssertEqual(harness.owner.relayed, [.togglePlaying])
        XCTAssertFalse(
            harness.owner.relayed.contains(.setPlaying(true)),
            "Resolved here, a toggle on a mirror is always \"play\" — the pause would never arrive"
        )
        assertUntouched(harness)
    }

    /// The lock screen's separate buttons, which are absolute and stay absolute.
    func testSetPlaybackRelaysTheAbsoluteInstruction() {
        assertRelays(.setPlaying(false)) { $0.setPlayback(playing: false) }
        assertRelays(.setPlaying(true)) { $0.setPlayback(playing: true) }
    }

    /// `from` names the track the press was made against so the owner can ignore a next it has
    /// already handled. A mirror holds no track, so it names nothing and the relay fills in
    /// whatever is on screen.
    func testAdvanceRelaysNextNamingNoTrackFromAnEmptyMirror() {
        assertRelays(.next(from: nil)) { $0.advance() }
    }

    func testAdvanceIfCurrentRelaysTheTrackItWasMadeAgainst() {
        assertRelays(.next(from: "a")) { $0.advanceIfCurrent("a") }
    }

    func testPreviousRelays() {
        assertRelays(.previous) { $0.previous() }
    }

    /// Relayed before the clamp: this device has no duration to clamp against, and the owner —
    /// which does — clamps it on arrival.
    func testSeekRelaysThePositionAsScrubbed() {
        assertRelays(.seek(87.5)) { $0.seek(to: 87.5) }
    }

    func testToggleShuffleRelays() {
        assertRelays(.toggleShuffle) { $0.toggleShuffle() }
    }

    /// The trim belongs to whichever device is making the sound. Left local it would quietly set
    /// a level for a player that is empty, and the music would carry on at the level it was at.
    func testSetVolumeRelays() {
        assertRelays(.setVolume(0.3)) { $0.setVolume(0.3) }
    }

    /// Reordering was the one queue edit with nothing on the wire, so a drag on the mirroring
    /// device rearranged an empty local queue and the rows snapped back on the next poll.
    ///
    /// The dragged track rides along with the indices. On a mirror this device's own queues are
    /// empty, so it cannot name the row itself — `PeerPlayback` fills it in from the queue that
    /// is actually on screen, and the owner uses it to find the row again if its position moved
    /// while the request was in flight.
    func testReorderingRelaysWithTheQueueItAppliesTo() {
        assertRelays(.moveInQueue(.manual, from: 2, to: 0, track: nil)) {
            $0.moveInManualQueue(from: IndexSet(integer: 2), to: 0)
        }
        assertRelays(.moveInQueue(.context, from: 0, to: 3, track: nil)) {
            $0.moveInContextQueue(from: IndexSet(integer: 0), to: 3)
        }
    }

    // MARK: - Queue editing

    func testAddToQueueRelaysTheWholeTrack() {
        let track = PeerFixtures.track("q")
        assertRelays(.addToQueue(track)) { $0.addToQueue(track) }
    }

    func testPlayNextRelaysTheWholeTrack() {
        let track = PeerFixtures.track("q")
        assertRelays(.playNext(track)) { $0.playNext(track) }
    }

    func testRemoveFromQueueRelaysById() {
        assertRelays(.removeFromQueue(videoId: "q")) { $0.removeFromQueue(PeerFixtures.track("q")) }
    }

    func testSkipToRelaysById() {
        assertRelays(.skipTo(videoId: "q")) { $0.skipTo(PeerFixtures.track("q")) }
    }

    /// The four position-taking routes address the owner by id and never by index.
    ///
    /// A row captures its index when it renders and the owner's queue moves on its own — it pops
    /// the front at every track boundary — so by the time a swipe made on this device lands over
    /// there, the position is the one thing that is no longer true. Each call below passes an
    /// index that exists in no queue at all: if the position were what travelled, that is what
    /// would arrive.
    func testThePositionTakingRoutesAddressTheOwnerByIdNotByIndex() {
        let track = PeerFixtures.track("q")

        assertRelays(.skipTo(videoId: "q")) { $0.skipToManualQueueEntry(at: 41, expecting: track) }
        assertRelays(.skipTo(videoId: "q")) { $0.skipToContextQueueEntry(at: 41, expecting: track) }
        assertRelays(.removeFromQueue(videoId: "q")) { $0.removeFromManualQueue(at: 41, expecting: track) }
        assertRelays(.removeFromQueue(videoId: "q")) { $0.removeFromContextQueue(at: 41, expecting: track) }
    }

    // MARK: - The mirror's own emptiness

    /// The relay comes *before* each method's own "is anything loaded" guard, and the order is
    /// load-bearing. A mirror's player is empty by definition, so a guard that ran first would
    /// swallow every press before it could be sent anywhere — the press that reaches the button
    /// on screen would reach nothing else.
    func testAnEmptyMirrorStillRelaysThePressesItsOwnGuardsWouldDrop() {
        let harness = mirroring()

        harness.player.togglePlayPause()
        harness.player.setPlayback(playing: true)

        XCTAssertNil(harness.player.currentTrack, "Precondition: the mirror holds nothing to guard on")
        XCTAssertEqual(harness.owner.relayed, [.togglePlaying, .setPlaying(true)])
    }

    /// A device that is mirroring but has not yet let go of its own session.
    ///
    /// That state is real and lasts a round trip: the handoff pauses, sends, and only clears the
    /// queue once the receiver has acknowledged, so between the peer's claim arriving and
    /// `releaseSession()` running this device is a mirror with a full queue. It is also the only
    /// arrangement in which "relays *and* acts locally" is visible at all — against an empty
    /// player a missing `return` changes nothing anyone can see.
    func testAMirrorThatStillHoldsAQueueTouchesNoneOfIt() async {
        let harness = SessionOwnerHarness()
        let context = [PeerFixtures.track("a"), PeerFixtures.track("b"), PeerFixtures.track("c")]
        let queued = PeerFixtures.track("m")
        await harness.startPlaying(context[0], context: context, contextTitle: "Some Radio")
        harness.player.addToQueue(queued)
        harness.engine.tick(to: 30)

        harness.owner.isMirroring = true
        harness.engine.clearEvents()

        harness.player.play(track: PeerFixtures.track("z"))
        harness.player.togglePlayPause()
        harness.player.setPlayback(playing: false)
        harness.player.advance()
        harness.player.advanceIfCurrent("a")
        harness.player.previous()
        harness.player.seek(to: 90)
        harness.player.toggleShuffle()
        harness.player.addToQueue(PeerFixtures.track("x"))
        harness.player.playNext(PeerFixtures.track("y"))
        harness.player.removeFromQueue(context[1])
        harness.player.skipTo(context[2])
        harness.player.skipToManualQueueEntry(at: 0, expecting: queued)
        harness.player.skipToContextQueueEntry(at: 0, expecting: context[1])
        harness.player.removeFromManualQueue(at: 0, expecting: queued)
        harness.player.removeFromContextQueue(at: 0, expecting: context[1])
        harness.player.setVolume(0.2)
        await harness.drain()

        XCTAssertEqual(harness.owner.relayed.count, 17, "Every call went to the owner, and each went once")
        XCTAssertEqual(harness.owner.claims, 1, "the one from starting the track, before any of this")
        XCTAssertEqual(harness.player.currentTrack, context[0])
        XCTAssertEqual(harness.player.manualQueue, [queued])
        XCTAssertEqual(harness.player.contextQueue, [context[1], context[2]])
        XCTAssertEqual(harness.player.queueContextTitle, "Some Radio")
        XCTAssertEqual(harness.player.progress, 30, accuracy: 0.001)
        XCTAssertTrue(harness.player.isPlaying, "The pause was for the other device")
        XCTAssertFalse(harness.player.isShuffling)
        XCTAssertEqual(harness.player.volume, 1)
        XCTAssertEqual(harness.engine.events, [], "The engine is the one thing that would be audible")
    }

    // MARK: - Owning the session

    /// Starting something here is the clearest possible statement that this device is in charge.
    func testPlayingLocallyClaimsTheSession() async {
        let harness = SessionOwnerHarness()

        await harness.startPlaying(PeerFixtures.track("a"))

        XCTAssertEqual(harness.owner.claims, 1)
    }

    /// And pressing play on a mirror is the opposite statement: the song starts over there, so
    /// the session stays over there too. Claiming it here would leave both devices believing they
    /// own the same session, which is the one state ownership exists to rule out.
    func testPlayingOnAMirrorDoesNotClaimTheSession() {
        let harness = mirroring()

        harness.player.play(track: PeerFixtures.track("a"))

        XCTAssertEqual(harness.owner.claims, 0)
        XCTAssertEqual(harness.owner.relayed.count, 1)
    }

    // MARK: - Not mirroring: everything behaves exactly as it did

    func testWithoutAPeerPlayStillPlaysHere() async {
        let harness = SessionOwnerHarness()
        let context = [PeerFixtures.track("a"), PeerFixtures.track("b")]

        await harness.startPlaying(context[0], context: context)

        XCTAssertTrue(harness.owner.relayed.isEmpty, "There is nowhere to relay to")
        XCTAssertEqual(harness.player.currentTrack, context[0])
        XCTAssertEqual(harness.player.contextQueue, [context[1]])
        XCTAssertTrue(harness.player.isPlaying)
        XCTAssertTrue(harness.engine.events.contains(.play), "Sound has to come out of this device")
    }

    func testWithoutAPeerTransportAndQueueEditsStillActHere() async {
        let harness = SessionOwnerHarness()
        let queued = PeerFixtures.track("q")
        await harness.startPlaying(PeerFixtures.track("a"))

        harness.player.addToQueue(queued)
        harness.player.seek(to: 42)
        harness.engine.clearEvents()
        harness.player.togglePlayPause()

        XCTAssertTrue(harness.owner.relayed.isEmpty)
        XCTAssertEqual(harness.player.manualQueue, [queued])
        XCTAssertEqual(harness.player.progress, 42, accuracy: 0.001)
        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertEqual(harness.engine.events, [.pause])
    }

    // MARK: - Helpers

    /// A player in the state a mirror is genuinely in: the peer owns the session, and this
    /// device's own player is empty and silent.
    private func mirroring() -> SessionOwnerHarness {
        let harness = SessionOwnerHarness()
        harness.owner.isMirroring = true
        return harness
    }

    /// Runs `act` against a mirror and checks the intent reached the owner and nothing else did.
    private func assertRelays(
        _ expected: PlayerService.PlaybackIntent,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ act: (PlayerService) -> Void
    ) {
        let harness = mirroring()

        act(harness.player)

        XCTAssertEqual(harness.owner.relayed, [expected], file: file, line: line)
        assertUntouched(harness, file: file, line: line)
    }

    /// The invariant the whole design rests on: a mirror's `PlayerService` is empty and makes no
    /// sound, whatever is pressed on it.
    private func assertUntouched(
        _ harness: SessionOwnerHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(harness.player.currentTrack, "A mirror must not load anything of its own", file: file, line: line)
        XCTAssertTrue(harness.player.manualQueue.isEmpty, file: file, line: line)
        XCTAssertTrue(harness.player.contextQueue.isEmpty, file: file, line: line)
        XCTAssertNil(harness.player.queueContextTitle, file: file, line: line)
        XCTAssertFalse(harness.player.isPlaying, file: file, line: line)
        XCTAssertFalse(harness.player.isShuffling, file: file, line: line)
        XCTAssertEqual(harness.player.progress, 0, file: file, line: line)
        XCTAssertEqual(harness.player.volume, 1, "The level belongs to the device making the sound", file: file, line: line)
        XCTAssertEqual(harness.engine.events, [], "A mirror is silent", file: file, line: line)
        XCTAssertEqual(harness.session.activations, [], "and does not take the audio route", file: file, line: line)
        XCTAssertTrue(harness.sideEffects.plays.isEmpty, "nor credits itself with plays", file: file, line: line)
        XCTAssertTrue(harness.sideEffects.listening.isEmpty, file: file, line: line)
        XCTAssertTrue(harness.sideEffects.radioSeeds.isEmpty, file: file, line: line)
        XCTAssertEqual(harness.owner.claims, 0, "and does not take the session from the device it is showing", file: file, line: line)
    }
}

/// A `PlayerService` wired to the fakes with a `SpySessionOwner` in place of `PeerPlayback`.
///
/// `PlayerHarness` cannot be handed one: it is shared with every other player test, all of which
/// want the unpaired `NoSessionOwner` default that leaves their behaviour untouched. The peer
/// suites — this one and `ReleaseSessionTests` — build their own here instead.
@MainActor
final class SessionOwnerHarness {
    let player: PlayerService
    let owner = SpySessionOwner()
    let engine = FakePlaybackEngine()
    let session = FakeAudioSession()
    let commands = FakeRemoteCommandCenter()
    let nowPlaying = FakeNowPlayingCenter()
    let streams = FakeStreamResolver()
    let downloads = FakeDownloads()
    let sideEffects = FakeSideEffects()
    let radios = FakeRadioFetcher()
    /// Private to this harness, for the same reasons `PlayerHarness` keeps its own: a test must
    /// not post notifications at every other `PlayerService` alive in the process, and must
    /// neither read the developer's own stored volume nor leave one behind in the app's defaults.
    let notifications = NotificationCenter()
    let defaults: UserDefaults
    private let defaultsSuiteName: String

    init() {
        defaultsSuiteName = "VVDemusTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        player = PlayerService(
            engine: engine,
            session: session,
            commandCenter: commands,
            nowPlaying: nowPlaying,
            streams: streams,
            downloads: downloads,
            sideEffects: sideEffects,
            radios: radios,
            notifications: notifications,
            sessionOwner: owner,
            defaults: defaults
        )
    }

    /// `UserDefaults(suiteName:)` writes a real plist into the test process's container, so
    /// without this every harness ever constructed leaves one behind.
    deinit {
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
    }

    /// Starts a track and waits for it to actually attach, so tests don't repeat the settling
    /// dance. Resolving a stream URL goes through an unstructured `Task`, so nothing here is
    /// synchronous with the call that triggered it.
    func startPlaying(_ track: Track, context: [Track] = [], contextTitle: String? = nil) async {
        player.play(track: track, context: context, contextTitle: contextTitle)
        await settle { self.player.currentTrack?.videoId == track.videoId && !self.player.isLoading }
    }

    func settle(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            await Task.yield()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertTrue(condition(), "Timed out waiting for condition", file: file, line: line)
    }

    /// Lets any already-queued main-actor work run, for assertions about things *not* happening.
    func drain(_ turns: Int = 12) async {
        for _ in 0..<turns {
            await Task.yield()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }
}
