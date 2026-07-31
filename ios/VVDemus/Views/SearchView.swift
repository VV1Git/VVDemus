import SwiftUI

struct SearchView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject var coordinator: NavigationCoordinator
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if isLoading && results.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, results.isEmpty, !isLoading {
                    // A failed search used to render as "No results for …", which is a
                    // factual claim about the catalogue that the app had no basis for — the
                    // request never landed. It matters most for a rate limit, where the fix
                    // is to wait and the misreading is to type a different query.
                    ErrorRow(message: errorMessage) { retry() }
                } else if results.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty && !isLoading {
                    ContentUnavailableView.search(text: query)
                } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    if recentSearches.isEmpty {
                        ContentUnavailableView(
                            "Search Songs and Artists",
                            systemImage: "magnifyingglass",
                            description: Text("Find something to play.")
                        )
                    } else {
                        recentSearchList
                    }
                } else {
                    List {
                        ForEach(results) { track in
                            TrackRow(
                                track: track,
                                isActive: player.currentTrack?.id == track.id,
                                onTap: { player.play(track: track, context: results, contextTitle: "Search") }
                            )
                            .trackRowMetrics()
                            .trackActions(track: track, player: player)
                        }
                    }
                    .listStyle(.plain)
                    .scrollDismissesKeyboard(.immediately)
                }
            }
            .background(Theme.background)
            .navigationTitle("Search")
            // On the content, not on the `NavigationStack`: attached to the stack, the
            // "Songs, artists" field leaked into every pushed destination — including
            // `PlaylistDetailView`, which declares a search field of its own.
            .searchable(text: $query, prompt: "Songs, artists")
            .navigationDestination(for: LibraryDestination.self) { destination in
                destination.destination(player: player)
            }
            .environment(\.openRadio) { track in
                coordinator.homePath.append(LibraryDestination.radio(track))
                coordinator.selectedTab = .home
            }
        }
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
                        HStack(spacing: Theme.Space.md) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                                // As wide as a result row's artwork, so a recent search and a
                                // search result start their text on the same leading edge —
                                // the icon column plus the stack spacing is exactly
                                // `Theme.Metrics.separatorLeading`.
                                .frame(width: Theme.ArtSize.row, alignment: .leading)
                            Text(term)
                                .font(.rowTitle)
                                .foregroundStyle(.primary)
                            Spacer(minLength: Theme.Space.md)
                        }
                        .contentShape(Rectangle())
                    }
                    .trackRowMetrics()
                }
                .onDelete { offsets in
                    var terms = recentSearches
                    terms.remove(atOffsets: offsets)
                    saveRecentSearches(terms)
                }
            } header: {
                HStack {
                    Text("Recent Searches")
                    Spacer()
                    Button("Clear") { saveRecentSearches([]) }
                        .font(.controlLabel)
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
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

    /// Runs the current query again — the Retry button on a failed search, which for a rate
    /// limit is the one action that can actually succeed.
    private func retry() {
        searchTask?.cancel()
        let text = query
        searchTask = Task { await runSearch(text) }
    }

    private func runSearch(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            errorMessage = nil
            return
        }
        isLoading = true
        errorMessage = nil
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
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't search right now."
        }
        guard !Task.isCancelled else { return }
        isLoading = false
    }
}
