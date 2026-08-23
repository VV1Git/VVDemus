import Foundation

/// LRC text — the synced half of an LRCLIB response — turned into `[LyricsLine]`.
///
/// The format is a single line of documentation and a decade of contributors disagreeing with
/// it. What actually arrives: two- and three-digit fractions in the same file, a chorus written
/// once and stamped four times, `[ar:]`/`[ti:]` headers that are not words anyone sings, bare
/// timestamps standing in for an instrumental break, an `[offset:]` tag that is wrong by exactly
/// the amount it is ignored by, and CRLF or a BOM from whoever pasted it out of a text editor.
///
/// Every one of those is silent when mishandled — nothing throws, nothing looks empty, the wrong
/// line is simply highlighted over the song. So this refuses per line rather than per file: a
/// typo in one tag costs that tag, never the rest of the words.
enum LRCParser {

    /// Empty means "nothing timed in here", which is a real answer rather than a failure — the
    /// caller falls back to plain text. Returning zero-second lines for untimed text would be
    /// strictly worse than that, because a bad cursor looks like a working one.
    static func parse(_ text: String) -> [LyricsLine] {
        // Milliseconds, applied to every timestamp in the file regardless of where the tag sits,
        // so it cannot be applied as we go. Sign convention, which the format states and which
        // is exactly backwards from what "offset" suggests: **a positive offset makes the words
        // appear earlier**, so it is subtracted.
        var offsetSeconds: TimeInterval = 0
        var collected: [LyricsLine] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            // A BOM only ever appears on the first line, but stripping it here costs nothing and
            // saves a special case; left in place it sits in front of the opening `[` and the
            // file loses precisely its first line — the one most likely to be noticed on screen
            // and least likely to be traced back to an invisible character.
            var rest = rawLine.drop { $0 == "\u{FEFF}" || $0 == " " || $0 == "\t" }
            var times: [TimeInterval] = []

            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let body = rest[rest.index(after: rest.startIndex)..<close]

                if let at = timestamp(body) {
                    times.append(at)
                } else if let ms = offsetMilliseconds(body) {
                    offsetSeconds = ms / 1000
                } else if !isMetadataTag(body) {
                    // Not a timestamp and not a header, so it is something a human typed as part
                    // of the lyric — a "[Chorus]" marker most often. Stop consuming tags and let
                    // it stay in the text, brackets and all.
                    break
                }

                rest = rest[rest.index(after: close)...].drop { $0 == " " || $0 == "\t" }
            }

            // No timestamp is not damage: it is a header line, a blank line, or the one tag in
            // the file with a typo in it. Nothing to place on a timeline, so nothing is emitted
            // — and the lines either side are untouched.
            guard !times.isEmpty else { continue }

            // A timestamp with nothing after it is how the format writes an instrumental break,
            // and it has to survive as an empty line. Dropped, the previous lyric stays
            // highlighted for the whole of a thirty-second gap where nobody is singing.
            let lineText = rest.trimmingCharacters(in: .whitespaces)
            for at in times {
                collected.append(LyricsLine(at: at, text: lineText))
            }
        }

        // `LyricsCursor.activeIndex(in:at:)` binary-searches this array, so order is correctness
        // rather than tidiness: a chorus stamped with three times arrives out of order in almost
        // every real file. The index tiebreak keeps a stable sort — two lines sharing a timestamp
        // are a call and its response, and swapping them is visible on screen.
        return collected.enumerated()
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .map { line in
                // Clamped, because an offset large enough to pull the opening line in front of
                // the start of the track hands a negative time to `PlayerService.seek(to:)`,
                // where it means nothing.
                LyricsLine(at: max(0, line.element.at - offsetSeconds), text: line.element.text)
            }
    }

    /// `mm:ss`, `mm:ss.xx`, `mm:ss.xxx`, and the `mm:ss:xx` variant some editors write.
    ///
    /// Two digits after the point are hundredths and three are milliseconds; read the wrong way
    /// a `.5` becomes `.005` and every line lands half a second early for the whole song.
    private static func timestamp(_ body: Substring) -> TimeInterval? {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        // Either separator, but only one fraction: `mm:ss:xx:yy` is not a shape anything writes.
        let parts = trimmed.split(whereSeparator: { $0 == ":" || $0 == "." })
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }

        // The minutes field is bounded like the other two, and for a harder reason than they
        // are: `minutes * 60` below is `Int` arithmetic, and Swift traps on overflow rather
        // than throwing. `[200000000000000000:00]` is all digits, parses to a valid `Int`, and
        // killed the process — from a remote, community-edited file, on a screen opened to read
        // along with a song. Six digits is a hundred and ninety years, so nothing real is lost,
        // and a tag past it is refused per line like every other malformed shape here.
        guard parts[0].count <= 6, let minutes = Int(parts[0]), let seconds = Int(parts[1]) else { return nil }
        // Minutes past 60 are ordinary on a long track. Seconds past 60 are not a longer minute,
        // they are a mangled tag — `[length:03:21]`'s cousin — and guessing at one puts a line
        // in the wrong place rather than dropping it.
        guard parts[1].count <= 2, seconds < 60 else { return nil }

        var at = TimeInterval(minutes * 60 + seconds)
        if parts.count == 3 {
            guard parts[2].count <= 3, let fraction = Double("0." + parts[2]) else { return nil }
            at += fraction
        }
        return at
    }

    /// Milliseconds, signed. Anything else in an `[offset:]` tag is ignored rather than guessed
    /// at: a shifted-by-garbage file is harder to notice than an unshifted one.
    private static func offsetMilliseconds(_ body: Substring) -> Double? {
        guard let colon = body.firstIndex(of: ":") else { return nil }
        guard body[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "offset" else { return nil }
        return Double(body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// `[ar:]`, `[ti:]`, `[al:]`, `[by:]`, `[length:]` and whatever else a contributor invented.
    ///
    /// Matched by shape rather than by a list of known keys, because the point is only to decide
    /// whether the tag is a header to skip past or text a human meant to be read. `[length:03:21]`
    /// is the one that has to be caught: strip the key and it is shaped exactly like a timestamp,
    /// so an unfiltered parser sings "03:21" at the three minute mark.
    private static func isMetadataTag(_ body: Substring) -> Bool {
        guard let colon = body.firstIndex(of: ":") else { return false }
        let key = body[..<colon].trimmingCharacters(in: .whitespaces)
        return !key.isEmpty && key.allSatisfy { $0.isLetter }
    }
}
