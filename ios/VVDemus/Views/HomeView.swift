import SwiftUI

private struct HomeSection: Identifiable {
    let id = UUID()
    let title: String
    let tracks: [Track]
}

struct HomeView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject private var history = PlayHistoryStore.shared
    @State private var sections: [HomeSection] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(greeting)
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    if isLoading && sections.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if let errorMessage, sections.isEmpty {
                        ErrorRow(message: errorMessage) { Task { await load() } }
                    } else {
                        ForEach(sections) { section in
                            HomeShelf(title: section.title, tracks: section.tracks, player: player)
                        }
                    }
                }
                .padding(.bottom, 110)
            }
            .background(Theme.background)
            .navigationBarHidden(true)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 0..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    /// Builds "Because you listened to…" shelves from recent local play history, plus a
    /// generic Quick Picks shelf, mirroring Spotify's mix of personalized and general rows.
    private func load() async {
        isLoading = sections.isEmpty
        errorMessage = nil
        do {
            async let quickPicks = APIClient.shared.home()

            let seeds = history.recentSeeds(3)
            var built: [HomeSection] = []

            if !seeds.isEmpty {
                let radios = try await withThrowingTaskGroup(of: (Int, [Track]).self) { group -> [[Track]] in
                    for (index, seed) in seeds.enumerated() {
                        group.addTask {
                            let mix = try await APIClient.shared.radio(videoId: seed.videoId, limit: 15)
                            return (index, Array(mix.dropFirst()))
                        }
                    }
                    var results = Array(repeating: [Track](), count: seeds.count)
                    for try await (index, tracks) in group { results[index] = tracks }
                    return results
                }
                for (seed, tracks) in zip(seeds, radios) where !tracks.isEmpty {
                    built.append(HomeSection(title: "Because you listened to \(seed.title)", tracks: tracks))
                }
            }

            let picks = try await quickPicks
            if !picks.isEmpty {
                built.append(HomeSection(title: "Quick Picks", tracks: picks))
            }
            sections = built
        } catch {
            if sections.isEmpty {
                errorMessage = "Couldn't load Home.\nIs the backend running at 127.0.0.1:8000?"
            }
        }
        isLoading = false
    }
}
