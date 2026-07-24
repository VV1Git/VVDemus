import Foundation

/// A radio the user has started, remembered locally so it can show up as a shortcut
/// on Home/Library — mirrors Spotify's "<Song> Radio" tiles.
struct RadioStation: Identifiable, Codable, Equatable {
    var id: String { seedTrack.videoId }
    let seedTrack: Track
    var lastPlayedAt: Date

    var title: String { "\(seedTrack.title) Radio" }
}
