import Foundation

/// Which songs survive a radio refresh, and how many new ones a refresh owes you.
///
/// Pure — no network, no store, no clock — so the phone, the Mac and the web remote can all
/// route through it and a test can walk a station through several refreshes in a millisecond.
///
/// ## Why the decision has to be made here
///
/// Refresh used to be "fetch the seed's mix again, store whatever comes back", on the belief
/// (written into comments all over this app) that YouTube returns a different selection every
/// time. Measured against the live endpoint, two back-to-back calls for the same seed shared
/// **31 of their 50 tracks**. So the list shuffled, the same core came back every time, and
/// pressing Refresh repeatedly got you nowhere — which is exactly how it was reported.
///
/// The endpoint cannot be asked for "songs I have not already seen". What it *can* be asked
/// for is the next page of an infinite radio, which is what `RadioFreshener` does. This type
/// is the other half: how much of the list those pages have to displace, and what may stay.
enum RadioRefreshPolicy {
    /// How many refreshes a song may survive.
    ///
    /// Two, so that three refreshes leave nothing of the list you started with but the seed.
    /// The half-the-list rule below usually clears it in two on its own; this cap is what
    /// makes the guarantee hold rather than leaving it to arithmetic that happens to work
    /// out — a station whose pool ran thin once must not carry a song forever afterwards.
    static let carryOverGenerations = 2

    /// At least half the list, rounded up, has to be songs the station has not shown.
    static func requiredNewCount(bodyLength: Int) -> Int {
        (bodyLength + 1) / 2
    }

    struct Outcome: Equatable {
        /// The refreshed mix, seed first.
        let tracks: [Track]
        /// Which refresh introduced each song, to hand back to the next one.
        let generations: [String: Int]
        /// How many songs in `tracks` the station had not shown before.
        let newCount: Int
        /// How many it owed.
        let requiredNewCount: Int

        /// Whether this is a refresh worth writing.
        ///
        /// A refresh that could only find six new songs is not a partial refresh, it is a
        /// failed one — and writing it would be worse than doing nothing: it spends the
        /// station's whole carry-over budget (everything it displaced is gone for good) to
        /// produce a list that still looks like the one you were complaining about. The
        /// caller keeps the old mix and says the refresh didn't land.
        var metRequirement: Bool { newCount >= requiredNewCount }
    }

    /// Folds `candidates` into `current`, keeping `seed` pinned at the top.
    ///
    /// `generation` is the number of the refresh being performed; `generations` maps each
    /// song already in the list to the refresh that introduced it. A song missing from that
    /// map is treated as one generation old rather than ancient — that is the first refresh
    /// after this feature shipped, and a mix that arrived from the other device by sync,
    /// neither of which should be thrown away wholesale.
    static func apply(
        seed: Track,
        current: [Track],
        generations: [String: Int],
        generation: Int,
        candidates: [Track],
        length: Int
    ) -> Outcome {
        let capacity = max(0, length - 1)
        guard capacity > 0 else {
            return Outcome(
                tracks: [seed],
                generations: [seed.videoId: generation],
                newCount: 0,
                requiredNewCount: 0
            )
        }

        let body = current.filter { $0.videoId != seed.videoId }
        let bodyIds = Set(body.map(\.videoId))

        // Deduped here as well as in `RadioFreshener`: the pool is assembled from several
        // pages of several stations, the guarantee is stated in songs, and a promise of
        // "half the list is new" cannot be kept on the caller's word for what is new.
        var offered: Set<String> = [seed.videoId]
        let fresh = candidates.filter { track in
            guard !bodyIds.contains(track.videoId) else { return false }
            return offered.insert(track.videoId).inserted
        }

        // Growing a station that came back short is fine; shrinking a full one to match a
        // thin pool is not — a refresh must never cost you songs it can't replace.
        let target = min(capacity, max(body.count, fresh.count))
        let required = requiredNewCount(bodyLength: target)

        // Youngest first, original order within a generation, and nothing past the
        // carry-over cap at any price.
        let oldest = generation - carryOverGenerations
        var survivors: [Survivor] = []
        for (index, track) in body.enumerated() {
            let born = generations[track.videoId] ?? generation - 1
            guard born > oldest else { continue }
            survivors.append(Survivor(index: index, track: track, born: born))
        }
        survivors.sort { $0.born == $1.born ? $0.index < $1.index : $0.born > $1.born }

        let keptEntries = Array(survivors.prefix(max(0, target - required)))
        let kept = keptEntries.map(\.track)
        let added = Array(fresh.prefix(max(0, target - kept.count)))

        var updated: [String: Int] = [seed.videoId: generation]
        for entry in keptEntries { updated[entry.track.videoId] = entry.born }
        for track in added { updated[track.videoId] = generation }

        return Outcome(
            tracks: [seed] + interleaved(new: added, kept: kept),
            generations: updated,
            newCount: added.count,
            requiredNewCount: required
        )
    }

    /// A song still in the list, with where it sits and which refresh brought it in.
    private struct Survivor {
        let index: Int
        let track: Track
        let born: Int
    }

    /// New, kept, new, kept… with whatever is left over run on at the end.
    ///
    /// Alternating rather than stacking the new half on top: a station is supposed to read as
    /// one radio, and two visibly separate blocks — everything unfamiliar, then everything
    /// you just had — reads as two lists stapled together. Starting on a new song is what
    /// makes the change obvious from the first row without doing that.
    private static func interleaved(new: [Track], kept: [Track]) -> [Track] {
        var result: [Track] = []
        result.reserveCapacity(new.count + kept.count)
        var newIterator = new.makeIterator()
        var keptIterator = kept.makeIterator()
        while true {
            var placed = false
            if let next = newIterator.next() { result.append(next); placed = true }
            if let next = keptIterator.next() { result.append(next); placed = true }
            if !placed { return result }
        }
    }
}
