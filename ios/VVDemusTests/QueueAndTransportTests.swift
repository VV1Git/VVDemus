import XCTest
@testable import VVDemus

/// Queue mechanics: the manual "play next"/"add to queue" list, the context queue behind
/// it, shuffle, and walking backwards and forwards through both.
@MainActor
final class QueueAndTransportTests: XCTestCase {
    private var harness: PlayerHarness!

    override func setUp() async throws {
        harness = PlayerHarness()
    }

    // MARK: - Starting playback

    func testPlayingFromAListQueuesEverythingAfterIt() async {
        let list = Fixtures.tracks(["a", "b", "c", "d"])
        await harness.startPlaying(list[1], context: list)

        XCTAssertEqual(harness.player.currentTrack?.videoId, "b")
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["c", "d"])
        XCTAssertTrue(harness.player.manualQueue.isEmpty)
    }

    func testPlayingATrackNotInItsContextQueuesNothing() async {
        let list = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(Fixtures.track("z"), context: list)

        XCTAssertEqual(harness.player.currentTrack?.videoId, "z")
        XCTAssertTrue(harness.player.contextQueue.isEmpty)
    }

    func testStartingSomethingNewClearsTheManualQueue() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.addToQueue(Fixtures.track("q"))
        XCTAssertEqual(harness.player.manualQueue.count, 1)

        await harness.startPlaying(Fixtures.track("b"))

        XCTAssertTrue(harness.player.manualQueue.isEmpty)
    }

    // MARK: - Manual queue

    func testManualQueuePlaysBeforeTheContextQueue() async {
        let list = Fixtures.tracks(["a", "b", "c"])
        await harness.startPlaying(list[0], context: list)
        harness.player.addToQueue(Fixtures.track("q"))

        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "q" }

        XCTAssertEqual(harness.player.currentTrack?.videoId, "q")
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["b", "c"], "The context queue is untouched")
    }

    func testPlayNextJumpsTheManualQueue() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.addToQueue(Fixtures.track("q1"))
        harness.player.playNext(Fixtures.track("q2"))

        XCTAssertEqual(harness.player.manualQueue.map(\.videoId), ["q2", "q1"])
    }

    /// A track sitting in both queues would be played twice — once when the manual queue
    /// reached it, and again when the context queue got to its own untouched copy.
    func testQueuingATrackRemovesItFromTheContextQueue() async {
        let list = Fixtures.tracks(["a", "b", "c"])
        await harness.startPlaying(list[0], context: list)

        harness.player.addToQueue(list[2])

        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["b"])
        XCTAssertEqual(harness.player.manualQueue.map(\.videoId), ["c"])
    }

    func testRemovingFromQueueClearsItEverywhere() async {
        let list = Fixtures.tracks(["a", "b", "c"])
        await harness.startPlaying(list[0], context: list)
        harness.player.addToQueue(Fixtures.track("q"))

        harness.player.removeFromQueue(Fixtures.track("q"))
        harness.player.removeFromQueue(list[1])

        XCTAssertTrue(harness.player.manualQueue.isEmpty)
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["c"])
    }

    func testReorderingTheManualQueue() async {
        await harness.startPlaying(Fixtures.track("a"))
        for id in ["q1", "q2", "q3"] { harness.player.addToQueue(Fixtures.track(id)) }

        harness.player.moveInManualQueue(from: IndexSet(integer: 2), to: 0)

        XCTAssertEqual(harness.player.manualQueue.map(\.videoId), ["q3", "q1", "q2"])
    }

    /// What a drag in the desktop's queue panel owes the user: the song already playing must not
    /// so much as flinch, and the next `advance()` must take whichever row the panel now shows at
    /// the top. `currentTrack` is held apart from both queues and no index follows it, so this is
    /// structurally true rather than carefully maintained — which is exactly why it is worth
    /// pinning now that the desktop exercises it on every drag.
    func testReorderingLeavesTheTrackAlreadyPlayingAlone() async {
        await harness.startPlaying(Fixtures.track("a"))
        for id in ["q1", "q2", "q3"] { harness.player.addToQueue(Fixtures.track(id)) }

        harness.player.moveInManualQueue(from: IndexSet(integer: 2), to: 0)

        XCTAssertEqual(harness.player.currentTrack?.videoId, "a",
                       "A reorder edits what is ahead, never what is playing")

        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "q3" }
        XCTAssertEqual(harness.player.currentTrack?.videoId, "q3",
                       "The queue has to play in the order the panel shows")
    }

    /// The arithmetic behind the panel's Move Down, which is the half of the reorder that a
    /// keyboard and VoiceOver can reach. `toOffset` is a *pre-removal* index, so moving down by
    /// one is `index + 2` — `index + 1` is where the row already sits once it has been lifted out,
    /// and asking for it moves nothing.
    func testMovingARowDownByOneNeedsThePreRemovalOffset() async {
        await harness.startPlaying(Fixtures.track("a"))
        for id in ["q1", "q2", "q3"] { harness.player.addToQueue(Fixtures.track(id)) }

        harness.player.moveInManualQueue(from: IndexSet(integer: 0), to: 2)

        XCTAssertEqual(harness.player.manualQueue.map(\.videoId), ["q2", "q1", "q3"])
    }

    /// A reorder made while shuffling used to be written into the shuffled queue only, and
    /// `toggleShuffle` restores the real order wholesale — so switching shuffle off threw the
    /// edit away without a trace. The two lists are different permutations of the same tracks, so
    /// what carries across is not an index but "this song plays in front of that one".
    ///
    /// Written against whatever order the shuffle actually produced, since it is random by
    /// design: the rows are found by id, and the assertion is about adjacency rather than about
    /// positions.
    func testAReorderMadeWhileShufflingSurvivesShuffleBeingTurnedOff() async throws {
        let list = Fixtures.tracks(["a", "b", "c", "d", "e"])
        await harness.startPlaying(list[0], context: list)
        harness.player.toggleShuffle()
        XCTAssertTrue(harness.player.isShuffling)

        // Drag the last row of the shuffled queue in front of the first.
        let shuffled = harness.player.contextQueue.map(\.videoId)
        let moved = try XCTUnwrap(shuffled.last)
        let anchor = try XCTUnwrap(shuffled.first)
        harness.player.moveInContextQueue(from: IndexSet(integer: shuffled.count - 1), to: 0)
        XCTAssertEqual(harness.player.contextQueue.first?.videoId, moved, "Precondition: the drag landed")

        harness.player.toggleShuffle()

        let restored = harness.player.contextQueue.map(\.videoId)
        XCTAssertEqual(Set(restored), Set(shuffled), "Unshuffling must not lose or duplicate a track")
        let movedIndex = try XCTUnwrap(restored.firstIndex(of: moved))
        let anchorIndex = try XCTUnwrap(restored.firstIndex(of: anchor))
        XCTAssertEqual(movedIndex + 1, anchorIndex,
                       "\"\(moved) before \(anchor)\" is the whole of what the drag said, and it has to hold in the real order too")
    }

    /// Letting go of a row without moving it is a no-op in the shuffled list, but it still names
    /// the row it was released in front of — and that pairing is a real constraint in the other
    /// order. Ungated, picking a row up and putting it straight back rearranged the unshuffled
    /// queue behind the user's back, and turning shuffle off then revealed an order they never
    /// asked for.
    func testDroppingARowBackWhereItStartedLeavesTheRealOrderAlone() async {
        let list = Fixtures.tracks(["a", "b", "c", "d", "e"])
        await harness.startPlaying(list[0], context: list)
        let real = harness.player.contextQueue.map(\.videoId)
        harness.player.toggleShuffle()

        // `toOffset` of the row's own offset moves nothing, and neither does the one after it.
        harness.player.moveInContextQueue(from: IndexSet(integer: 1), to: 1)
        harness.player.moveInContextQueue(from: IndexSet(integer: 1), to: 2)

        harness.player.toggleShuffle()
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), real)
    }

    // MARK: - Skipping around

    func testSkipToDropsEverythingBeforeIt() async {
        let list = Fixtures.tracks(["a", "b", "c", "d"])
        await harness.startPlaying(list[0], context: list)

        harness.player.skipTo(list[2])
        await harness.settle { self.harness.player.currentTrack?.videoId == "c" }

        XCTAssertEqual(harness.player.currentTrack?.videoId, "c")
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["d"])
    }

    func testSkipToAnUnknownTrackDoesNothing() async {
        let list = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(list[0], context: list)

        harness.player.skipTo(Fixtures.track("nope"))
        await harness.drain()

        XCTAssertEqual(harness.player.currentTrack?.videoId, "a")
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["b"])
    }

    /// The same track can legitimately appear twice in a mix; consuming one copy must not
    /// silently drop the other.
    func testDuplicateTracksInAQueueAreConsumedOneAtATime() async {
        let list = [Fixtures.track("a"), Fixtures.track("b"), Fixtures.track("b"), Fixtures.track("c")]
        await harness.startPlaying(list[0], context: list)

        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" }

        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["b", "c"])
    }

    // MARK: - Previous

    func testPreviousRestartsTheTrackWhenPastThreeSeconds() async {
        let list = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(list[0], context: list)
        harness.player.advance()
        // Waits for the track to actually attach, not merely to be selected: the periodic
        // tick is ignored while a load is in flight (the old item is still attached, and
        // its clock is not the new track's), so ticking too early left progress at 0.
        await harness.settle {
            self.harness.player.currentTrack?.videoId == "b" && !self.harness.player.isLoading
        }
        harness.engine.tick(to: 30)

        harness.player.previous()

        XCTAssertEqual(harness.player.currentTrack?.videoId, "b")
        XCTAssertEqual(harness.player.progress, 0, accuracy: 0.001)
    }

    func testPreviousGoesBackWhenNearTheStart() async {
        let list = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(list[0], context: list)
        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" }
        harness.engine.tick(to: 1)

        harness.player.previous()
        await harness.settle { self.harness.player.currentTrack?.videoId == "a" }

        XCTAssertEqual(harness.player.currentTrack?.videoId, "a")
    }

    func testWalkingBackAndForwardRetracesTheSamePath() async {
        let list = Fixtures.tracks(["a", "b", "c"])
        await harness.startPlaying(list[0], context: list)
        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" }

        harness.player.previous()
        await harness.settle { self.harness.player.currentTrack?.videoId == "a" }
        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" }

        XCTAssertEqual(harness.player.currentTrack?.videoId, "b", "Forward again should return to b, not skip to c")
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["c"])
    }

    /// Stepping back over an explicitly queued track used to quietly move it into the
    /// context queue, so going forward again played something else entirely.
    func testSteppingBackOverAManuallyQueuedTrackKeepsItInTheManualQueue() async {
        let list = Fixtures.tracks(["x", "c"])
        await harness.startPlaying(list[0], context: list)
        harness.player.playNext(Fixtures.track("a"))

        harness.player.advance() // plays the manually queued "a"
        await harness.settle { self.harness.player.currentTrack?.videoId == "a" }

        harness.player.previous() // back to x
        await harness.settle { self.harness.player.currentTrack?.videoId == "x" }

        XCTAssertEqual(harness.player.manualQueue.map(\.videoId), ["a"], "\"a\" was queued by hand; it belongs there")

        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "a" }
        XCTAssertEqual(harness.player.currentTrack?.videoId, "a", "Forward again must return to the queued track")
    }

    func testPreviousAtTheVeryStartJustRestarts() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.engine.tick(to: 1)
        XCTAssertFalse(harness.player.hasPrevious)

        harness.player.previous()

        XCTAssertEqual(harness.player.currentTrack?.videoId, "a")
        XCTAssertEqual(harness.player.progress, 0, accuracy: 0.001)
    }

    func testTheBackStackIsBounded() async {
        let list = Fixtures.tracks((0..<60).map { "t\($0)" })
        await harness.startPlaying(list[0], context: list)
        for _ in 0..<50 {
            harness.player.advance()
            await harness.drain(2)
        }
        await harness.drain()

        // Walk all the way back; it must terminate rather than growing without bound.
        var steps = 0
        while harness.player.hasPrevious && steps < 100 {
            harness.player.previous()
            await harness.drain(2)
            steps += 1
        }
        XCTAssertLessThanOrEqual(steps, 31, "The back stack is capped at 30 entries")
    }

    // MARK: - Shuffle

    func testShuffleKeepsTheSameTracks() async {
        let list = Fixtures.tracks((0..<20).map { "t\($0)" })
        await harness.startPlaying(list[0], context: list)
        let before = Set(harness.player.contextQueue.map(\.videoId))

        harness.player.toggleShuffle()

        XCTAssertTrue(harness.player.isShuffling)
        XCTAssertEqual(Set(harness.player.contextQueue.map(\.videoId)), before)
    }

    func testTurningShuffleOffRestoresTheRealOrder() async {
        let list = Fixtures.tracks((0..<20).map { "t\($0)" })
        await harness.startPlaying(list[0], context: list)
        let original = harness.player.contextQueue.map(\.videoId)

        harness.player.toggleShuffle()
        harness.player.toggleShuffle()

        XCTAssertFalse(harness.player.isShuffling)
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), original)
    }

    func testShuffleIsResetWhenSomethingNewStarts() async {
        let list = Fixtures.tracks(["a", "b", "c"])
        await harness.startPlaying(list[0], context: list)
        harness.player.toggleShuffle()
        XCTAssertTrue(harness.player.isShuffling)

        await harness.startPlaying(Fixtures.track("z"))

        XCTAssertFalse(harness.player.isShuffling)
    }

    func testManualQueueIsNeverShuffled() async {
        let list = Fixtures.tracks((0..<20).map { "t\($0)" })
        await harness.startPlaying(list[0], context: list)
        for id in ["q1", "q2", "q3"] { harness.player.addToQueue(Fixtures.track(id)) }

        harness.player.toggleShuffle()

        XCTAssertEqual(harness.player.manualQueue.map(\.videoId), ["q1", "q2", "q3"], "The user chose this order")
    }

    /// Stepping back while shuffling must not rewrite the unshuffled running order, which
    /// is what gets restored when shuffle is switched off.
    func testSteppingBackWhileShufflingPreservesTheRealOrder() async {
        let list = Fixtures.tracks(["a", "b", "c", "d"])
        await harness.startPlaying(list[0], context: list)
        harness.player.toggleShuffle()

        harness.player.advance()
        await harness.drain()
        harness.player.previous()
        await harness.drain()

        harness.player.toggleShuffle() // off
        let restored = harness.player.contextQueue.map(\.videoId)
        XCTAssertEqual(Set(restored).count, restored.count, "No duplicates should appear in the restored order")
    }

    // MARK: - Seeking

    func testSeekIsClampedToTheTrack() async {
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 100))
        harness.engine.itemDurationSeconds = 100
        harness.engine.tick(to: 5)

        harness.player.seek(to: 500)
        XCTAssertEqual(harness.player.progress, 100, accuracy: 0.001)

        harness.player.seek(to: -20)
        XCTAssertEqual(harness.player.progress, 0, accuracy: 0.001)
    }

    func testSeekingToANonFiniteValueIsSafe() async {
        await harness.startPlaying(Fixtures.track("a", durationSeconds: 100))
        harness.player.seek(to: .nan)
        XCTAssertTrue(harness.player.progress.isFinite)
    }

    // MARK: - Listening stats

    func testSkippingCreditsOnlyWhatWasActuallyHeard() async {
        let list = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(list[0], context: list)
        harness.engine.tick(to: 42)

        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" }

        XCTAssertEqual(harness.sideEffects.listening.first?.track.videoId, "a")
        XCTAssertEqual(harness.sideEffects.listening.first?.seconds, 42)
    }

    func testStatsAreCappedAtTheTracksOwnLength() async {
        let list = [Fixtures.track("a", durationSeconds: 30), Fixtures.track("b")]
        await harness.startPlaying(list[0], context: list)
        harness.engine.tick(to: 900) // a wildly wrong position shouldn't inflate stats

        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" }

        XCTAssertEqual(harness.sideEffects.listening.first?.seconds, 30)
    }

    func testATrackNeverStartedIsNotRecorded() async {
        let list = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(list[0], context: list)

        harness.player.advance() // skipped at 0:00
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" }

        XCTAssertTrue(harness.sideEffects.listening.isEmpty)
    }
}

/// Queue entries are addressed by position, because a track can legitimately appear more
/// than once and matching on id removes every copy.
@MainActor
final class QueueIdentityTests: XCTestCase {
    private var harness: PlayerHarness!

    override func setUp() async throws {
        harness = PlayerHarness()
    }

    func testQueuingTheSameTrackTwiceDoesNotDuplicateIt() async {
        await harness.startPlaying(Fixtures.track("a"))
        let extra = Fixtures.track("q")

        harness.player.addToQueue(extra)
        harness.player.addToQueue(extra)

        XCTAssertEqual(harness.player.manualQueue.map(\.videoId), ["q"])
    }

    /// A mix can repeat a song; removing one copy must leave the other.
    func testRemovingOneOfTwoIdenticalContextEntriesLeavesTheOther() async {
        let list = [Fixtures.track("a"), Fixtures.track("b"), Fixtures.track("c"), Fixtures.track("b")]
        await harness.startPlaying(list[0], context: list)
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["b", "c", "b"])

        harness.player.removeFromContextQueue(at: 0)

        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["c", "b"],
                       "Removing by id would have taken both copies of b")
    }

    func testRemovingByPositionIgnoresAnOutOfRangeIndex() async {
        await harness.startPlaying(Fixtures.track("a"))
        harness.player.addToQueue(Fixtures.track("q"))

        harness.player.removeFromManualQueue(at: 99)
        harness.player.removeFromContextQueue(at: -1)

        XCTAssertEqual(harness.player.manualQueue.count, 1)
    }

    func testRemovingFromTheManualQueueByPosition() async {
        await harness.startPlaying(Fixtures.track("a"))
        for id in ["q1", "q2", "q3"] { harness.player.addToQueue(Fixtures.track(id)) }

        harness.player.removeFromManualQueue(at: 1)

        XCTAssertEqual(harness.player.manualQueue.map(\.videoId), ["q1", "q3"])
    }

    // MARK: - Rolling into a radio (probe)

    func testStartingTheLastTrackOfACollectionRollsStraightIntoARadio() async {
        let album = Fixtures.tracks(["a", "b", "c"])
        harness.radios.results["c"] = Fixtures.tracks(["r1", "r2", "r3"])

        // The album's final track in its natural order.
        await harness.startPlaying(album[2], context: album)
        XCTAssertTrue(harness.player.contextQueue.isEmpty, "queue is empty the moment playback starts")

        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "r1" }

        XCTAssertEqual(harness.player.currentTrack?.videoId, "r1")
        XCTAssertEqual(harness.player.queueContextTitle, "c Radio")
        XCTAssertEqual(harness.radios.requests, ["c"])
    }

    func testStartingAMiddleTrackKeepsPlayingTheAlbum() async {
        let album = Fixtures.tracks(["a", "b", "c"])
        harness.radios.results["b"] = Fixtures.tracks(["r1"])

        await harness.startPlaying(album[1], context: album)
        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "c" }

        XCTAssertEqual(harness.player.currentTrack?.videoId, "c")
        XCTAssertTrue(harness.radios.requests.isEmpty, "no radio fetched while the album still has tracks")
    }

}
