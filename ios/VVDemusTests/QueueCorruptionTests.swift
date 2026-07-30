import XCTest
@testable import VVDemus

/// Ways the queue used to quietly lose or duplicate entries. Every case here ends with a
/// track the user can no longer reach, which is worse than a visible misbehaviour: nothing
/// on screen says the song was dropped.
@MainActor
final class QueueCorruptionTests: XCTestCase {
    private var harness: PlayerHarness!

    override func setUp() async throws {
        harness = PlayerHarness()
    }

    // MARK: - Rewinding while shuffled

    /// Shuffle, next, previous, shuffle off. The rewind un-plays the track, so it has to be
    /// back in *both* queues; it used to go back only into the shuffled one, and switching
    /// shuffle off — which replaces `contextQueue` with the unshuffled list — deleted it.
    func testRewindingWhileShuffledKeepsTheTrackInTheUnshuffledOrder() async {
        let list = Fixtures.tracks(["a", "b", "c", "d"])
        await harness.startPlaying(list[0], context: list)
        harness.player.toggleShuffle()

        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId != "a" }
        let played = harness.player.currentTrack?.videoId

        harness.player.previous() // still at 0:00, so this steps back rather than restarting
        await harness.settle { self.harness.player.currentTrack?.videoId == "a" }
        XCTAssertEqual(
            Set(harness.player.contextQueue.map(\.videoId)), ["b", "c", "d"],
            "The rewound track \(played ?? "?") must be back in the shuffled queue"
        )

        harness.player.toggleShuffle() // off

        XCTAssertEqual(
            harness.player.contextQueue.map(\.videoId), ["b", "c", "d"],
            "Turning shuffle off restores the real order — with every track still in it"
        )
    }

    /// Two steps back, so the restored positions can't both be index 0 and still come out
    /// in the right order.
    func testRewindingTwiceWhileShuffledRestoresTheRealOrder() async {
        let list = Fixtures.tracks(["a", "b", "c", "d", "e"])
        await harness.startPlaying(list[0], context: list)
        harness.player.toggleShuffle()

        harness.player.advance()
        await harness.drain()
        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack != nil && !self.harness.player.isLoading }

        harness.player.previous()
        await harness.drain()
        harness.player.previous()
        await harness.settle { self.harness.player.currentTrack?.videoId == "a" }

        harness.player.toggleShuffle() // off

        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["b", "c", "d", "e"])
    }

    /// The unshuffled case is the one that always worked; it must keep working, since the
    /// fix changed where the track is re-inserted rather than whether it is.
    func testRewindingWithoutShuffleStillPutsTheTrackBackAtTheFront() async {
        let list = Fixtures.tracks(["a", "b", "c"])
        await harness.startPlaying(list[0], context: list)

        harness.player.advance()
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" }
        harness.player.previous()
        await harness.settle { self.harness.player.currentTrack?.videoId == "a" }

        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["b", "c"])
        harness.player.toggleShuffle()
        harness.player.toggleShuffle()
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["b", "c"])
    }

    // MARK: - Duplicated entries

    /// A mix or a Home shelf can repeat a videoId. The web remote's remove route addresses
    /// rows by track, and used to take every copy with it.
    func testRemovingADuplicatedTrackTakesOnlyOneCopy() async {
        let list = [Fixtures.track("a"), Fixtures.track("b"), Fixtures.track("c"), Fixtures.track("b")]
        await harness.startPlaying(list[0], context: list)
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["b", "c", "b"])

        harness.player.removeFromQueue(Fixtures.track("b"))

        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["c", "b"])
    }

    /// ...and the unshuffled order has to lose exactly one copy too, or the survivor
    /// disappears the next time shuffle is switched off.
    func testRemovingADuplicatedTrackLeavesTheSurvivorInTheUnshuffledOrder() async {
        let list = [Fixtures.track("a"), Fixtures.track("b"), Fixtures.track("c"), Fixtures.track("b")]
        await harness.startPlaying(list[0], context: list)

        harness.player.removeFromQueue(Fixtures.track("b"))
        harness.player.toggleShuffle()
        harness.player.toggleShuffle()

        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["c", "b"])
    }

    /// Skipping forward over a repeated track dropped every copy of it from the unshuffled
    /// order, including the one still queued behind the skip target.
    func testSkippingPastADuplicateKeepsTheLaterCopyInTheUnshuffledOrder() async {
        let list = [Fixtures.track("a"), Fixtures.track("b"), Fixtures.track("c"), Fixtures.track("b")]
        await harness.startPlaying(list[0], context: list)

        harness.player.skipTo(Fixtures.track("c"))
        await harness.settle { self.harness.player.currentTrack?.videoId == "c" }
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["b"])

        harness.player.toggleShuffle()
        harness.player.toggleShuffle()

        XCTAssertEqual(
            harness.player.contextQueue.map(\.videoId), ["b"],
            "The copy of b after c was never played and must survive"
        )
    }

    /// A tap on the second of two identical rows means *that* row. Matching on track can
    /// only find the first one, which plays the wrong entry and leaves the rows in between
    /// queued; the position-carrying route is what the queue screen should use.
    func testSkippingToTheSecondCopyOfATrackConsumesEverythingBeforeIt() async {
        let list = [
            Fixtures.track("a"), Fixtures.track("b"), Fixtures.track("c"),
            Fixtures.track("b"), Fixtures.track("d")
        ]
        await harness.startPlaying(list[0], context: list)
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["b", "c", "b", "d"])

        harness.player.skipToContextQueueEntry(at: 2, expecting: Fixtures.track("b"))
        await harness.settle { self.harness.player.currentTrack?.videoId == "b" }

        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["d"])
        harness.player.toggleShuffle()
        harness.player.toggleShuffle()
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["d"])
    }

    func testSkippingToAManualQueueEntryByPosition() async {
        await harness.startPlaying(Fixtures.track("a"))
        for id in ["q1", "q2", "q3"] { harness.player.addToQueue(Fixtures.track(id)) }

        harness.player.skipToManualQueueEntry(at: 1, expecting: Fixtures.track("q2"))
        await harness.settle { self.harness.player.currentTrack?.videoId == "q2" }

        XCTAssertEqual(harness.player.manualQueue.map(\.videoId), ["q3"])
    }

    /// The queue moves under the UI between a row rendering and being tapped, exactly as it
    /// does for the remove routes.
    func testSkippingToAStaleIndexFallsBackToTheExpectedTrack() async {
        let list = Fixtures.tracks(["a", "b", "c", "d"])
        await harness.startPlaying(list[0], context: list)

        harness.player.skipToContextQueueEntry(at: 99, expecting: Fixtures.track("c"))
        await harness.settle { self.harness.player.currentTrack?.videoId == "c" }

        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["d"])
    }

    func testSkippingToAnIndexHoldingNothingExpectedDoesNothing() async {
        let list = Fixtures.tracks(["a", "b"])
        await harness.startPlaying(list[0], context: list)

        harness.player.skipToContextQueueEntry(at: 99)
        harness.player.skipToManualQueueEntry(at: -1)
        await harness.drain()

        XCTAssertEqual(harness.player.currentTrack?.videoId, "a")
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["b"])
    }

    /// The browser plays on past a disconnection and the phone catches up. Consuming the
    /// queue to match must not delete a duplicate that is still ahead of it.
    func testAdoptingBrowserPlaybackKeepsALaterDuplicate() async {
        let list = [Fixtures.track("a"), Fixtures.track("b"), Fixtures.track("c"), Fixtures.track("b")]
        await harness.startPlaying(list[0], context: list)
        harness.player.setActiveDevice(.computer)
        await harness.settle { self.harness.player.externalStream != nil }

        harness.player.adoptExternalPlayback(videoId: "c", progress: 12)
        await harness.drain()

        XCTAssertEqual(harness.player.currentTrack?.videoId, "c")
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["b"])
        harness.player.toggleShuffle()
        harness.player.toggleShuffle()
        XCTAssertEqual(harness.player.contextQueue.map(\.videoId), ["b"])
    }

    /// Combines the two: adopt a track while shuffled, then rewind. The adopted track has
    /// to return to its real position, not to the front.
    func testRewindingAfterASkipRestoresTheTrackToItsRealPosition() async {
        let list = Fixtures.tracks(["a", "b", "c", "d", "e"])
        await harness.startPlaying(list[0], context: list)
        harness.player.toggleShuffle()

        harness.player.skipTo(Fixtures.track("d"))
        await harness.settle { self.harness.player.currentTrack?.videoId == "d" }

        harness.player.previous()
        await harness.settle { self.harness.player.currentTrack?.videoId == "a" }

        harness.player.toggleShuffle() // off
        let restored = harness.player.contextQueue.map(\.videoId)
        XCTAssertTrue(restored.contains("d"), "The rewound track is missing entirely")
        XCTAssertEqual(restored, restored.sorted(), "…and it belongs at its real position, not the front")
    }
}
