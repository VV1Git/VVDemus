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
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, track in
                            TrackRow(
                                track: track,
                                isActive: player.currentTrack?.id == track.id,
                                onTap: { player.play(track: track, context: results, contextTitle: "Search") }
                            )
                            .trackRowMetrics()
                            .trackActions(track: track, player: player)
                            // Every other list using `trackRowMetrics()` has a section header
                            // above its first track, so row 0's top separator divides two real
                            // things. Here it hangs under the search field, inset 76pt to the
                            // title column with nothing to its left to justify the indent — a
                            // stub line rather than a divider.
                            .listRowSeparator(index == 0 ? .hidden : .automatic, edges: .top)
                        }
                    }
                    .listStyle(.plain)
                    .dismissesKeyboardOnScroll()
                }
            }
            // Before the background, not after. `ContentUnavailableView` takes its intrinsic
            // size on macOS rather than filling, so the black was painted as a centred box
            // with the window's default grey around it — the empty state read as a slab
            // dropped onto the page. Every other branch here is a List, which fills on its
            // own, which is why only the empty state showed it.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                // The Mac has no tab bar: `MacRootView` drives its detail pane from its own
                // sidebar selection and never reads `selectedTab`. Pushing onto Home's path
                // there did nothing at the moment you asked for it, and then opened Home on a
                // radio screen the next time you clicked Home, with nothing to explain it.
                // This screen owns a stack, so push onto that. The phone keeps switching to
                // the Home tab, where that path is the one actually on screen.
                #if os(macOS)
                path.append(LibraryDestination.radio(track))
                #else
                coordinator.homePath.append(LibraryDestination.radio(track))
                coordinator.selectedTab = .home
                #endif
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
                                // The same font as the title beside it. Left unset, the glyph
                                // takes the row's environment font instead — which is not
                                // `rowTitle` and rendered the clock noticeably larger than the
                                // word next to it, so the icon read as the subject of the row
                                // rather than a marker on it.
                                .font(.rowTitle)
                                .foregroundStyle(.secondary)
                                // As wide as a result row's artwork, so a recent search and a
                                // search result start their text on the same leading edge —
                                // the icon column plus the stack spacing is exactly
                                // `Theme.Metrics.separatorLeading`.
                                //
                                // Centred in that column, not pinned to its leading edge. A 19pt
                                // glyph left-aligned in a 48pt slot sits against the screen edge
                                // with a 43pt void before the label, where the artwork it stands
                                // in for fills the slot and leaves a 12pt gap.
                                .frame(width: Theme.ArtSize.row)
                            Text(term)
                                .font(.rowTitle)
                                .foregroundStyle(.primary)
                            Spacer(minLength: Theme.Space.md)
                        }
                        .contentShape(Rectangle())
                    }
                    // Without this the row is a *control*, not a row. macOS gives a `Button` in a
                    // list the automatic style, which paints a tinted rounded background and
                    // recolours the whole label to the accent — so the `.primary` title and
                    // `.secondary` clock above were both overridden and every recent search read
                    // as a green pill. The phone's borderless default never showed it.
                    .buttonStyle(.plain)
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
        .dismissesKeyboardOnScroll()
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
        // Cleared here rather than at the end, because three of this function's four exits
        // used to skip that line: the empty-query return below and both cancellation guards.
        // Delete a slow search's query and you were left with a spinner that never stopped —
        // the emptied query's run returns before it ever touches `isLoading`, so nothing
        // downstream would have cleared it either.
        //
        // Skipped when cancelled for the same reason the guards exist: the successor search
        // has already set `isLoading` for itself by the time a cancelled `retry()` run
        // unwinds, and clearing it here would hide that one's spinner instead.
        defer { if !Task.isCancelled { isLoading = false } }
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
    }
}
