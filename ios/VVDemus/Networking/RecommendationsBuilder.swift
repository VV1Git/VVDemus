import Foundation

/// Builds "Because you listened to…" shelves from recent play history — one seed track per
/// shelf, fetched concurrently. Shared by HomeView (native UI) and LocalControlServer (web
/// remote) so the personalization logic only lives in one place.
enum RecommendationsBuilder {
    struct Section: Identifiable, Codable {
        var id: String { title }
        let title: String
        let tracks: [Track]
    }

    static func build(seeds: [Track], perSeedLimit: Int = 15) async throws -> [Section] {
        guard !seeds.isEmpty else { return [] }
        let radios = try await withThrowingTaskGroup(of: (Int, [Track]).self) { group -> [[Track]] in
            for (index, seed) in seeds.enumerated() {
                group.addTask {
                    let mix = try await APIClient.shared.radio(videoId: seed.videoId, limit: perSeedLimit)
                    return (index, Array(mix.dropFirst()))
                }
            }
            var results = Array(repeating: [Track](), count: seeds.count)
            for try await (index, tracks) in group { results[index] = tracks }
            return results
        }
        return zip(seeds, radios).compactMap { seed, tracks in
            tracks.isEmpty ? nil : Section(title: "Because you listened to \(seed.title)", tracks: tracks)
        }
    }
}
