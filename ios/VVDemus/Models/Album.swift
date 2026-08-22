import Foundation

/// One release from YouTube Music's catalogue — an album, single or EP.
///
/// Identified by its `browseId` (always `MPRE…`), which is what the album page is fetched
/// with. The `audioPlaylistId` (`OLAK5uy_…`) is carried alongside because search hands it
/// over for free and it is the only other handle YouTube offers on a release; nothing reads
/// it yet, and the track list deliberately comes from the browse page instead — the
/// playlist endpoint returns raw upload titles ("Daft Punk - One More Time (Official
/// Video)") where browse returns the track name the album actually prints ("One More Time").
struct Album: Identifiable, Codable, Equatable, Hashable {
    let browseId: String
    let title: String
    let artist: String
    /// "Album", "Single" or "EP", as YouTube labels it. Kept rather than assumed, so a
    /// two-track single isn't presented as an album.
    let kind: String
    let year: String?
    let thumbnailUrl: String?
    let audioPlaylistId: String?

    var id: String { browseId }

    /// The byline under the title, everywhere one is drawn: "Album · Daft Punk · 2001".
    var subtitle: String {
        [kind, artist, year].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A search result, which is a song or a release. The two are interleaved in one list rather
/// than stacked in separate sections, so `SearchView` needs a single element type to iterate.
enum SearchResult: Identifiable, Equatable, Hashable {
    case track(Track)
    case album(Album)

    /// Prefixed by kind. A release and one of its songs can share neither id today, but
    /// `videoId` and `browseId` are two different namespaces and nothing guarantees that
    /// stays true — an id collision inside a `ForEach` drops rows silently.
    var id: String {
        switch self {
        case .track(let track): return "t:\(track.videoId)"
        case .album(let album): return "a:\(album.browseId)"
        }
    }
}

extension SearchResult {
    /// How many songs sit between one release and the next.
    private static let albumStride = 4

    /// Folds releases into the song list.
    ///
    /// The top song stays first, deliberately: a query that names a song ("one more time")
    /// must not be answered by an album, and YouTube's album filter always returns
    /// *something* for any query at all. Releases then appear one every `albumStride` rows,
    /// starting at the second — close enough to the top to be impossible to miss on a query
    /// that did mean an album, without pushing the songs off the first screen.
    ///
    /// Releases left over when the songs run out are appended, so a search that matched four
    /// albums and one song still shows all four.
    static func interleave(tracks: [Track], albums: [Album]) -> [SearchResult] {
        guard !albums.isEmpty else { return tracks.map(SearchResult.track) }
        var results: [SearchResult] = []
        results.reserveCapacity(tracks.count + albums.count)
        var next = 0
        for (index, track) in tracks.enumerated() {
            if index > 0, (index - 1) % albumStride == 0, next < albums.count {
                results.append(.album(albums[next]))
                next += 1
            }
            results.append(.track(track))
        }
        results.append(contentsOf: albums[next...].map(SearchResult.album))
        return results
    }
}
