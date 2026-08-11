import Foundation

/// Turns whatever the user pasted into the playlist id the embed endpoint wants, or nothing.
///
/// This exists because there is no single "Spotify playlist link". The iOS share sheet gives
/// `https://open.spotify.com/playlist/<id>?si=…`, sometimes with a trailing newline when the
/// paste came out of Notes or a chat; the desktop client's Copy Spotify URI gives
/// `spotify:playlist:<id>`; anyone outside en gets a locale segment (`/intl-ja/playlist/<id>`);
/// and copying the *text* of a link rather than the link drops the scheme entirely. All of those
/// are the same playlist, and a person who pasted one and was told it "doesn't look like a
/// Spotify playlist link" has nowhere to go.
///
/// The parsing is done by hand rather than through `URL`/`URLComponents` for one reason:
/// `URL(string: "open.spotify.com/playlist/x")` parses happily with a nil host and the whole
/// thing as a relative path, so a host check written against it silently passes anything.
/// Guessing a scheme to make `URLComponents` cooperate then has to be undone for the
/// `spotify:` form, which is not a URL with a host at all. Splitting the string is shorter than
/// either workaround and has no shape it quietly mis-reads.
enum SpotifyPlaylistLink {

    /// Every character a Spotify id is made of. ASCII on purpose: `CharacterSet.alphanumerics`
    /// would also admit `é` and `日`, which no id contains and which would go on to be
    /// percent-escaped into a URL nobody meant to request.
    private static let idAlphabet = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    /// The playlist id in `input`, or nil if it does not name a Spotify playlist.
    ///
    /// The id's length is deliberately not checked even though every real one is 22 characters.
    /// The two mistakes are not symmetric: rejecting an id that would have worked strands the
    /// user on an error message they cannot act on, while accepting one that will not work costs
    /// a single request that comes back 404 and is reported as `SpotifyImportError.notAvailable`
    /// — a truthful answer either way. The alphabet *is* enforced, because that is what stops a
    /// path segment like `..` or a percent-escape from being handed to the fetcher as an id.
    static func playlistId(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let id = idFromURIForm(trimmed) { return id }
        return idFromURLForm(trimmed)
    }

    /// `spotify:playlist:<id>`, the desktop client's form. Matched case-insensitively on the
    /// prefix only: the scheme and entity type are ASCII keywords, but the id that follows is
    /// base62 and lowercasing it would turn a valid id into a 404.
    private static func idFromURIForm(_ trimmed: String) -> String? {
        let prefix = "spotify:"
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        let body = String(trimmed.dropFirst(prefix.count))
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "playlist" else { return nil }
        return validId(String(parts[1]))
    }

    private static func idFromURLForm(_ trimmed: String) -> String? {
        var rest = trimmed[...]

        // A scheme is optional, but if one is present it has to be a web scheme. `file://` and
        // friends name something we cannot fetch, and treating them as schemeless would read
        // "file" as the host.
        if let schemeEnd = rest.range(of: "://") {
            let scheme = rest[rest.startIndex..<schemeEnd.lowerBound].lowercased()
            guard scheme == "https" || scheme == "http" else { return nil }
            rest = rest[schemeEnd.upperBound...]
        }

        // Query and fragment carry only tracking (`si`, `pt`, `nd`) and the player's own anchor.
        if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            rest = rest[rest.startIndex..<cut]
        }

        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        var host = rest[rest.startIndex..<slash].lowercased()
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        // Exact match, never a suffix test: `open.spotify.com.example.test` ends in the right
        // letters and is somebody else's server.
        guard host == "open.spotify.com" else { return nil }

        var segments = rest[slash...].split(separator: "/").map(String.init)
        // Spotify inserts a locale segment ahead of the entity for non-English users.
        if let first = segments.first, first.lowercased().hasPrefix("intl-") {
            segments.removeFirst()
        }
        guard segments.count == 2, segments[0].lowercased() == "playlist" else { return nil }
        return validId(segments[1])
    }

    private static func validId(_ candidate: String) -> String? {
        guard !candidate.isEmpty,
              candidate.allSatisfy({ idAlphabet.contains($0) }) else { return nil }
        return candidate
    }
}
