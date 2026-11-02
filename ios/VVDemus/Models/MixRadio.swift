import Foundation

/// A named radio built from several songs at once rather than one.
///
/// The songs you picked play first, in the order you picked them, and everything after them is
/// chosen for being like the *set* — not like the first of them, which is all a single-seed
/// radio can offer. Songs removed from it steer it the other way: they are gone, and songs like
/// them sink or drop out. See `MixRadioBlend` for how both are decided.
///
/// Synced whole, newest-wins, like an `AlbumRecord`: the picks are an ordered list the station
/// is built from in that order, so splicing two devices' edits together would make a station
/// neither of them asked for. Deleting is a tombstone, so it survives meeting a device that
/// still has the mix.
struct MixRadio: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var seeds: [Track]
    /// "Less like this." Never overlaps `seeds` — see `add` and `remove`.
    var removed: [Track]
    var createdAt: Date
    var deletedAt: Date?
    var stamp: EditStamp

    var isPresent: Bool { deletedAt == nil }

    /// What the station was built from. A station built for a different signature is stale.
    var signature: String {
        seeds.map(\.videoId).joined(separator: "+") + "|" + removed.map(\.videoId).joined(separator: "+")
    }

    func contains(_ track: Track) -> Bool {
        seeds.contains { $0.videoId == track.videoId }
    }

    /// Picks `track`. Picking a song you removed earlier takes back the removal — liking it
    /// now is the newer, clearer signal.
    mutating func add(_ track: Track) {
        removed.removeAll { $0.videoId == track.videoId }
        guard !contains(track) else { return }
        seeds.append(track)
    }

    /// Removes `track` and steers the station away from songs like it — a pick or a suggested
    /// song alike, since "not this" means the same either way.
    mutating func remove(_ track: Track) {
        seeds.removeAll { $0.videoId == track.videoId }
        guard !removed.contains(where: { $0.videoId == track.videoId }) else { return }
        removed.append(track)
    }

    /// A name to offer when creating a mix from its first pick.
    static func suggestedName(for seeds: [Track]) -> String {
        switch seeds.count {
        case 0: return "Mix Radio"
        case 1: return "\(seeds[0].title) Mix"
        case 2: return "\(seeds[0].title) + \(seeds[1].title) Mix"
        default: return "\(seeds[0].title) + \(seeds.count - 1) More Mix"
        }
    }

    /// Folds `incoming` into `local` per mix, newest-wins, returning how many changed.
    static func merging(_ local: [MixRadio], _ incoming: [MixRadio]) -> (mixes: [MixRadio], changed: Int) {
        var result = local
        var changed = 0
        for mix in incoming {
            guard let index = result.firstIndex(where: { $0.id == mix.id }) else {
                result.append(mix)
                changed += 1
                continue
            }
            guard mix.stamp.isNewerThan(result[index].stamp) else { continue }
            result[index] = mix
            changed += 1
        }
        return (result, changed)
    }
}

/// Fuses one radio per seed into a single station that leans towards the songs they agree on.
///
/// YouTube Music has no multi-seed radio — its `next` endpoint takes one `videoId` — so the
/// station is assembled here from one radio per seed. Concatenating them would just be the
/// first seed's radio followed by the second's; interleaving them would give each seed its
/// own lane and nothing in common. What is wanted is the songs that sit *between* the seeds,
/// and the signal for that is already in the radios: a song that turns up in two or three of
/// them is like all of those seeds, not just one.
///
/// So each candidate is scored by reciprocal rank fusion — the sum, over every radio it
/// appears in, of `1 / (damping + rank)`. A song near the top of one radio still scores well,
/// which keeps a seed with nothing in common with the others from vanishing, but a song that
/// several radios share outranks it. With no overlap at all the scores tie rank for rank, and
/// the tie-break below turns that into an even round-robin across the seeds.
///
/// Pure and synchronous so the interesting cases can be reached from `VVDemusTests` without
/// the network.
enum MixRadioBlend {
    /// How much a song's position within one radio matters against how many radios it is in.
    ///
    /// At 15, one radio's own number one (1/16 ≈ 0.063) still beats a song two radios share at
    /// rank 20 (2/35 ≈ 0.057) — the very top of a seed's radio is the strongest signal it has.
    /// But two radios' rank 10 (2/25 = 0.08) beats it, and so does any song three radios share
    /// within their top 30.
    static let rankDamping = 15.0

    /// - Parameters:
    ///   - seeds: the songs the station is built from. They lead the result, in this order.
    ///   - radios: each seed's radio, index for index. A radio's own seed is usually its first
    ///     entry (or the audio upload it was swapped for); either way it matches a seed below
    ///     and is skipped, so callers can pass radios exactly as fetched.
    ///   - limit: the length of the whole station, seeds included.
    ///   - avoiding: songs to put behind every other candidate — what the station showed before
    ///     a refresh. Pushed back rather than excluded, so a seed set YouTube has little to say
    ///     about still fills its list.
    ///   - removed: songs taken out of the station. Never in it, and `removedRadios` — the
    ///     radios of some or all of them — each count *against* every song they list, with the
    ///     same rank weighting a seed's radio counts for. A song a removed radio cancels out
    ///     is dropped, so removing a song takes the songs most like it with it; a song the
    ///     picks agree on strongly enough still survives.
    ///   - isSameSong: whether two different uploads are the same song, so a video and its
    ///     `- Topic` audio copy arriving from two radios count as one song shared by both
    ///     rather than two songs each found once.
    static func blend(
        seeds: [Track],
        radios: [[Track]],
        limit: Int,
        avoiding: Set<String> = [],
        removed: [Track] = [],
        removedRadios: [[Track]] = [],
        isSameSong: (Track, Track) -> Bool = { InnerTubeClient.isSameSong($0, as: $1) }
    ) -> [Track] {
        var result: [Track] = []
        var resultIds = Set<String>()
        for seed in seeds where resultIds.insert(seed.videoId).inserted {
            result.append(seed)
        }
        guard result.count < limit else { return Array(result.prefix(limit)) }

        struct Candidate {
            let track: Track
            var score: Double
            var bestRank: Int
            var firstRadio: Int
            /// Every id this song arrived under, so a later copy of it is folded in by id.
            var ids: Set<String>
        }
        var candidates: [Candidate] = []
        var indexById: [String: Int] = [:]
        // `isSameSong` normalises both titles on every call, and comparing every candidate
        // with every other is quadratic in the number of seeds: ten seeds is 500 candidates.
        // It never matches across different artists anyway, so only same-artist rows are
        // compared.
        var indicesByArtist: [String: [Int]] = [:]
        let seedsByArtist = Dictionary(grouping: seeds, by: { artistKey($0) })
        let removedIds = Set(removed.map(\.videoId))
        let removedByArtist = Dictionary(grouping: removed, by: { artistKey($0) })
        func isRemoved(_ track: Track) -> Bool {
            removedIds.contains(track.videoId)
                || removedByArtist[artistKey(track), default: []].contains { isSameSong(track, $0) }
        }

        for (radioIndex, radio) in radios.enumerated() {
            // One contribution per radio per song, so a radio that lists two uploads of the
            // same song cannot vote for it twice.
            var counted = Set<Int>()
            var rank = 0
            for track in radio {
                if resultIds.contains(track.videoId) { continue }
                let artist = artistKey(track)
                if seedsByArtist[artist, default: []].contains(where: { isSameSong(track, $0) }) { continue }
                if isRemoved(track) { continue }
                rank += 1

                let existing = indexById[track.videoId]
                    ?? indicesByArtist[artist, default: []].first { isSameSong(track, candidates[$0].track) }
                let weight = 1.0 / (rankDamping + Double(rank))
                if let index = existing {
                    indexById[track.videoId] = index
                    candidates[index].ids.insert(track.videoId)
                    guard counted.insert(index).inserted else { continue }
                    candidates[index].score += weight
                    candidates[index].bestRank = min(candidates[index].bestRank, rank)
                } else {
                    indexById[track.videoId] = candidates.count
                    indicesByArtist[artist, default: []].append(candidates.count)
                    counted.insert(candidates.count)
                    candidates.append(Candidate(
                        track: track, score: weight, bestRank: rank,
                        firstRadio: radioIndex, ids: [track.videoId]
                    ))
                }
            }
        }

        // Each removed song's radio votes against what it lists, once per radio, weighted by
        // rank exactly as a seed's radio votes for. Its first entries are the removed song
        // itself and its closest neighbours, which are exactly what "less like this" means.
        var penalties = [Double](repeating: 0, count: candidates.count)
        for radio in removedRadios {
            var counted = Set<Int>()
            var rank = 0
            for track in radio {
                if isRemoved(track) { continue }
                rank += 1
                let artist = artistKey(track)
                guard let index = indexById[track.videoId]
                        ?? indicesByArtist[artist, default: []].first(where: { isSameSong(track, candidates[$0].track) }),
                      counted.insert(index).inserted else { continue }
                penalties[index] += 1.0 / (rankDamping + Double(rank))
            }
        }
        for index in candidates.indices where penalties[index] > 0 {
            candidates[index].score -= penalties[index]
        }
        // Cancelled out or worse: the songs a removal was about. Dropped rather than sunk, or a
        // short station would fill its tail with exactly what you asked to hear less of.
        candidates.removeAll { $0.score <= 0 }

        let ranked = candidates.sorted { a, b in
            let aAvoided = !a.ids.isDisjoint(with: avoiding)
            let bAvoided = !b.ids.isDisjoint(with: avoiding)
            if aAvoided != bAvoided { return !aAvoided }
            if a.score != b.score { return a.score > b.score }
            if a.bestRank != b.bestRank { return a.bestRank < b.bestRank }
            return a.firstRadio < b.firstRadio
        }

        for candidate in ranked {
            guard result.count < limit else { break }
            result.append(candidate.track)
        }
        return result
    }

    /// The first credited artist, folded — "Tame Impala, Rihanna" and "tame impala" share one.
    private static func artistKey(_ track: Track) -> String {
        (track.artist.components(separatedBy: ",").first ?? track.artist)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }
}
