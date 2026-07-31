import SwiftUI

/// Navigation targets reachable from both Home shortcuts and the Library tab.
enum LibraryDestination: Hashable {
    case liked
    case playlist(UUID)
    case radio(Track)
    case daylist
    case downloads
    case stats
    case settings
}

extension LibraryDestination {
    /// The one place a destination becomes a screen. Home and Library each used to carry
    /// their own copy of this switch, so every new case had to be added twice.
    @ViewBuilder
    func destination(player: PlayerService) -> some View {
        switch self {
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
        case .settings:
            SettingsView()
        }
    }
}
