import Foundation

/// A radio built from several songs at once rather than one.
///
/// The songs you picked play first, in the order you picked them, and everything after them is
/// chosen for being like the *set* — not like the first of them, which is all a single-seed
/// radio can offer. See `MixRadioBlend` for how "like the set" is decided.
struct MixRadio: Hashable {
    let seeds: [Track]

    /// Stable for one set of seeds in one order, so the same pick opens the same screen.
    var id: String { seeds.map(\.videoId).joined(separator: "+") }

    var title: String {
        switch seeds.count {
        case 0: return "Mix Radio"
        case 1: return "\(seeds[0].title) Radio"
        case 2: return "\(seeds[0].title) + \(seeds[1].title) Radio"
        default: return "\(seeds[0].title) + \(seeds.count - 1) More Radio"
        }
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
    ///   - isSameSong: whether two different uploads are the same song, so a video and its
    ///     `- Topic` audio copy arriving from two radios count as one song shared by both
    ///     rather than two songs each found once.
    static func blend(
        seeds: [Track],
        radios: [[Track]],
        limit: Int,
        avoiding: Set<String> = [],
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

        for (radioIndex, radio) in radios.enumerated() {
            // One contribution per radio per song, so a radio that lists two uploads of the
            // same song cannot vote for it twice.
            var counted = Set<Int>()
            var rank = 0
            for track in radio {
                if resultIds.contains(track.videoId) { continue }
                let artist = artistKey(track)
                if seedsByArtist[artist, default: []].contains(where: { isSameSong(track, $0) }) { continue }
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
