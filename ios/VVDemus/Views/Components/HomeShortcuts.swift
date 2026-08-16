import Foundation

/// One tile in Home's shortcut grid.
///
/// Carries a `recency` alongside the thing itself because the grid is one list ordered by
/// when you last opened something, not three lists concatenated by kind. Each kind answers
/// that question from a different place — see `RecentOpensStore` — and the tile is where the
/// answers are put on the same footing.
struct HomeShortcut: Identifiable {
    enum Kind {
        case likedSongs
        case radio(RadioStation)
        case playlist(Playlist)
        case album(Album)
    }

    let kind: Kind
    let recency: Date

    var id: String {
        switch kind {
        case .likedSongs: return "liked"
        case .radio(let station): return "radio-\(station.id)"
        case .playlist(let playlist): return "playlist-\(playlist.id)"
        case .album(let album): return "album-\(album.browseId)"
        }
    }
}

/// Which shortcuts Home offers, and in what order.
///
/// A free function over plain values rather than a computed property on the view: the
/// ordering is the whole of the behaviour, it reads four stores to produce it, and none of
/// those stores can be stood up in a test without writing into the app's real defaults.
enum HomeShortcuts {
    /// Everything eligible, newest first, with Liked Songs pinned to the front.
    ///
    /// One ordering across all four kinds rather than a fixed run of radios followed by a
    /// fixed run of playlists: with the grid capped, grouping by kind meant an album opened a
    /// minute ago could be pushed off Home by a radio nobody had touched in a month.
    ///
    /// Liked Songs is exempt because it is not a thing you open so much as a place — it has
    /// no recency worth comparing against a record you played this morning, and it is the one
    /// tile that should always be in the same spot.
    ///
    /// - Parameters:
    ///   - albumOpenedAt: the album's own recorded visit, from `AlbumHistoryStore`.
    ///   - openedAt: this device's "last opened" log, from `RecentOpensStore`. Consulted for
    ///     every kind, so a radio read without being played and a playlist made a year ago
    ///     but opened a minute ago both sort where they belong.
    static func ranked(
        hasLikedSongs: Bool,
        radios: [RadioStation],
        playlists: [Playlist],
        albums: [Album],
        albumOpenedAt: (String) -> Date?,
        openedAt: (String) -> Date?
    ) -> [HomeShortcut] {
        func newest(_ own: Date, _ key: String) -> Date {
            max(own, openedAt(key) ?? .distantPast)
        }

        var items: [HomeShortcut] = []
        items.append(contentsOf: radios.map { station in
            HomeShortcut(
                kind: .radio(station),
                recency: newest(station.lastPlayedAt, RecentOpensStore.radioKey(station.id))
            )
        })
        items.append(contentsOf: playlists.map { playlist in
            HomeShortcut(
                kind: .playlist(playlist),
                recency: newest(playlist.createdAt, RecentOpensStore.playlistKey(playlist.id))
            )
        })
        items.append(contentsOf: albums.map { album in
            HomeShortcut(
                kind: .album(album),
                // The album store already records on open, so its own timestamp is normally
                // the answer; the open log is consulted anyway so the two cannot disagree
                // after a sync brings an older record over.
                recency: newest(
                    albumOpenedAt(album.browseId) ?? .distantPast,
                    RecentOpensStore.albumKey(album.browseId)
                )
            )
        })

        // Ties broken by id, so two things opened in the same clock tick — which a merge
        // replaying a batch will produce — don't swap places between renders.
        items.sort { $0.recency == $1.recency ? $0.id < $1.id : $0.recency > $1.recency }

        if hasLikedSongs {
            items.insert(HomeShortcut(kind: .likedSongs, recency: .distantFuture), at: 0)
        }
        return items
    }
}
