import SwiftUI

struct SearchView: View {
    @ObservedObject var player: PlayerService
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var isLoading = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty && !isLoading {
                    Text("No results for \"\(query)\"")
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(Theme.textSecondary)
                        Text("Search songs and artists")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(results) { track in
                            TrackRow(track: track, isActive: player.currentTrack?.id == track.id)
                                .listRowBackground(Theme.background)
                                .listRowSeparatorTint(Theme.card)
                                .onTapGesture { player.play(track: track, context: results, contextTitle: "Search") }
                                .trackActions(track: track, player: player)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
            .navigationTitle("Search")
        }
        .searchable(text: $query, prompt: "Songs, artists")
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await runSearch(newValue)
            }
        }
    }

    private func runSearch(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        isLoading = true
        do {
            results = try await APIClient.shared.search(trimmed)
        } catch {
            results = []
        }
        isLoading = false
    }
}
