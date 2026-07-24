import SwiftUI

struct HomeView: View {
    @ObservedObject var player: PlayerService
    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 12)

                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if let errorMessage {
                        ErrorRow(message: errorMessage) { Task { await load() } }
                    } else {
                        ForEach(tracks) { track in
                            TrackRow(track: track, isActive: player.currentTrack?.id == track.id)
                                .onTapGesture { player.play(track: track, queue: tracks) }
                        }
                    }
                }
                .padding(.bottom, 100)
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

    private func load() async {
        isLoading = tracks.isEmpty
        errorMessage = nil
        do {
            tracks = try await APIClient.shared.home()
        } catch {
            errorMessage = "Couldn't load Home.\nIs the backend running at 127.0.0.1:8000?"
        }
        isLoading = false
    }
}
