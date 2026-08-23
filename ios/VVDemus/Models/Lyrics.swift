import Foundation

/// One line of a timed lyric, `at` being the moment it is sung, in seconds from the start of the
/// track — the same clock as `PlayerService.progress`, so no conversion sits between the two.
struct LyricsLine: Codable, Equatable {
    let at: TimeInterval
    let text: String
}

/// Timed or untimed, never both. A source that gives us words we trust and timing we do not comes
/// back as `.plain`, which is the whole reason `LyricsMatch` has a third verdict.
enum LyricsBody: Codable, Equatable {
    /// Sorted by `at`, with exact repeats removed. `LyricsCursor` is written against that promise
    /// rather than re-checking it on every progress tick.
    case synced([LyricsLine])
    case plain([String])
}

struct Lyrics: Codable, Equatable {
    let body: LyricsBody
    let attribution: String?
    /// The length of whatever the lyrics were matched against. Kept so that a scroll running
    /// steadily ahead of the song can be diagnosed from the cache afterwards, rather than needing
    /// the bad match to be reproduced live.
    let matchedDuration: Int?

    /// Swift has no private enum case, so `.synced` cannot enforce its own ordering. Instead the
    /// invariant is held at the two doors a body can come through: this initialiser, and decoding.
    /// Everything downstream takes a `Lyrics`, never a bare `LyricsBody`, so there is no third way in.
    init(body: LyricsBody, attribution: String?, matchedDuration: Int?) {
        self.body = body.normalized()
        self.attribution = attribution
        self.matchedDuration = matchedDuration
    }
}

extension LyricsBody {
    func normalized() -> LyricsBody {
        guard case .synced(let lines) = self else { return self }
        return .synced(LyricsBody.normalize(lines))
    }

    /// Sorted stably, so lines sharing a timestamp keep the order the file put them in — the
    /// cursor's tie-break ("the last of the run wins") is only deterministic if that order is.
    /// `Array.sorted` makes no stability promise, hence the index tie-break.
    ///
    /// De-duplication is deliberately narrow: only an identical instant *and* identical text goes,
    /// which is what a concatenated or twice-merged LRC file produces and what shows up on screen
    /// as a line printed twice. Two different texts at one timestamp are kept — they may be a real
    /// overlap, and silently dropping words is a worse failure than a tie.
    private static func normalize(_ lines: [LyricsLine]) -> [LyricsLine] {
        let sorted = lines.enumerated()
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .map(\.element)

        var seen = Set<String>()
        return sorted.filter { seen.insert("\($0.at)\u{0}\($0.text)").inserted }
    }
}

extension LyricsBody {
    private enum CodingKeys: String, CodingKey {
        case synced, plain
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let lines = try container.decodeIfPresent([LyricsLine].self, forKey: .synced) {
            // Snapshots on disk outlive the code that wrote them; an older build's cache, or a
            // hand-edited one, must not be able to hand the cursor an unsorted array.
            self = .synced(LyricsBody.normalize(lines))
        } else if let lines = try container.decodeIfPresent([String].self, forKey: .plain) {
            self = .plain(lines)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: container.codingPath,
                      debugDescription: "a lyrics body carried neither synced nor plain lines"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .synced(let lines): try container.encode(lines, forKey: .synced)
        case .plain(let lines): try container.encode(lines, forKey: .plain)
        }
    }
}
