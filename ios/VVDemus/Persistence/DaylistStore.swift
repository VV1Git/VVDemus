import Foundation

/// A lightweight "daylist": a mix that leans on the time of day plus recent listening
/// history, refreshable on demand and auto-regenerated once the time-of-day bucket
/// changes (morning/afternoon/evening/night) — approximating Spotify's daylist without
/// any personalization backend, just local history + a mood-flavored search seed.
@MainActor
final class DaylistStore: ObservableObject {
    static let shared = DaylistStore()

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var title: String = ""
    @Published private(set) var generatedAt: Date?
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?

    private let key = "daylist_v1"

    private struct Snapshot: Codable {
        let title: String
        let tracks: [Track]
        let generatedAt: Date
    }

    private init() { load() }

    /// Regenerates only if the time-of-day bucket has moved on since the last mix, or
    /// there's nothing cached yet — avoids re-fetching every time Home appears.
    func refreshIfNeeded() async {
        if let generatedAt, Self.bucket(for: generatedAt) == Self.currentBucket, !tracks.isEmpty {
            return
        }
        await refresh()
    }

    func refresh() async {
        isRefreshing = true
        errorMessage = nil
        do {
            let bucket = Self.currentBucket
            let seeds = PlayHistoryStore.shared.recentSeeds(3)

            async let moodResults = APIClient.shared.search(bucket.searchQuery, limit: InnerTubeClient.dataSaverLimit(default: 15))

            var pool: [Track] = []
            var seen = Set<String>()

            if !seeds.isEmpty {
                let radioLists = try await withThrowingTaskGroup(of: [Track].self) { group -> [[Track]] in
                    for seed in seeds {
                        group.addTask {
                            let mix = try await APIClient.shared.radio(videoId: seed.videoId, limit: InnerTubeClient.dataSaverLimit(default: 10))
                            return Array(mix.dropFirst())
                        }
                    }
                    var results: [[Track]] = []
                    for try await list in group { results.append(list) }
                    return results
                }
                for list in radioLists {
                    for track in list where !seen.contains(track.id) {
                        seen.insert(track.id)
                        pool.append(track)
                    }
                }
            }

            for track in try await moodResults where !seen.contains(track.id) {
                seen.insert(track.id)
                pool.append(track)
            }

            guard !pool.isEmpty else {
                throw APIError.server("No recommendations available right now.")
            }

            tracks = Array(pool.shuffled().prefix(30))
            title = Self.title(for: bucket)
            generatedAt = Date()
            save()
        } catch {
            errorMessage = "Couldn't build your Daylist right now."
        }
        isRefreshing = false
    }

    // MARK: - Time-of-day bucket

    enum Bucket {
        case morning, afternoon, evening, night

        var searchQuery: String {
            switch self {
            case .morning: return "morning chill mix"
            case .afternoon: return "afternoon vibes"
            case .evening: return "evening chill mix"
            case .night: return "late night vibes"
            }
        }

        var label: String {
            switch self {
            case .morning: return "Morning"
            case .afternoon: return "Afternoon"
            case .evening: return "Evening"
            case .night: return "Late Night"
            }
        }
    }

    static var currentBucket: Bucket { bucket(for: Date()) }

    static func bucket(for date: Date) -> Bucket {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return .morning
        case 12..<17: return .afternoon
        case 17..<21: return .evening
        default: return .night
        }
    }

    private static func title(for bucket: Bucket) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return "\(formatter.string(from: Date())) \(bucket.label) Mix"
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        title = snapshot.title
        tracks = snapshot.tracks
        generatedAt = snapshot.generatedAt
    }

    private func save() {
        guard let generatedAt else { return }
        let snapshot = Snapshot(title: title, tracks: tracks, generatedAt: generatedAt)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
