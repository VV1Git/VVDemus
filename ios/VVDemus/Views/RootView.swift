import SwiftUI

struct RootView: View {
    @StateObject private var player = PlayerService.shared
    @State private var showNowPlaying = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                HomeView(player: player)
                    .tabItem { Label("Home", systemImage: "house.fill") }

                SearchView(player: player)
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }

                LibraryView(player: player)
                    .tabItem { Label("Library", systemImage: "books.vertical.fill") }
            }
            .tint(Theme.accent)

            if player.currentTrack != nil {
                MiniPlayerBar(player: player)
                    .padding(.bottom, 49)
                    .onTapGesture { showNowPlaying = true }
            }
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView(player: player)
        }
    }
}
