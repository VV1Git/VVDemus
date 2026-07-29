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

    /// How old a cached mix may be and still be reused for a shelf. Generous because these
    /// shelves are ambient browsing content — nobody notices, or wants to pay for, a
    /// freshly fetched "Because you listened to…" row every time Home appears.
    private static let cacheFreshness: TimeInterval = 30 * 60

    static func build(seeds: [Track], perSeedLimit: Int = InnerTubeClient.dataSaverLimit(default: 15)) async throws -> [Section] {
        guard !seeds.isEmpty else { return [] }
        // A radio fetched recently — by the autoplay engine, a radio screen, or a previous
        // Home load — is reused rather than fetched again. These shelves are built from the
        // same seeds the rest of the app is already pulling mixes for, so without this the
        // same ~36KB response was being paid for several times over.
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: the latter is a *trap*, not
        // an error, on a duplicate key. `PlayHistoryStore.record` dedupes on the way in but
        // `load()` doesn't, so any persisted history containing the same videoId twice — an
        // older build, a restored backup — crashed the app every single time Home appeared,
        // with no way out but deleting the app.
        let cached = await MainActor.run {
            Dictionary(
                seeds.map { seed in
                    (seed.videoId, RadioCacheStore.shared.isFresh(seed.videoId, within: cacheFreshness)
                        ? RadioCacheStore.shared.tracks(for: seed.videoId)
                        : nil)
                },
                uniquingKeysWith: { first, _ in first }
            )
        }

        // Each child returns its own failure instead of throwing, because
        // `for try await` rethrows the first error and cancels every sibling: one flaky
        // seed radio meant the whole Home feed vanished, on exactly the poor connection
        // where a partial feed matters most. A shelf that failed is simply left empty and
        // filtered out below; only a total wipeout is worth reporting.
        let radios = await withTaskGroup(of: (Int, [Track]).self) { group -> [[Track]] in
            for (index, seed) in seeds.enumerated() {
                if let hit = cached[seed.videoId] ?? nil, !hit.isEmpty {
                    group.addTask { (index, Array(hit.dropFirst())) }
                    continue
                }
                group.addTask {
                    guard let mix = try? await APIClient.shared.radio(videoId: seed.videoId, limit: perSeedLimit) else {
                        return (index, [])
                    }
                    // Never overwrites an existing mix: these shelves fetch a short slice,
                    // and writing it through would shrink the radio's own screen to match.
                    await MainActor.run { RadioCacheStore.shared.storeIfAbsent(mix, for: seed.videoId) }
                    return (index, Array(mix.dropFirst()))
                }
            }
            var results = Array(repeating: [Track](), count: seeds.count)
            for await (index, tracks) in group { results[index] = tracks }
            return results
        }
        // Every seed failed — that's a real error (offline), not a thin feed.
        if radios.allSatisfy(\.isEmpty) {
            throw APIError.server("Couldn't load recommendations.")
        }
        return zip(seeds, radios).compactMap { seed, tracks in
            let songs = tracks.excludingLongFormMixes()
            return songs.isEmpty ? nil : Section(title: "Because you listened to \(seed.title)", tracks: songs)
        }
    }
}

/// The assembled Home feed, cached on disk with a time-to-live.
///
/// Building it costs six InnerTube responses (three seed radios plus three Quick Picks
/// searches, ~35KB each over the wire), and it was rebuilt from scratch every time Home
/// appeared and every time the web remote was opened — several times a day, for content
/// that barely changes hour to hour. Now it's fetched once per `freshness` window and
/// reused everywhere; pull-to-refresh still forces a rebuild.
@MainActor
final class HomeFeedStore: ObservableObject {
    static let shared = HomeFeedStore()

    @Published private(set) var sections: [RecommendationsBuilder.Section] = []
    @Published private(set) var isLoading = false
    private(set) var generatedAt: Date?

    private let key = "home_feed_v2" // v1 shelves predate the long-form mix filter
    private let freshness: TimeInterval = 30 * 60
    /// Shared so that Home appearing and the web remote asking at the same moment produce
    /// one fetch between them, not two.
    private var inFlight: Task<[RecommendationsBuilder.Section], Error>?

    private init() { load() }

    var isFresh: Bool {
        guard let generatedAt, !sections.isEmpty else { return false }
        return Date().timeIntervalSince(generatedAt) < freshness
    }

    @discardableResult
    func refreshIfNeeded() async throws -> [RecommendationsBuilder.Section] {
        if isFresh { return sections }
        return try await refresh()
    }

    @discardableResult
    func refresh() async throws -> [RecommendationsBuilder.Section] {
        if let inFlight { return try await inFlight.value }
        let task = Task { () throws -> [RecommendationsBuilder.Section] in
            async let quickPicks = APIClient.shared.home()
            var built = try await RecommendationsBuilder.build(seeds: PlayHistoryStore.shared.recentSeeds(3))
            if let picks = try? await quickPicks, !picks.isEmpty {
                built.append(RecommendationsBuilder.Section(title: "Quick Picks", tracks: picks))
            }
            return built
        }
        inFlight = task
        isLoading = sections.isEmpty
        defer {
            inFlight = nil
            isLoading = false
        }
        let built = try await task.value
        // An empty result (offline, or no history yet) shouldn't throw away a perfectly
        // good cached feed — better to keep showing yesterday's shelves than nothing.
        if !built.isEmpty {
            sections = built
            generatedAt = Date()
            save()
        }
        return sections
    }

    private struct Snapshot: Codable {
        let sections: [RecommendationsBuilder.Section]
        let generatedAt: Date
    }

    private func load() {
        guard let snapshot = DefaultsSnapshot.load(Snapshot.self, forKey: key) else { return }
        sections = snapshot.sections
        generatedAt = snapshot.generatedAt
    }

    private func save() {
        guard let generatedAt, let data = try? JSONEncoder().encode(Snapshot(sections: sections, generatedAt: generatedAt)) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
