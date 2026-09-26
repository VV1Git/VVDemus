import Foundation

/// Search results with fan uploads folded in among the catalogue's songs.
///
/// Unreleased music has no catalogue entry — the only copies are uploads, which YouTube Music
/// files as videos — so a Songs-only search can never find it. Uploads rank *below* songs
/// unless they answer the query better: an upload moves up past exactly the songs that match
/// fewer of the words typed, and never past one that matches as many. "choosin texas drake"
/// puts Drake's unreleased "Choosin' Texas" above Ella Langley's released one, because only the
/// upload has "drake" in it; "choosin texas" leaves Ella Langley's songs on top and puts the
/// upload straight after them.
enum SearchBlend {
    /// A Videos-filter row as it arrives, before anything has been decided about it.
    struct Upload: Equatable {
        let videoId: String
        let rawTitle: String
        let channel: String
        let thumbnailUrl: String?
        let durationSeconds: Int?
    }

    /// Enough to find what was asked for without uploads outnumbering the songs around them.
    static let maximumUploads = 6

    /// An unreleased song is as long as any other song; a "PND unreleased mix" is forty
    /// minutes. Well short of `Track.isLongFormMix`'s cut, because the Videos filter is full of
    /// half-hour compilations that no real track in it comes near.
    static let longestUploadSeconds = 600

    /// An upload has to contain at least this share of the query's words to be shown at all.
    /// Below it, it isn't plainly about what was asked for.
    static let minimumUploadCoverage = 0.5

    static func blend(songs: [Track], uploads: [Upload], query: String) -> [Track] {
        let wanted = Set(TrackMatcher.words(query))
        guard !wanted.isEmpty else { return songs }

        let songScores = songs.map { coverage(of: wanted, in: [$0.title, $0.artist, $0.album ?? ""]) }
        let knownArtists = songs.map(\.artist)
        let knownTitles = songs.map(\.title)

        // Scored on the upload as written, not as cleaned up: the channel and the tags are
        // part of how it answers the query — "the weeknd unreleased" is asking for the tag.
        var placed: [(before: Int, track: Track)] = []
        for upload in uploads where placed.count < maximumUploads {
            guard !isJunk(upload) else { continue }
            let score = coverage(of: wanted, in: [upload.rawTitle, upload.channel])
            guard score >= minimumUploadCoverage else { continue }
            let track = UploadTitle.track(from: upload, knownArtists: knownArtists, knownTitles: knownTitles)
            // A released song's upload is a worse copy of a row already on screen.
            guard !songs.contains(where: { InnerTubeClient.isSameSong(track, as: $0) }) else { continue }
            let before = songScores.firstIndex(where: { $0 < score }) ?? songs.count
            placed.append((before, track))
        }

        var blended: [Track] = []
        for (index, song) in songs.enumerated() {
            blended += placed.filter { $0.before == index }.map { $0.track }
            blended.append(song)
        }
        blended += placed.filter { $0.before == songs.count }.map { $0.track }
        return blended
    }

    /// The share of the query's words that appear anywhere in `fields`.
    ///
    /// A word also counts when one is a prefix of the other — "choosing" typed, "Choosin'"
    /// uploaded — but only from four letters up, below which a shared prefix is a coincidence.
    static func coverage(of wanted: Set<String>, in fields: [String]) -> Double {
        guard !wanted.isEmpty else { return 0 }
        let present = Set(fields.flatMap(TrackMatcher.words))
        let found = wanted.filter { word in
            present.contains(word) || present.contains { other in
                let (short, long) = word.count <= other.count ? (word, other) : (other, word)
                return short.count >= 4 && long.hasPrefix(short)
            }
        }
        return Double(found.count) / Double(wanted.count)
    }

    /// Uploads that are something other than a song, or a released song in other clothes. Lyric
    /// videos are most of the second kind: lyric channels upload what is already out, and for a
    /// search like "sza snooze" they were half of everything the Videos filter returned.
    private static let notTheSongWords: Set<String> = [
        "lyrics", "lyric", "karaoke", "instrumental", "choreography", "tutorial", "reaction",
        "cover", "nightcore", "slowed", "reverb", "hour",
    ]

    private static func isJunk(_ upload: Upload) -> Bool {
        if let seconds = upload.durationSeconds, seconds > longestUploadSeconds { return true }
        let words = TrackMatcher.words(upload.rawTitle)
        // Nothing but hashtags: a short, not a song.
        if !words.isEmpty, upload.rawTitle.split(separator: " ").allSatisfy({ $0.hasPrefix("#") }) { return true }
        let pairs = zip(words, words.dropFirst())
        if words.contains("playlist") { return true }
        // Producers' "Drake type beat" instrumentals name the artist, so they match an artist
        // search perfectly while containing none of the artist's music.
        if pairs.contains(where: { $0 == "type" && $1 == "beat" }) { return true }
        // Said outright, it outweighs the rest: an unreleased track's lyric video is still the
        // unreleased track.
        if !UploadTitle.unreleasedWords.isDisjoint(with: words) { return false }
        return !notTheSongWords.isDisjoint(with: words)
            || pairs.contains(where: { $0 == "line" && $1 == "dance" })
    }
}

/// A fan upload's title taken apart into what a song row shows: "PARTYNEXTDOOR - Poppa / Wet My
/// Whistle (Unreleased/Leak)" from the channel "The Volume" becomes "Poppa / Wet My Whistle
/// (Unreleased)" by PARTYNEXTDOOR.
///
/// Uploaders mostly write "Artist - Title", sometimes the other way round, and pile on tags,
/// hashtags and "| playlist" tails. None of it is structured, so this is best effort: anything
/// that can't be read confidently is left as the uploader wrote it, and the channel stands in
/// for the artist when the title doesn't name one.
enum UploadTitle {
    /// `knownArtists` and `knownTitles` are what the Songs half of the same search found — the
    /// only evidence there is for which side of "A - B" is the artist.
    static func track(from upload: SearchBlend.Upload, knownArtists: [String], knownTitles: [String] = []) -> Track {
        var isUnreleased = false
        let untagged = withoutHashtags(strippingTags(upload.rawTitle, isUnreleased: &isUnreleased))
        let (body, tail) = splitting(untagged, at: [" | ", " // "])

        var title = body
        var artist: String?
        if let (left, right) = splitAtDash(body) {
            if isArtist(right, among: knownArtists), !isArtist(left, among: knownArtists) {
                // Written the other way round: "Tongue - The Weeknd".
                artist = right
                title = left
            } else if !isArtist(left, among: knownArtists), isTitle(left, among: knownTitles) {
                // "Choosin' Texas - 2AM Remix": the left side is a song, so neither side is
                // the artist and the whole of it is the title.
                title = body
            } else {
                artist = left
                title = right
            }
        }
        if artist == nil, let tail, agrees(tail, with: knownArtists) {
            // "CHOOSIN' TEXAS (REMIX) | Drake x Don Toliver x Ella Langley"
            artist = tail
        }

        var featured: String?
        if let credit = artist {
            let (lead, guests) = splittingFeature(credit)
            artist = lead
            featured = guests
        }

        title = tidied(title)
        if title.isEmpty { title = tidied(upload.rawTitle) }
        let words = Set(TrackMatcher.words(title))
        if let featured, words.isDisjoint(with: ["feat", "ft", "featuring"]) {
            title += " (feat. \(featured))"
        }
        if isUnreleased, !words.contains("unreleased") {
            title += " (Unreleased)"
        }

        let credited = artist.map(tidied).flatMap { $0.isEmpty ? nil : $0 }
        return Track(
            videoId: upload.videoId,
            title: title,
            artist: credited.map { canonical($0, among: knownArtists) } ?? upload.channel,
            album: nil,
            thumbnailUrl: upload.thumbnailUrl,
            durationSeconds: upload.durationSeconds
        )
    }

    // MARK: - Tags

    private enum Tag { case unreleased, noise, meaningful }

    /// Words that describe the upload rather than the song. Deliberately narrower than
    /// `TrackMatcher`'s decoration list: that one exists to *compare* titles and happily drops
    /// "Radio Edit", which a title on screen should keep.
    private static let noiseWords: Set<String> = [
        "official", "video", "music", "audio", "lyric", "lyrics", "visualizer", "visualiser",
        "hd", "hq", "cdq", "4k", "high", "quality", "full", "song", "version", "og", "new",
        "studio", "explicit", "clean",
    ]

    static let unreleasedWords: Set<String> = ["unreleased", "leak", "leaked"]

    private static func tag(_ group: String) -> Tag {
        let words = TrackMatcher.words(group)
        if words.isEmpty { return .noise }
        if !unreleasedWords.isDisjoint(with: words) { return .unreleased }
        // "(prod. Metro Boomin)" — a credit no catalogue title carries.
        if words.first == "prod" { return .noise }
        return words.allSatisfy(noiseWords.contains) ? .noise : .meaningful
    }

    /// Drops bracketed groups that are only packaging, and folds every flavour of
    /// "(Unreleased/Leak)" into one flag so it can be written back once, the same way each time.
    private static func strippingTags(_ raw: String, isUnreleased: inout Bool) -> String {
        var kept = ""
        var group = ""
        var depth = 0
        for character in raw {
            if "([{".contains(character) {
                if depth == 0 { group = "" }
                depth += 1
                group.append(character)
            } else if ")]}".contains(character), depth > 0 {
                depth -= 1
                group.append(character)
                guard depth == 0 else { continue }
                switch tag(group) {
                case .unreleased: isUnreleased = true
                case .noise: break
                case .meaningful: kept += group
                }
            } else if depth > 0 {
                group.append(character)
            } else {
                kept.append(character)
            }
        }
        // An unclosed bracket is kept as written rather than guessed at.
        return depth > 0 ? kept + group : kept
    }

    private static func withoutHashtags(_ text: String) -> String {
        text.split(separator: " ").filter { !$0.hasPrefix("#") }.joined(separator: " ")
    }

    // MARK: - Structure

    private static func splitting(_ text: String, at separators: [String]) -> (String, String?) {
        let ranges = separators.compactMap { text.range(of: $0) }
        guard let first = ranges.min(by: { $0.lowerBound < $1.lowerBound }) else { return (text, nil) }
        let tail = String(text[first.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (String(text[..<first.lowerBound]), tail.isEmpty ? nil : tail)
    }

    /// A *spaced* dash only, of any of the three kinds uploaders type — an unspaced one is part
    /// of a word ("Spider-Man").
    private static func splitAtDash(_ text: String) -> (String, String)? {
        let (left, right) = splitting(text, at: [" - ", " – ", " — "])
        let lead = left.trimmingCharacters(in: .whitespaces)
        guard let right, !lead.isEmpty else { return nil }
        return (lead, right)
    }

    /// "Drake ft. Don Toliver" → ("Drake", "Don Toliver"). Uploaders don't always leave a space
    /// after the marker — "PartyNextDoor ft.TyDolla$ign" — so it is matched as a word, not as
    /// a padded string.
    private static func splittingFeature(_ credit: String) -> (String, String?) {
        guard let marker = credit.range(of: #"\s(feat|ft|featuring)\b\.?\s*"#,
                                        options: [.regularExpression, .caseInsensitive]) else {
            return (credit, nil)
        }
        let lead = String(credit[..<marker.lowerBound]).trimmingCharacters(in: .whitespaces)
        let guests = String(credit[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !lead.isEmpty else { return (credit, nil) }
        return (lead, guests.isEmpty ? nil : guests)
    }

    /// Whether `name`, its featured guests aside, *is* one of the artists — every word of it
    /// belongs to one of theirs. Deliberately stricter than `agrees`: the right side of
    /// "Drake - Choosin' Texas (REMIX) ft. Ella Langley" contains an artist without being one,
    /// and reading it as the artist turned the song into "Drake" by "Choosin' Texas".
    private static func isArtist(_ name: String, among knownArtists: [String]) -> Bool {
        let words = TrackMatcher.ArtistName(splittingFeature(name).0).tokens
        guard !words.isEmpty else { return false }
        return knownArtists.contains { words.isSubset(of: TrackMatcher.ArtistName($0).tokens) }
    }

    /// Whether `name` is the title of a song this search found, packaging and credits aside.
    private static func isTitle(_ name: String, among knownTitles: [String]) -> Bool {
        let core = TrackMatcher.normalisedTitle(name).core
        guard !core.isEmpty else { return false }
        return knownTitles.contains { TrackMatcher.normalisedTitle($0).core == core }
    }

    /// Looser than `isArtist`: one credit contains the other. Right for a "| A x B x C" tail,
    /// which lists everyone on the track and is a credit whenever a known artist is among them.
    private static func agrees(_ name: String, with knownArtists: [String]) -> Bool {
        let candidate = TrackMatcher.ArtistName(name)
        return knownArtists.contains { TrackMatcher.ArtistName($0).agreement(with: candidate) == 1 }
    }

    /// "partynextdoor" as the catalogue writes it, "PARTYNEXTDOOR" — but only when the two are
    /// the same words, so a credit like "Drake x Don Toliver" is never collapsed to "Drake".
    private static func canonical(_ artist: String, among knownArtists: [String]) -> String {
        let words = TrackMatcher.words(artist)
        return knownArtists.first { TrackMatcher.words($0) == words } ?? artist
    }

    /// Whitespace collapsed, stray separators and quotes trimmed from the ends, and a trailing
    /// "HQ"/"CDQ" outside any bracket dropped.
    private static func tidied(_ text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        while words.count > 1, let last = words.last,
              ["hq", "cdq", "hd", "4k"].contains(last.lowercased()) {
            words.removeLast()
        }
        return words.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—|:/\"“”"))
    }
}
