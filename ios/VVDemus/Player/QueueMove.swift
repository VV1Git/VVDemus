import Foundation

/// Where a dragged queue row should actually land, when the list it was dragged in is not the
/// list the move will be applied to.
///
/// A drag produces two indices, and both are only true of the array the row was drawn from. Two
/// places in this app apply them to a *different* array:
///
/// - Over the wire. While one device mirrors the other, the queue on screen belongs to the owner,
///   and the owner's queue advances on its own at every track boundary. The route used to correct
///   the source by videoId and pass the destination through as sent, which is worse than
///   correcting neither: a sender holding [A,B,C,D] and dragging B in front of D sends from 1,
///   to 3; an owner that has since played A holds [B,C,D], corrects the source to 0, applies
///   `toOffset: 3`, and produces [C,D,B] for a drag that said "B before D".
/// - Behind shuffle. `orderedContextQueue` holds the real running order while `contextQueue`
///   holds the shuffled one, so a drag measured against the shuffled list describes a permutation
///   of the same tracks. `moveInContextQueue` used to write the move through only when shuffle
///   was off, so a reorder made while shuffling was discarded the moment it was switched off.
///
/// So a drop names the row it should end up *in front of*, and that name is resolved against the
/// list actually being edited. A value type for the same reason `PlaybackMirror` and
/// `BackgroundAudioPolicy` are: the cases worth covering need two divergent queues and nothing
/// else — no network, no second device, and no waiting out a real track boundary.
enum QueueMove {
    /// Where the row was dropped, as the sender saw it.
    enum Anchor: Equatable {
        /// Immediately in front of this track. `move(fromOffsets:toOffset:)` takes a
        /// *pre-removal* offset, so the row standing at the drop index in the list as drawn is
        /// exactly the one the drop should land in front of — which holds in both directions.
        case before(String)
        /// Dropped past the last row.
        case end
        /// Nothing was named. A peer on a build that predates the anchor sends this; the indices
        /// are all there is, and they get corrected by however far the source has drifted.
        case unstated
    }

    struct Inputs {
        /// The queue as it stands, in the order the move will be applied to.
        let queue: [String]
        /// The row being moved, named rather than indexed. Nil when the sender could not say.
        let movedVideoId: String?
        let anchor: Anchor
        /// The sender's own indices, meaningful only against the sender's copy of the queue.
        let from: Int
        let to: Int
    }

    struct Decision: Equatable {
        /// nil when the row is not in this queue at all — already played, or removed while the
        /// request was in flight. The caller must then do nothing: the index this replaced fell
        /// back to `from` in that case, which moved whichever unrelated row happened to be
        /// standing there.
        let source: Int?
        /// A `move(fromOffsets:toOffset:)` offset, already clamped to the queue.
        let destination: Int
    }

    static func decide(_ inputs: Inputs) -> Decision {
        let queue = inputs.queue
        let source = resolvedSource(inputs)
        // How far the queue has moved under the sender, measured on the one row both copies can
        // still name. It is the correction for a bare index, and it is what makes a peer that
        // sends no anchor land in the right place anyway for the case that actually bites: a
        // track boundary passing while the request was in flight.
        let drift = source.map { inputs.from - $0 } ?? 0
        let expected = inputs.to - drift

        let destination: Int
        switch inputs.anchor {
        case .before(let anchorId):
            // Falls back to the corrected index rather than giving up: an anchor that is gone
            // means the queue was edited past what drift alone describes, and the corrected
            // index is still the best guess available.
            destination = index(of: anchorId, in: queue, nearest: expected) ?? expected
        case .end:
            destination = queue.count
        case .unstated:
            destination = expected
        }
        return Decision(source: source, destination: min(max(0, destination), queue.count))
    }

    /// The permutation case: the same tracks in a different order, so there are no indices to
    /// correct and none are asked for. Only the anchor means anything.
    ///
    /// Separate from `decide(_:)` rather than served by passing it the shuffled list's indices,
    /// which describe a list this one is not — they would have quietly become the tiebreak for
    /// choosing between two copies of a repeated track, centred on a position from the wrong
    /// array. Here the moved row's own place is the only sensible centre.
    ///
    /// A repeated videoId resolves to its first copy, which is the best available answer once
    /// the index that could have told them apart is gone.
    static func reorder(_ queue: [String], moving movedVideoId: String?, to anchor: Anchor) -> Decision {
        guard let movedVideoId, let source = queue.firstIndex(of: movedVideoId) else {
            return Decision(source: nil, destination: 0)
        }
        let destination: Int
        switch anchor {
        case .before(let anchorId):
            destination = index(of: anchorId, in: queue, nearest: source) ?? source
        case .end:
            destination = queue.count
        // Nothing said where it should go, so it stays where it is rather than being moved
        // somewhere arbitrary: `move(fromOffsets:toOffset:)` at the row's own offset is a no-op.
        case .unstated:
            destination = source
        }
        return Decision(source: source, destination: min(max(0, destination), queue.count))
    }

    private static func resolvedSource(_ inputs: Inputs) -> Int? {
        guard let movedVideoId = inputs.movedVideoId else {
            // Nothing named, so the index is all there is to go on.
            return inputs.queue.indices.contains(inputs.from) ? inputs.from : nil
        }
        // The index wins while it still holds the row it was sent with, which is both the common
        // case and the only way to tell two copies of one videoId apart.
        if inputs.queue.indices.contains(inputs.from), inputs.queue[inputs.from] == movedVideoId {
            return inputs.from
        }
        return index(of: movedVideoId, in: inputs.queue, nearest: inputs.from)
    }

    /// The occurrence nearest `expected`, not the first one.
    ///
    /// A radio or a shelf can repeat a videoId, and `firstIndex(of:)` would resolve the second
    /// copy of a track to the first — the same ambiguity `skipToManualQueueEntry(at:expecting:)`
    /// exists to avoid on the tap path. Ties go to the lower index, so this is deterministic.
    private static func index(of id: String, in queue: [String], nearest expected: Int) -> Int? {
        queue.indices
            .filter { queue[$0] == id }
            .min { abs($0 - expected) < abs($1 - expected) }
    }
}
