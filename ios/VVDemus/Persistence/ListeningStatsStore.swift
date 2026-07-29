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

    /// Resolved once. It used to be a computed property that ran
    /// `FileManager.createDirectory` on every access — including inside the background
    /// write task, i.e. a filesystem syscall per save.
    private let fileURL: URL

    private let writer: HistoryWriter

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("listening_history.json")
        writer = HistoryWriter(fileURL: fileURL)
        load()
    }

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
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([PlayEvent].self, from: data) else {
            // Keep the file. Starting from an empty array and then saving over it would
            // destroy a year of history on the first track played after any decode
            // failure.
            NSLog("[ListeningStatsStore] history failed to decode — preserving it as .corrupt")
            try? FileManager.default.moveItem(
                at: fileURL,
                to: fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            )
            return
        }
        events = decoded
    }

    /// Encodes off the main thread — `record()` runs synchronously on every track change
    /// (skip, autoplay, "next"), and after months of history this array is big enough that
    /// encoding it inline was a real, avoidable hitch right as the next track starts loading.
    private func save() {
        writer.write(events)
    }
}

/// Serializes writes to the history file.
///
/// This was a bare `Task.detached` per save. Detached tasks are unordered and run
/// concurrently, so two `record()` calls in quick succession — a skip storm, or autoplay
/// advancing while the user also taps next — raced, and the task holding the *older,
/// smaller* snapshot could finish last and win. The write itself was atomic, so the file
/// was never corrupt; it just quietly lost events, permanently.
private actor HistoryWriter {
    private let fileURL: URL
    private var pending: [PlayEvent]?
    private var isWriting = false

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    nonisolated func write(_ events: [PlayEvent]) {
        Task { await self.enqueue(events) }
    }

    private func enqueue(_ events: [PlayEvent]) async {
        // Only the newest snapshot is worth writing; anything queued behind it is already
        // a subset of it. This coalesces a burst of skips into a single write.
        pending = events
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        while let next = pending {
            pending = nil
            guard let data = try? JSONEncoder().encode(next) else { continue }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
