import SwiftUI

enum MixSortOption: String, CaseIterable, Identifiable {
    case order
    case title = "Title"
    case artist = "Artist"

    var id: String { rawValue }

    /// One parallel set of names on all four collection screens. The old per-screen wording
    /// ("Playlist order" / "Recommended order") claimed things that weren't true — a daylist's
    /// order is chronological, not recommended — and made the same control read differently
    /// on every screen.
    var label: String {
        switch self {
        case .order: return "Default Order"
        case .title: return "Title"
        case .artist: return "Artist"
        }
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

/// The sort control every collection screen puts at the top of its ellipsis menu.
///
/// An inline `Picker` rather than a row of `Button`s: the system draws the checkmark next to
/// the active option, so the menu finally says which sort is in effect.
struct MixSortPicker: View {
    @Binding var selection: MixSortOption

    var body: some View {
        Picker("Sort By", selection: $selection) {
            ForEach(MixSortOption.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.inline)
    }
}

extension View {
    /// Metrics for a `MixDetailHeader` sitting as the first row of a collection's `List`.
    /// The header draws no horizontal padding of its own, so the row inset is what keeps the
    /// hero on the same leading edge as the track rows below it.
    func mixHeaderRowMetrics() -> some View {
        self.listRowInsets(EdgeInsets(top: 0, leading: Theme.Metrics.gutter,
                                      bottom: Theme.Space.lg, trailing: Theme.Metrics.gutter))
            .listRowSeparator(.hidden)
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
