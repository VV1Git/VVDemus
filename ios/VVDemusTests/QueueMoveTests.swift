import XCTest
@testable import VVDemus

/// A drag resolved against a queue that is not the one it was measured on — two divergent lists
/// in, one pair of indices out. No network, no second device and no audio, which is what makes
/// the awkward cases (the owner mid-track, the dragged row already played, a peer on an older
/// build, a radio that repeats a track) cheap enough to write out in full.
final class QueueMoveTests: XCTestCase {
    private func decide(
        _ queue: [String],
        moved: String?,
        anchor: QueueMove.Anchor,
        from: Int,
        to: Int
    ) -> QueueMove.Decision {
        QueueMove.decide(QueueMove.Inputs(
            queue: queue, movedVideoId: moved, anchor: anchor, from: from, to: to
        ))
    }

    /// Applies the decision exactly as its two callers do, so the assertions can be about an
    /// order rather than about a pair of numbers.
    private func applied(_ queue: [String], _ decision: QueueMove.Decision) -> [String] {
        guard let source = decision.source else { return queue }
        var copy = queue
        copy.move(fromOffsets: IndexSet(integer: source), toOffset: decision.destination)
        return copy
    }

    // MARK: - The bug this file exists for

    /// The owner played A while the drag was in flight. Correcting the source and passing the
    /// destination through as sent landed B at the end — [C,D,B] for a drag that said "B before
    /// D" — and did it once per track boundary, silently.
    func testADropSurvivesTheQueueAdvancingUnderIt() {
        // Sender held [A,B,C,D] and dragged B in front of D.
        let decision = decide(["B", "C", "D"], moved: "B", anchor: .before("D"), from: 1, to: 3)

        XCTAssertEqual(decision.source, 0)
        XCTAssertEqual(applied(["B", "C", "D"], decision), ["C", "B", "D"])
    }

    /// The same correction without an anchor, which is what a peer on a build that predates the
    /// wire fields sends. The drift the source correction reveals is enough on its own for the
    /// case that actually bites.
    func testAnUnstatedDropIsStillCorrectedByHowFarTheQueueDrifted() {
        let decision = decide(["B", "C", "D"], moved: "B", anchor: .unstated, from: 1, to: 3)

        XCTAssertEqual(decision.destination, 2)
        XCTAssertEqual(applied(["B", "C", "D"], decision), ["C", "B", "D"])
    }

    func testAnUndriftedDropIsLeftExactlyWhereItWasAimed() {
        let queue = ["A", "B", "C", "D"]
        let decision = decide(queue, moved: "B", anchor: .before("D"), from: 1, to: 3)

        XCTAssertEqual(decision.source, 1)
        XCTAssertEqual(applied(queue, decision), ["A", "C", "B", "D"])
    }

    /// Upwards, which uses the same rule and has to come out the other way round.
    func testDraggingARowUpwardsLandsItInFrontOfTheAnchor() {
        let queue = ["A", "B", "C", "D"]
        let decision = decide(queue, moved: "D", anchor: .before("B"), from: 3, to: 1)

        XCTAssertEqual(applied(queue, decision), ["A", "D", "B", "C"])
    }

    func testADropPastTheLastRowGoesToTheEnd() {
        let queue = ["B", "C", "D"]
        let decision = decide(queue, moved: "B", anchor: .end, from: 1, to: 4)

        XCTAssertEqual(decision.destination, 3)
        XCTAssertEqual(applied(queue, decision), ["C", "D", "B"])
    }

    // MARK: - Rows that are no longer there

    /// The dragged row was played, or removed, while the request was in flight. The index this
    /// replaced fell back to `from` here and moved whichever unrelated row happened to be
    /// standing at it — editing a queue the sender never touched.
    func testAMovedRowThatIsGoneMovesNothingAtAll() {
        let decision = decide(["C", "D"], moved: "B", anchor: .before("D"), from: 1, to: 3)

        XCTAssertNil(decision.source)
        XCTAssertEqual(applied(["C", "D"], decision), ["C", "D"])
    }

    /// An anchor that is gone means the queue was edited past what drift alone describes. The
    /// corrected index is still the best answer available, and is better than refusing the move.
    func testAnAnchorThatIsGoneFallsBackToTheCorrectedIndex() {
        let decision = decide(["B", "C"], moved: "B", anchor: .before("D"), from: 1, to: 3)

        XCTAssertEqual(decision.source, 0)
        XCTAssertEqual(decision.destination, 2)
    }

    func testIndicesAreClampedToTheQueueTheyAreAppliedTo() {
        let decision = decide(["A", "B"], moved: "A", anchor: .unstated, from: 0, to: 99)

        XCTAssertEqual(decision.destination, 2)
        XCTAssertEqual(applied(["A", "B"], decision), ["B", "A"])
    }

    // MARK: - Repeated tracks

    /// A radio can hand back the same videoId twice, and `firstIndex(of:)` would resolve the
    /// second copy of a track to the first — the same ambiguity the `at:expecting:` variants of
    /// `skipTo`/`removeFrom` exist to avoid on the tap path.
    func testARepeatedTrackResolvesToTheCopyTheDragMeant() {
        let queue = ["X", "A", "B", "X", "C"]
        let decision = decide(queue, moved: "X", anchor: .before("A"), from: 3, to: 1)

        XCTAssertEqual(decision.source, 3, "The second copy of X is the one that was dragged")
        XCTAssertEqual(applied(queue, decision), ["X", "X", "A", "B", "C"])
    }

    func testARepeatedAnchorResolvesToTheCopyNearestTheDrop() {
        let queue = ["A", "X", "B", "C", "X"]
        let decision = decide(queue, moved: "A", anchor: .before("X"), from: 0, to: 4)

        XCTAssertEqual(decision.destination, 4, "The X nearest the drop is the last one")
        XCTAssertEqual(applied(queue, decision), ["X", "B", "C", "A", "X"])
    }

    // MARK: - The permutation case, behind shuffle

    /// The shuffled queue and the real one hold the same tracks in different orders, so an index
    /// carries nothing across and only the anchor does.
    func testAReorderCarriesIntoADifferentPermutationOfTheSameTracks() {
        // Shuffled: [C,A,D,B]; the user drags D in front of A. In the real order that means the
        // same thing, at entirely different indices.
        let ordered = ["A", "B", "C", "D"]
        let decision = QueueMove.reorder(ordered, moving: "D", to: .before("A"))

        XCTAssertEqual(applied(ordered, decision), ["D", "A", "B", "C"])
    }

    func testAReorderOntoTheEndOfTheShuffledQueueLandsOnTheEndOfTheRealOne() {
        let ordered = ["A", "B", "C", "D"]
        let decision = QueueMove.reorder(ordered, moving: "B", to: .end)

        XCTAssertEqual(applied(ordered, decision), ["A", "C", "D", "B"])
    }

    /// A row already in front of its anchor is a drag that asked for what was already true.
    func testAReorderThatIsAlreadySatisfiedChangesNothing() {
        let ordered = ["A", "B", "C", "D"]
        let decision = QueueMove.reorder(ordered, moving: "B", to: .before("C"))

        XCTAssertEqual(applied(ordered, decision), ordered)
    }

    func testAReorderWithNothingToGoOnMovesNothing() {
        let ordered = ["A", "B"]

        XCTAssertNil(QueueMove.reorder(ordered, moving: "Z", to: .before("A")).source)
        XCTAssertNil(QueueMove.reorder(ordered, moving: nil, to: .end).source)
        XCTAssertEqual(applied(ordered, QueueMove.reorder(ordered, moving: "A", to: .unstated)), ordered)
    }

    /// Nothing named at all — the shape a caller that has only indices produces.
    func testWithNoNamedRowTheIndexIsAllThereIs() {
        let queue = ["A", "B", "C"]
        let decision = decide(queue, moved: nil, anchor: .unstated, from: 2, to: 0)

        XCTAssertEqual(decision.source, 2)
        XCTAssertEqual(applied(queue, decision), ["C", "A", "B"])
    }

    func testWithNoNamedRowAnOutOfRangeIndexMovesNothing() {
        XCTAssertNil(decide(["A"], moved: nil, anchor: .unstated, from: 4, to: 0).source)
    }
}
