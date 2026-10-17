import Foundation

/// Fetches one radio per seed and hands them to `MixRadioBlend`.
///
/// Not `@MainActor`, for the same reason as `RadioRefreshService`: every seed is a YouTube
/// round trip, and the blend compares hundreds of titles, none of which belongs on the main
/// thread.
enum MixRadioService {
    /// - Parameter avoiding: what the station showed before, when this is a refresh. Each
    ///   seed's radio is then read one page deeper too, so the blend has new songs to rank
    ///   ahead of the ones being pushed back. A first build has nothing to avoid and does not
    ///   spend the extra requests.
    static func build(
        seeds: [Track],
        avoiding: Set<String> = [],
        limit: Int = InnerTubeClient.radioLength,
        source: RadioSource = InnerTubeRadioSource(),
        isSameSong: (Track, Track) -> Bool = { InnerTubeClient.isSameSong($0, as: $1) }
    ) async throws -> [Track] {
        guard !seeds.isEmpty else { return [] }
        let deeper = !avoiding.isEmpty

        var radios = [[Track]](repeating: [], count: seeds.count)
        var firstError: Error?
        await withTaskGroup(of: (Int, Result<[Track], Error>).self) { group in
            for (index, seed) in seeds.enumerated() {
                group.addTask {
                    do {
                        let page = try await source.page(seed: seed.videoId, limit: InnerTubeClient.radioLength)
                        var tracks = page.tracks
                        if deeper, let token = page.continuation,
                           let next = try? await source.continuationPage(token) {
                            tracks += next.tracks
                        }
                        return (index, .success(tracks))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for await (index, result) in group {
                switch result {
                case .success(let tracks): radios[index] = tracks
                case .failure(let error): firstError = firstError ?? error
                }
            }
        }

        // One seed's radio failing still leaves a station like the rest of the set, which is
        // more use than an error. Only when every one of them failed is there nothing to
        // build from — the seeds alone are not a radio.
        if radios.allSatisfy(\.isEmpty), let firstError { throw firstError }

        return MixRadioBlend.blend(seeds: seeds, radios: radios, limit: limit, avoiding: avoiding,
                                   isSameSong: isSameSong)
    }
}
