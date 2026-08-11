import XCTest
@testable import VVDemus

/// The one place the import feature touches whatever a person happened to have on their
/// clipboard. Everything downstream of it — the fetch, the parse, the matcher — assumes it was
/// handed a playlist id, so every way a paste can be malformed has to be settled here, and all
/// of it is a string in and a string out: no network, no page, nothing to stub.
final class SpotifyPlaylistLinkTests: XCTestCase {

    /// The 22-character id used throughout: Spotify's own "Today's Top Hits".
    private let topHits = "37i9dQZF1DXcBWIGoYBM5M"

    // MARK: - What the share sheets actually produce

    func testTheiOSShareSheetLinkIsAccepted() {
        XCTAssertEqual(
            SpotifyPlaylistLink.playlistId(from: "https://open.spotify.com/playlist/\(topHits)?si=ab12cd34"),
            topHits,
            "This is verbatim what iOS's Share > Copy Link hands over; if this one form fails the "
                + "feature is unusable for almost everybody")
    }

    func testExtraTrackingParametersAreIgnored() {
        XCTAssertEqual(
            SpotifyPlaylistLink.playlistId(
                from: "https://open.spotify.com/playlist/\(topHits)?si=ab12cd34&pt=9f0e&nd=1"),
            topHits,
            "Sharing through Messages or a browser appends more than si=; the id is the only part "
                + "that means anything to us")
    }

    func testTheDesktopAppsURIFormIsAccepted() {
        XCTAssertEqual(SpotifyPlaylistLink.playlistId(from: "spotify:playlist:\(topHits)"), topHits,
                       "The desktop client's Copy Spotify URI gives this shape, not a URL")
    }

    func testALocalisedPathIsAccepted() {
        XCTAssertEqual(SpotifyPlaylistLink.playlistId(from: "https://open.spotify.com/intl-ja/playlist/\(topHits)"),
                       topHits,
                       "Spotify inserts a locale segment for non-English users; treating that as an "
                        + "unknown path would break the link for everyone outside en")
        XCTAssertEqual(SpotifyPlaylistLink.playlistId(from: "open.spotify.com/intl-de/playlist/\(topHits)?si=x"),
                       topHits)
    }

    func testSurroundingWhitespaceAndNewlinesAreTrimmed() {
        XCTAssertEqual(
            SpotifyPlaylistLink.playlistId(from: "  https://open.spotify.com/playlist/\(topHits)\n"),
            topHits,
            "A link pasted out of Notes or a chat message arrives with a trailing newline, and the "
                + "user cannot see it to delete it")
    }

    // MARK: - The other shapes people paste

    func testASchemelessLinkIsAccepted() {
        XCTAssertEqual(SpotifyPlaylistLink.playlistId(from: "open.spotify.com/playlist/\(topHits)"), topHits,
                       "Copying the text of a link, rather than the link, drops the scheme")
    }

    func testPlainHTTPIsAccepted() {
        XCTAssertEqual(SpotifyPlaylistLink.playlistId(from: "http://open.spotify.com/playlist/\(topHits)"), topHits)
    }

    func testAWWWHostIsAccepted() {
        XCTAssertEqual(SpotifyPlaylistLink.playlistId(from: "https://www.open.spotify.com/playlist/\(topHits)"),
                       topHits,
                       "Some link rewriters prepend www.; it resolves to the same page")
    }

    func testTrailingSlashesAreAccepted() {
        XCTAssertEqual(SpotifyPlaylistLink.playlistId(from: "https://open.spotify.com/playlist/\(topHits)/"), topHits)
        XCTAssertEqual(SpotifyPlaylistLink.playlistId(from: "https://open.spotify.com/playlist/\(topHits)//"), topHits)
    }

    func testTheHostIsMatchedWithoutRegardToCase() {
        XCTAssertEqual(SpotifyPlaylistLink.playlistId(from: "HTTPS://OPEN.SPOTIFY.COM/playlist/\(topHits)"), topHits,
                       "Hosts and schemes are case-insensitive; an autocapitalised paste is still valid")
    }

    func testAFragmentIsIgnored() {
        XCTAssertEqual(SpotifyPlaylistLink.playlistId(from: "https://open.spotify.com/playlist/\(topHits)#play"),
                       topHits)
    }

    // MARK: - Links to something that is not a playlist

    func testOtherSpotifyEntitiesAreRejected() {
        for kind in ["album", "track", "artist", "episode", "show", "user"] {
            XCTAssertNil(SpotifyPlaylistLink.playlistId(from: "https://open.spotify.com/\(kind)/\(topHits)"),
                         "A \(kind) link must be refused up front. The embed endpoint answers for "
                            + "playlists only, so letting it through would import nothing and blame "
                            + "the network for it")
            XCTAssertNil(SpotifyPlaylistLink.playlistId(from: "spotify:\(kind):\(topHits)"))
        }
    }

    func testOtherHostsAreRejected() {
        XCTAssertNil(SpotifyPlaylistLink.playlistId(from: "https://open.spotify.com.evil.test/playlist/\(topHits)"),
                     "Suffix-matching the host would let any domain ending in the right letters "
                        + "decide what we fetch")
        XCTAssertNil(SpotifyPlaylistLink.playlistId(from: "https://spotify.com/playlist/\(topHits)"))
        XCTAssertNil(SpotifyPlaylistLink.playlistId(from: "https://music.youtube.com/playlist?list=\(topHits)"))
    }

    func testANonWebSchemeIsRejected() {
        XCTAssertNil(SpotifyPlaylistLink.playlistId(from: "file://open.spotify.com/playlist/\(topHits)"),
                     "Only http(s) and the spotify: URI describe a page we can fetch")
    }

    func testGarbageIsRejected() {
        XCTAssertNil(SpotifyPlaylistLink.playlistId(from: ""))
        XCTAssertNil(SpotifyPlaylistLink.playlistId(from: "   \n "))
        XCTAssertNil(SpotifyPlaylistLink.playlistId(from: "hello"))
        XCTAssertNil(SpotifyPlaylistLink.playlistId(from: topHits),
                     "A bare id is ambiguous — it is equally an album or a track id — and the "
                        + "field asks for a link")
        XCTAssertNil(SpotifyPlaylistLink.playlistId(from: "https://open.spotify.com/playlist/"),
                     "A playlist link with no playlist on the end")
        XCTAssertNil(SpotifyPlaylistLink.playlistId(from: "https://open.spotify.com/playlist"))
        XCTAssertNil(SpotifyPlaylistLink.playlistId(from: "spotify:playlist:"))
    }

    func testDeeperPathsUnderAPlaylistAreRejected() {
        XCTAssertNil(SpotifyPlaylistLink.playlistId(from: "https://open.spotify.com/playlist/\(topHits)/tracks"),
                     "Nothing at Spotify serves this, so accepting it would mean guessing which "
                        + "segment was meant to be the id")
    }

    func testAnIdWithCharactersSpotifyIdsNeverContainIsRejected() {
        XCTAssertNil(SpotifyPlaylistLink.playlistId(from: "https://open.spotify.com/playlist/../../etc"),
                     "Ids are base62; anything else is either a traversal attempt or a link to some "
                        + "other part of the site")
        XCTAssertNil(SpotifyPlaylistLink.playlistId(from: "https://open.spotify.com/playlist/id%20with%20space"))
    }

    // MARK: - Deliberately not strict about the id's length

    /// Spotify ids are 22 base62 characters today, and it is tempting to check that. It is the
    /// wrong trade: an id that is genuinely 22 characters but that we reject leaves the user
    /// staring at "that doesn't look like a Spotify playlist link" for a link that works fine in
    /// their browser, with nothing to do about it. An id we wrongly accept costs one HTTP request
    /// that comes back 404, and the sheet already has an honest sentence for that. So the length
    /// is left alone and only the alphabet is enforced, which is what keeps a path segment like
    /// `..` from being treated as an id.
    func testAnUnusuallyLengthedIdIsStillAccepted() {
        XCTAssertEqual(SpotifyPlaylistLink.playlistId(from: "https://open.spotify.com/playlist/abc123"), "abc123",
                       "Rejecting a short id here would be a dead end for the user; letting it "
                        + "through costs a 404 that reports itself")
        let long = String(repeating: "a", count: 40)
        XCTAssertEqual(SpotifyPlaylistLink.playlistId(from: "spotify:playlist:\(long)"), long)
    }

    func testTheIdsCaseIsPreservedExactly() {
        XCTAssertEqual(SpotifyPlaylistLink.playlistId(from: "https://OPEN.spotify.com/playlist/\(topHits)"), topHits,
                       "Ids are base62 and case-carrying — lowercasing the whole URL while parsing "
                        + "would turn a valid id into a 404")
    }
}
