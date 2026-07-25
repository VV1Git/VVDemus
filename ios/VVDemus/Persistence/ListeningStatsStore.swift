import Foundation

/// A timestamped log of every track actually played, backing the Stats screen's
/// "top artists/songs over the last week/month/3 months/year" breakdowns. Stored as a
/// JSON file (not UserDefaults) since a year of listening can run into the thousands of
/// entries — pruned to ~13 months so it never grows unbounded.
@MainActor
final class ListeningStatsStore: ObservableObject {
    static let shared = ListeningStatsStore()

    @Published private(set) var events: [PlayEvent] = []

    private let maxAgeDays = 396 // ~13 months, one month of slack past the 1-year range

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("listening_history.json")
    }

    private init() { load() }

    func record(_ track: Track, secondsPlayed: Int) {
        guard secondsPlayed >= 5 else { return } // ignore accidental taps/quick skips
        events.append(PlayEvent(track: track, playedAt: Date(), secondsPlayed: secondsPlayed))
        prune()
        save()
    }

    func events(since date: Date) -> [PlayEvent] {
        events.filter { $0.playedAt >= date }
    }

    private func prune() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()) else { return }
        events.removeAll { $0.playedAt < cutoff }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PlayEvent].self, from: data) else { return }
        events = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
