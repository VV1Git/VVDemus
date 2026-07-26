import Foundation

struct Track: Identifiable, Codable, Equatable, Hashable {
    let videoId: String
    let title: String
    let artist: String
    let album: String?
    let thumbnailUrl: String?
    let durationSeconds: Int?

    var id: String { videoId }
}

struct StreamInfo: Codable {
    let videoId: String
    let url: String
    let expiresAt: Double
    let mimeType: String
}

extension Track {
    /// Anything longer than a song plausibly is: the hour-long "Zen Meditation Music",
    /// "Coffee Shop Jazz", "Continuous Mix" and "Top 100" uploads that YouTube Music
    /// classifies as songs and happily returns for broad, mood-flavoured queries like
    /// "morning chill mix". They're indistinguishable from real tracks in the response —
    /// only their length gives them away — and one of them landing in a generated mix
    /// hijacks the queue for the next three hours.
    ///
    /// The threshold sits well clear of long real songs (Echoes, In-A-Gadda-Da-Vida and
    /// friends all come in under 18 minutes) while catching compilations, which start
    /// around the hour mark. Tracks whose length is unknown are given the benefit of the
    /// doubt rather than being dropped.
    var isLongFormMix: Bool {
        guard let durationSeconds else { return false }
        return durationSeconds > Track.longFormMixThreshold
    }

    static let longFormMixThreshold = 20 * 60
}

extension Sequence where Element == Track {
    /// Strips long-form compilations out of automatically generated listening — the
    /// daylist, Quick Picks, recommendation shelves, radios and autoplay. Deliberately not
    /// applied to search results: if someone searches for three hours of rain sounds,
    /// that's exactly what they should get.
    func excludingLongFormMixes() -> [Track] {
        filter { !$0.isLongFormMix }
    }
}
