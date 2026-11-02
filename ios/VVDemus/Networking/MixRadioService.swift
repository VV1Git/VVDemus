import Foundation

/// What a build produced: the station, and every radio it read — so the caller can keep them
/// and rebuild after the next edit from the same inputs rather than from a fresh, different
/// answer from YouTube.
struct MixRadioBuild {
    var tracks: [Track]
    /// Keyed by the videoId each radio is for.
    var radios: [String: [Track]]
}

/// Fetches one radio per seed, and one per removed song, and hands them to `MixRadioBlend`.
///
/// Not `@MainActor`, for the same reason as `RadioRefreshService`: every seed is a YouTube
/// round trip, and the blend compares hundreds of titles, none of which belongs on the main
/// thread.
enum MixRadioService {
    /// How many removed songs' radios are read. The newest removals, which say the most about
    /// what you want now; each one costs a request the first time it is used.
    static let removedRadioLimit = 10

    /// - Parameters:
    ///   - known: radios already read, by videoId. Used in place of a request wherever one is
    ///     there — which is what makes removing a song take out the songs like it and leave
    ///     everything else where it was, rather than reshuffling the whole station.
    ///   - avoiding: what the station showed before, when this is a refresh. A refresh never
    ///     uses `known` for the picks: each pick's radio is read afresh and one page deeper,
    ///     so the blend has new songs to rank ahead of the ones being pushed back. A rebuild
    ///     after an edit passes the same set without `deeper`, to keep a refresh's order.
    static func build(
        seeds: [Track],
        removed: [Track] = [],
        avoiding: Set<String> = [],
        deeper: Bool? = nil,
        known: [String: [Track]] = [:],
        limit: Int = InnerTubeClient.radioLength,
        source: RadioSource = InnerTubeRadioSource(),
        isSameSong: (Track, Track) -> Bool = { InnerTubeClient.isSameSong($0, as: $1) }
    ) async throws -> MixRadioBuild {
        guard !seeds.isEmpty else { return MixRadioBuild(tracks: [], radios: [:]) }
        // A refresh is a build with something to avoid, unless the caller says otherwise.
        let deeper = deeper ?? !avoiding.isEmpty
        // Every removed song stays out of the station; only the newest few have their radios
        // read to steer by.
        let steering = Array(removed.suffix(removedRadioLimit))

        // Seeds first, then removed songs; `isSeed` keeps the two apart afterwards.
        let wanted = seeds.map { ($0, true) } + steering.map { ($0, false) }
        var radios = [[Track]](repeating: [], count: wanted.count)
        var fetched: [String: [Track]] = [:]
        var firstError: Error?

        await withTaskGroup(of: (Int, Result<[Track], Error>, Bool).self) { group in
            for (index, (track, isSeed)) in wanted.enumerated() {
                let goDeeper = deeper && isSeed
                if !goDeeper, let cached = known[track.videoId], !cached.isEmpty {
                    radios[index] = cached
                    continue
                }
                group.addTask {
                    do {
                        let page = try await source.page(seed: track.videoId, limit: InnerTubeClient.radioLength)
                        var tracks = page.tracks
                        if goDeeper, let token = page.continuation,
                           let next = try? await source.continuationPage(token) {
                            tracks += next.tracks
                        }
                        return (index, .success(tracks), isSeed)
                    } catch {
                        return (index, .failure(error), isSeed)
                    }
                }
            }
            for await (index, result, isSeed) in group {
                switch result {
                case .success(let tracks):
                    radios[index] = tracks
                    fetched[wanted[index].0.videoId] = tracks
                case .failure(let error):
                    // A removed song's radio failing only means steering less hard this time.
                    if isSeed { firstError = firstError ?? error }
                }
            }
        }

        let seedRadios = Array(radios.prefix(seeds.count))
        // One seed's radio failing still leaves a station like the rest of the set, which is
        // more use than an error. Only when every one of them failed is there nothing to
        // build from — the seeds alone are not a radio.
        if seedRadios.allSatisfy(\.isEmpty), let firstError { throw firstError }

        let tracks = MixRadioBlend.blend(
            seeds: seeds, radios: seedRadios, limit: limit, avoiding: avoiding,
            removed: removed, removedRadios: Array(radios.dropFirst(seeds.count)),
            isSameSong: isSameSong
        )
        return MixRadioBuild(tracks: tracks, radios: fetched)
    }
}
