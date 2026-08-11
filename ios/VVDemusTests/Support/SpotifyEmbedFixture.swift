import Foundation

/// Builds Spotify embed pages the way Spotify builds them, small enough to read.
///
/// The real page is 84 KB of Next.js output for 50 tracks, and pasting one into the repo
/// would mean every future `git diff` of the test directory is dominated by a blob nobody
/// reads and the type checker has to chew through. Everything the parser can get wrong is a
/// *shape* question — tag missing, attributes reordered, `duration` served as a string,
/// `entity` absent because the playlist is private — and each of those is three legible
/// lines here instead of a needle hunted inside 84 KB.
///
/// The values below are copied verbatim from a page captured on 2026-08-10
/// (`open.spotify.com/embed/playlist/37i9dQZF1DXcBWIGoYBM5M`), curly apostrophe and all, so
/// the fixture stays honest about what Spotify actually serves.
enum SpotifyEmbedFixture {

    struct Row {
        var title: String?
        var subtitle: String?
        /// Milliseconds, as Spotify sends it. Omitted from the JSON entirely when nil, which
        /// is a different case from `0` and both need covering.
        var duration: Int?
        var isPlayable: Bool = true

        init(_ title: String?, _ subtitle: String?, duration: Int? = 200_000, isPlayable: Bool = true) {
            self.title = title
            self.subtitle = subtitle
            self.duration = duration
            self.isPlayable = isPlayable
        }
    }

    /// The first six rows of the captured page. "Dai Dai" is here because its two-artist
    /// subtitle is the shape the matcher has to split on later — and note the `\u{00A0}`:
    /// Spotify really does join artists with a comma and a *non-breaking* space, which is
    /// invisible in test output and would otherwise never be reproduced by a hand-typed
    /// fixture.
    static let sampleRows: [Row] = [
        Row("stupid song", "Olivia Rodrigo", duration: 209_680),
        Row("Earrings", "Malcolm Todd", duration: 151_500),
        Row("petal", "Ariana Grande", duration: 184_248),
        Row("Dai Dai", "Shakira,\u{00A0}Burna Boy", duration: 223_448),
        Row("Animal", "KATSEYE", duration: 158_494),
        Row("Babydoll", "Dominic Fike", duration: 97_960),
    ]

    static let sampleName = "Today’s Top Hits"

    /// `count` distinct rows, for the boundary the truncation flag is defined by. Built
    /// programmatically because a hundred hand-written rows would tell the reader nothing a
    /// loop doesn't.
    static func rows(count: Int) -> [Row] {
        (0..<count).map { Row("Song \($0)", "Artist \($0)", duration: 180_000 + $0) }
    }

    // MARK: - JSON

    static func entityJSON(name: String? = sampleName,
                           type: String? = "playlist",
                           rows: [Row]? = sampleRows) -> String {
        var fields: [String] = []
        if let type { fields.append("\"type\": \(quoted(type))") }
        if let name { fields.append("\"name\": \(quoted(name))") }
        // Real pages carry these alongside; they are here so a parser that accidentally
        // reads the playlist's own `duration` (always 0) or `isPlayable` gets caught.
        fields.append("\"duration\": 0")
        fields.append("\"isPlayable\": true")
        if let rows {
            fields.append("\"trackList\": [\(rows.map(rowJSON).joined(separator: ", "))]")
        }
        return "{\(fields.joined(separator: ", "))}"
    }

    static func rowJSON(_ row: Row) -> String {
        var fields: [String] = ["\"uri\": \"spotify:track:0000000000000000000000\""]
        if let title = row.title { fields.append("\"title\": \(quoted(title))") }
        if let subtitle = row.subtitle { fields.append("\"subtitle\": \(quoted(subtitle))") }
        if let duration = row.duration { fields.append("\"duration\": \(duration)") }
        fields.append("\"isPlayable\": \(row.isPlayable)")
        fields.append("\"entityType\": \"track\"")
        return "{\(fields.joined(separator: ", "))}"
    }

    /// The `__NEXT_DATA__` payload: the four levels of nesting the entity really sits under,
    /// plus the sibling keys Next.js always emits, so nothing can pass by matching a shorter
    /// path than the page actually has.
    static func nextDataJSON(entityJSON: String?) -> String {
        let entity = entityJSON.map { "\"entity\": \($0), " } ?? ""
        return """
        {"props": {"pageProps": {"state": {"data": {\(entity)\
        "embeded_entity_uri": "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"}}}}, \
        "page": "/embed/playlist/[id]", "buildId": "vvdemus-fixture", "isFallback": false}
        """
    }

    // MARK: - Markup

    /// A page whose surroundings are as hostile as the real one: another JSON script tag
    /// before the payload, and a plain script after it.
    static func html(nextData: String,
                     attributes: String = #"id="__NEXT_DATA__" type="application/json""#) -> String {
        """
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Spotify Embed</title>
        <script id="__ANOTHER_PAYLOAD__" type="application/json">{"decoy": true}</script>
        </head><body><div id="__next"></div>
        <script \(attributes)>\(nextData)</script>
        <script>window.__spotifyEmbed = 1;</script>
        </body></html>
        """
    }

    /// The whole stack in one call: rows in, a page out.
    static func page(name: String? = sampleName,
                     type: String? = "playlist",
                     rows: [Row]? = sampleRows) -> String {
        html(nextData: nextDataJSON(entityJSON: entityJSON(name: name, type: type, rows: rows)))
    }

    private static func quoted(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [string])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}
