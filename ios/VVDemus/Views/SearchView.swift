import SwiftUI

struct SearchView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject var coordinator: NavigationCoordinator
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var isLoading = false
    @State private var searchTask: Task<Void, Never>?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if isLoading && results.isEmpty {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty && !isLoading {
                    Text("No results for \"\(query)\"")
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    if recentSearches.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.largeTitle)
                                .foregroundStyle(Theme.textSecondary)
                            Text("Search songs and artists")
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        recentSearchList
                    }
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
                    .miniPlayerInset()
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
            .navigationTitle("Search")
            .navigationDestination(for: LibraryDestination.self) { destination in
                switch destination {
                case .liked:
                    LikedSongsView(player: player)
                case .playlist(let id):
                    PlaylistDetailView(playlistId: id, player: player)
                case .radio(let seed):
                    RadioDetailView(seedTrack: seed, player: player)
                case .daylist:
                    DaylistDetailView(player: player)
                case .downloads:
                    DownloadsView(player: player)
                case .stats:
                    StatsView(player: player)
                }
            }
            .environment(\.openRadio) { track in
                coordinator.homePath.append(LibraryDestination.radio(track))
                coordinator.selectedTab = .home
            }
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

    // MARK: - Recent searches

    /// Stored as a JSON array in a single defaults key. Re-running a past search is both
    /// the fastest way back to something you were just listening to and a nudge away from
    /// retyping a query character by character — every keystroke of which used to fire its
    /// own search request once the debounce elapsed.
    @AppStorage("recent_searches_v1") private var recentSearchesJSON = "[]"
    private static let recentSearchLimit = 8

    private var recentSearches: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(recentSearchesJSON.utf8))) ?? []
    }

    private var recentSearchList: some View {
        List {
            Section {
                ForEach(recentSearches, id: \.self) { term in
                    Button {
                        query = term
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(Theme.textSecondary)
                            Text(term)
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .listRowBackground(Theme.background)
                    .listRowSeparatorTint(Theme.card)
                }
                .onDelete { offsets in
                    var terms = recentSearches
                    terms.remove(atOffsets: offsets)
                    saveRecentSearches(terms)
                }
            } header: {
                Text("Recent searches")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .listStyle(.plain)
        .miniPlayerInset()
        .scrollContentBackground(.hidden)
    }

    private func rememberSearch(_ term: String) {
        var terms = recentSearches.filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        terms.insert(term, at: 0)
        saveRecentSearches(Array(terms.prefix(Self.recentSearchLimit)))
    }

    private func saveRecentSearches(_ terms: [String]) {
        guard let data = try? JSONEncoder().encode(terms) else { return }
        recentSearchesJSON = String(decoding: data, as: UTF8.self)
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
            // Only remembered once it actually returned something, so half-typed queries
            // that happened to match nothing don't clutter the list.
            if !results.isEmpty { rememberSearch(trimmed) }
        } catch {
            // A cancelled task is the *next* keystroke arriving, not a failed search.
            // Clearing here made the visible results vanish and "No results" flash whenever
            // a request was superseded more than 350ms in.
            guard !Task.isCancelled else { return }
            results = []
        }
        guard !Task.isCancelled else { return }
        isLoading = false
    }
}
