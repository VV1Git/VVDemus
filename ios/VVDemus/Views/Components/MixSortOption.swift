import Foundation

enum MixSortOption: String, CaseIterable {
    case order
    case title = "Title"
    case artist = "Artist"

    func label(orderLabel: String) -> String {
        self == .order ? orderLabel : rawValue
    }

    func apply(to tracks: [Track]) -> [Track] {
        switch self {
        case .order:
            return tracks
        case .title:
            return tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            return tracks.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        }
    }
}

func filterTracks(_ tracks: [Track], matching query: String) -> [Track] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return tracks }
    return tracks.filter {
        $0.title.localizedCaseInsensitiveContains(trimmed) || $0.artist.localizedCaseInsensitiveContains(trimmed)
    }
}

func totalDuration(of tracks: [Track]) -> TimeInterval {
    TimeInterval(tracks.compactMap(\.durationSeconds).reduce(0, +))
}
