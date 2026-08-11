import Foundation

/// Decides which YouTube Music search result — if any — is the recording a Spotify row named.
///
/// This is the quality core of the Spotify import, and its failures are asymmetric. A miss is
/// visible: the summary lists it by name and the user can go and find it by hand. A *wrong*
/// match is invisible: a karaoke backing track, a sped-up TikTok rip or a live take sits in the
/// playlist looking exactly like the song until it plays three weeks later, by which point
/// nobody remembers where it came from. So every rule here is written to refuse, and returning
/// nil is the designed outcome rather than a failure to produce one.
///
/// Everything is a pure function of the two values passed in: no network, no store, no clock.
/// The whole point is that the interesting cases — the ones that only show up in a real search
/// response, three screens into a real playlist — can be provoked directly in a unit test.
enum TrackMatcher {

    /// The best acceptable candidate, or nil when none of them is the right recording.
    ///
    /// Order of the array is YouTube's relevance to a *text query*, which says nothing about
    /// which specific cut of a song it is, so the whole list is scored and the winner taken on
    /// score alone. Ties keep the earlier candidate, which is the only thing search rank is
    /// still good for.
    static func bestMatch(for spotify: SpotifyTrack, among candidates: [Track]) -> Track? {
        let wantedTitle = normalisedTitle(spotify.title)
        let wantedMarkers = variantMarkers(in: wantedTitle.tokens)
        let wantedArtist = ArtistName(spotify.artist)
        let wantedSeconds = spotify.durationMs.map { Int((Double($0) / 1000).rounded()) }

        var best: (track: Track, score: Double)?

        for candidate in candidates {
            guard let score = score(candidate,
                                    wantedTitle: wantedTitle,
                                    wantedMarkers: wantedMarkers,
                                    wantedArtist: wantedArtist,
                                    wantedSeconds: wantedSeconds) else { continue }
            if score > (best?.score ?? -1) {
                best = (candidate, score)
            }
        }

        return best?.track
    }

    // MARK: - Scoring one candidate

    /// nil means "disqualified", which is not the same as a low score: the gates below are
    /// things no amount of agreement elsewhere is allowed to outvote.
    private static func score(
        _ candidate: Track,
        wantedTitle: NormalisedTitle,
        wantedMarkers: [String: Int],
        wantedArtist: ArtistName,
        wantedSeconds: Int?
    ) -> Double? {
        // `InnerTubeClient.parseSearchItem` substitutes these literals when the renderer is
        // missing the field, so they are not a title and not a name — a result carrying them
        // is a malformed one, and matching on the placeholder text would let it win outright
        // whenever the Spotify side happens to be odd too.
        guard !isPlaceholder(candidate.title, equals: "unknown title") else { return nil }

        // The hour-long "Top 100 Hits" / "Best of" / "Continuous Mix" uploads that YouTube Music
        // files as songs. `Track.excludingLongFormMixes()` is deliberately not applied to search
        // results, so an import has to make the call itself. Checked separately from the length
        // comparison below because Spotify does not always give us a duration to compare against,
        // and a missing duration must not become permission to import three hours of audio.
        if candidate.isLongFormMix, (wantedSeconds ?? 0) <= Track.longFormMixThreshold {
            return nil
        }

        let candidateTitle = normalisedTitle(candidate.title)
        let candidateArtist = ArtistName(candidate.artist)

        // Variant words have to agree on both sides, not merely be strippable. "Blinding Lights -
        // Remastered" is the same recording as "Blinding Lights"; "Blinding Lights - Remix" is
        // not, and it has the same artist and can have the same length, so nothing else in the
        // scorer can tell them apart. Counted rather than collected into a set, because a set
        // collapses the two occurrences in "Live Forever - Live at Knebworth" into the one that
        // "Live Forever" already carries and hands the Knebworth take a clean pass — the exact
        // silent wrong match this gate exists to stop. Multiplicity still leaves the case the
        // set was there for intact: "Live and Let Die" is `live: 1` against "Live and Let Die -
        // Remastered 2011", also `live: 1`, and matches.
        guard variantMarkers(in: candidateTitle.tokens) == wantedMarkers else { return nil }

        // The same vocabulary read off the *credit*, which the title gate never sees. Tribute
        // and karaoke channels name themselves after the artist and title their uploads plainly
        // ("Nothing Else Matters" by "Metallica Tribute Band"), so every text signal agrees and
        // the artist comparison below actively rewards them: a credit that *contains* the wanted
        // one scores a perfect 1. The word is on one side only, which is the whole tell.
        guard candidateArtist.markers == wantedArtist.markers else { return nil }

        // Compared twice: once whole, and once on the title proper with every bracketed or
        // dash-separated suffix dropped. Spotify hangs soundtrack attributions off the title
        // ("Sunflower - Spider-Man: Into the Spider-Verse", "Barbie World - From Barbie The
        // Album") that YouTube Music simply does not carry, and whole-title comparison scores
        // those around 0.2 — the correct result is thrown away for half a film soundtrack at a
        // time. The discount keeps the relaxation honest, and only material behind a bracket or
        // a spaced dash is ever droppable: "Yesterday Once More" has no separator, so it is
        // still refused for "Yesterday".
        //
        // The relaxation runs in one direction only, and that asymmetry is load-bearing. Dropping
        // material from the *Spotify* side is what the soundtrack case needs. Dropping material
        // from the *candidate* side is how "Heat Waves (Speed Up)", "(Bass Boosted)", "(Chopped
        // and Screwed)" and "(Piano Rendition)" were imported at 0.85: `variantWords` has no
        // entry for any of them, so the marker gate above waves them through, and the core
        // comparison then throws the suffix away as if it had been recognised as packaging. The
        // dictionary can never be complete, so the rule is not "is this word known" but "did the
        // Spotify row already account for it" — its title, or its artist, which covers the
        // common "Title - Artist Name" upload. Anything left over is treated as possibly naming
        // a different recording and has to survive the whole-title comparison instead.
        let candidateSuffixIsAccountedFor = candidateTitle.unrecognisedSuffix.allSatisfy {
            wantedTitle.tokens.contains($0) || wantedArtist.tokens.contains($0)
        }
        var titleScore = similarity(wantedTitle.tokens, candidateTitle.tokens)
        if candidateSuffixIsAccountedFor {
            titleScore = max(titleScore,
                             coreDiscount * similarity(wantedTitle.core, candidateTitle.core))
        }
        guard titleScore >= titleFloor else { return nil }

        let artistScore = wantedArtist.agreement(with: candidateArtist)
        // A cover is titled identically, is often the same length, and differs only here. Total
        // disagreement between two artist names we can both read is therefore fatal rather than
        // merely expensive — this is what keeps Luke Combs' "Fast Car" out of a Tracy Chapman
        // playlist. "Both read" is doing real work: `agreement` returns nil, not 0, when the two
        // credits are written in different alphabets, because that is an absence of evidence and
        // this line would otherwise refuse every romanised J-pop row on sight.
        if let artistScore, artistScore == 0 { return nil }

        var durationScore = unknownDurationScore
        if let wantedSeconds, let candidateSeconds = candidate.durationSeconds {
            let delta = abs(wantedSeconds - candidateSeconds)
            // Spotify's millisecond count is exact and YouTube Music's own catalogue entries land
            // within a second or two of it. Anything beyond a quarter of a minute is a different
            // performance — a live take, an extended mix, an album version against a single edit —
            // not a different encode of the same one.
            guard delta <= durationVetoSeconds else { return nil }
            durationScore = closeness(ofDelta: delta)
        }

        // Title is a multiplier rather than a term, so the total can never exceed the title
        // score: a weak title match cannot be rescued by a perfect artist and a perfect length,
        // which is precisely how "Yesterday Once More" gets imported as "Yesterday".
        let support = titleWeight
            + artistWeight * (artistScore ?? unknownArtistScore)
            + durationWeight * durationScore
        let total = titleScore * support
        return total >= acceptanceThreshold ? total : nil
    }

    // MARK: - Thresholds

    /// Below this the titles are not the same song and nothing else is consulted.
    private static let titleFloor = 0.55

    /// The share of the total a perfect title alone is worth; artist and duration make up the
    /// rest. Tuned so that a perfect title with an unreadable artist and no duration on either
    /// side still lands above the acceptance threshold — that combination is common and usually
    /// right — while a merely similar title with the same missing evidence does not.
    private static let titleWeight = 0.62
    private static let artistWeight = 0.23
    private static let durationWeight = 0.15

    private static let acceptanceThreshold = 0.66

    /// What an absent artist or duration is worth: neither evidence for nor against. Deliberately
    /// below 0.5 for the artist, because "we could not read either name" should cost a little —
    /// it is more often a junk channel than a real one.
    private static let unknownArtistScore = 0.45
    private static let unknownDurationScore = 0.5

    private static let durationVetoSeconds = 15

    /// What a match on the title proper alone is worth against one on the whole title. Set so
    /// that dropping the suffixes still needs the artist or the length to agree before the
    /// candidate is acceptable.
    private static let coreDiscount = 0.85

    /// Within a couple of seconds is strong evidence for this exact recording; the value decays
    /// from there so that when several candidates all pass the veto, the closest one wins.
    private static func closeness(ofDelta delta: Int) -> Double {
        switch delta {
        case ...2: return 1.0
        case ...5: return 0.9
        case ...10: return 0.7
        default: return 0.45
        }
    }

    // MARK: - Title normalisation

    /// A title reduced to comparable tokens: case and diacritics folded, punctuation dropped,
    /// featured-artist credits removed, and decoration such as "(Remastered 2011)" or
    /// "- Official Video" stripped — but only decoration, never a word that identifies a
    /// different recording.
    ///
    /// Structure is read before punctuation is thrown away, because the structure is the whole
    /// signal: the first segment is the title proper and everything after it — bracketed, or
    /// following a spaced dash — is a suffix that may or may not be load-bearing. The first
    /// segment is always kept, which is also what stops a track named nothing but "(Audio)" from
    /// normalising to the empty string. Two empty titles compare as a perfect match, so an
    /// unconditional stripper hands the top score to whichever piece of junk search listed first.
    private static func normalisedTitle(_ raw: String) -> NormalisedTitle {
        let folded = fold(raw)
        let segments = segmented(folded)
        var tokens: [String] = []
        var core: [String] = []

        var unrecognisedSuffix: [String] = []

        for (index, segment) in segments.enumerated() {
            let segmentTokens = collapsingOriginalMix(segment.tokens)
            if index == 0 {
                core = truncatingCredit(segmentTokens)
                tokens += core
                continue
            }
            if isCredit(segmentTokens, bracketed: segment.bracketed) { continue }
            if isDecoration(segmentTokens) { continue }
            let surviving = truncatingCredit(segmentTokens)
            tokens += surviving
            unrecognisedSuffix += surviving
        }

        guard !tokens.isEmpty else {
            let fallback = tokenise(folded)
            return NormalisedTitle(tokens: fallback, core: fallback, unrecognisedSuffix: [])
        }
        return NormalisedTitle(tokens: tokens,
                               core: core.isEmpty ? tokens : core,
                               unrecognisedSuffix: unrecognisedSuffix)
    }

    /// `tokens` is the title with its non-load-bearing decoration removed; `core` is the title
    /// proper, with *every* suffix removed whether it was load-bearing or not.
    private struct NormalisedTitle {
        let tokens: [String]
        let core: [String]
        /// Exactly what `core` drops and `tokens` keeps: suffix material that survived the
        /// decoration filter because no word in it is one we recognise as packaging. `score`
        /// reads it to decide whether the core comparison is allowed to throw it away, which is
        /// the difference between importing "Heat Waves" and importing "Heat Waves (Speed Up)".
        let unrecognisedSuffix: [String]
    }

    /// "Original Mix" is the dance catalogue's name for the *original*: on Beatport and in the
    /// YouTube Music entries that copy it, "Strobe (Original Mix)" is the album master Spotify
    /// simply calls "Strobe". Collapsed to "original" here — before markers or decoration are
    /// read, both of which look at one token at a time — so the suffix becomes ordinary
    /// packaging and drops out. It has to stay keyed on the pair: a bare "mix" is "Extended Mix"
    /// and "Club Mix", which really are other recordings, so "mix" must not join
    /// `decorationWords`.
    private static func collapsingOriginalMix(_ tokens: [String]) -> [String] {
        guard tokens.count >= 2 else { return tokens }
        var collapsed: [String] = []
        var index = 0
        while index < tokens.count {
            if tokens[index] == "original", index + 1 < tokens.count, tokens[index + 1] == "mix" {
                collapsed.append("original")
                index += 2
            } else {
                collapsed.append(tokens[index])
                index += 1
            }
        }
        return collapsed
    }

    /// Case, accents and half-width forms folded in one pass, and apostrophes deleted rather than
    /// split on so that "Don't" stays one token instead of becoming "don" and "t".
    private static func fold(_ raw: String) -> String {
        let withoutApostrophes = raw.replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "`", with: "")
        return withoutApostrophes.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func tokenise(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Splits a folded title into its title-proper and its suffixes. Brackets of any of the three
    /// kinds start a segment; outside brackets, a *spaced* dash does — an unspaced one is part of
    /// a word ("Spider-Man", "Marie-Jeanne") and must not split anything.
    private static func segmented(_ folded: String) -> [(tokens: [String], bracketed: Bool)] {
        var segments: [(tokens: [String], bracketed: Bool)] = []
        var plain = ""
        var bracketed = ""
        var depth = 0

        func flushPlain() {
            var text = plain
            plain = ""
            for dash in [" \u{2013} ", " \u{2014} ", " \u{2012} ", " \u{2015} "] {
                text = text.replacingOccurrences(of: dash, with: " - ")
            }
            for piece in text.components(separatedBy: " - ") {
                let tokens = tokenise(piece)
                if !tokens.isEmpty { segments.append((tokens, false)) }
            }
        }

        for character in folded {
            if "([{".contains(character) {
                if depth == 0 { flushPlain() } else { bracketed.append(character) }
                depth += 1
            } else if ")]}".contains(character) {
                if depth == 1 {
                    let tokens = tokenise(bracketed)
                    bracketed = ""
                    if !tokens.isEmpty { segments.append((tokens, true)) }
                } else if depth > 1 {
                    bracketed.append(character)
                }
                depth = max(0, depth - 1)
            } else if depth > 0 {
                bracketed.append(character)
            } else {
                plain.append(character)
            }
        }

        // An unclosed bracket is common in scraped titles; treat what follows it as a segment
        // rather than losing it.
        if depth > 0 {
            let tokens = tokenise(bracketed)
            if !tokens.isEmpty { segments.append((tokens, true)) }
        }
        flushPlain()
        return segments
    }

    /// "feat.", "ft." and — inside brackets only — "with". "with" is excluded outside brackets
    /// because it is an ordinary English word: stripping it there deletes half of "Dancing With
    /// Myself".
    private static func isCredit(_ tokens: [String], bracketed: Bool) -> Bool {
        guard let first = tokens.first else { return false }
        if bracketed && (first == "with" || first == "w") { return true }
        return creditWords.contains(first)
    }

    /// Drops a trailing "feat. X" that was written inline rather than in brackets.
    private static func truncatingCredit(_ tokens: [String]) -> [String] {
        guard let index = tokens.firstIndex(where: { creditWords.contains($0) }), index > 0 else {
            return tokens
        }
        return Array(tokens[..<index])
    }

    private static let creditWords: Set<String> = ["feat", "feats", "ft", "featuring"]

    /// A suffix is decoration only when *every* word in it is packaging. That is the conservative
    /// direction: an unrecognised word keeps the whole suffix, so a new kind of variant Spotify or
    /// YouTube invents next year is treated as significant rather than quietly discarded.
    private static func isDecoration(_ tokens: [String]) -> Bool {
        !tokens.isEmpty && tokens.allSatisfy { decorationWords.contains($0) || isYearLike($0) }
    }

    /// "2011", "50th" — the numeric half of "Remastered 2011" and "50th Anniversary Edition".
    private static func isYearLike(_ token: String) -> Bool {
        let digits = token.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return false }
        let rest = token.dropFirst(digits.count)
        return rest.isEmpty || ["st", "nd", "rd", "th"].contains(String(rest))
    }

    /// Words that describe the upload rather than the performance. Notably absent: "remix",
    /// "live", "mix", "acoustic" and friends, which are in `variantWords` instead.
    private static let decorationWords: Set<String> = [
        "remaster", "remastered", "remastering", "remasters", "master", "mastered",
        "version", "edit", "radio", "single", "album", "original", "reissue", "digital",
        "official", "video", "audio", "music", "lyric", "lyrics", "visualizer", "visualiser",
        "hd", "hq", "4k", "explicit", "clean", "deluxe", "edition", "expanded", "anniversary",
        "bonus", "track", "mono", "stereo", "from", "taken", "the", "a", "an", "new",
    ]

    // MARK: - Variant words

    /// Words that mean "a different recording of this song", counted rather than collected.
    ///
    /// Counting is what tells "Live Forever" from "Live Forever - Live at Knebworth". A set
    /// collapses both to `{live}` and the live take passes a gate whose entire job is to catch
    /// it; the same goes for "Live and Let Die (Live)" and "Remix to Ignition (Remix)", which
    /// are precisely the songs whose real titles contain the word. The count keeps them
    /// distinguishable while still leaving the honest case alone: one `live` on each side.
    private static func variantMarkers(in tokens: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for token in tokens {
            guard let marker = variantWords[token] else { continue }
            counts[marker, default: 0] += 1
        }
        return counts
    }

    private static let variantWords: [String: String] = [
        "remix": "remix", "remixes": "remix", "remixed": "remix", "rmx": "remix",
        "live": "live", "unplugged": "live", "rehearsal": "live", "bootleg": "live",
        "acoustic": "acoustic",
        "cover": "cover", "tribute": "cover", "remake": "cover",
        "karaoke": "karaoke", "backing": "karaoke",
        "instrumental": "instrumental", "instrumentals": "instrumental",
        "acapella": "acapella", "cappella": "acapella",
        "demo": "demo",
        "reprise": "reprise",
        "nightcore": "sped", "sped": "sped", "spedup": "sped", "speedup": "sped",
        "slowed": "slowed", "reverb": "slowed",
        "mashup": "mashup", "medley": "mashup",
        "mix": "mix", "dub": "dub",
        "orchestral": "orchestral", "symphonic": "orchestral",
        "parody": "parody",
        "8d": "8d",
    ]

    // MARK: - Similarity

    /// Token overlap blended with character-bigram overlap.
    ///
    /// Neither alone is enough. Token overlap is the honest measure for English titles and is
    /// what stops "Yesterday" from matching "Yesterday Once More", but it scores zero for
    /// Japanese and Korean titles, which have no spaces to tokenise on at all. Bigram overlap
    /// carries those, and also softens a single mistyped or transliterated word. Deliberately
    /// symmetric — a containment measure would rate every title as a perfect match for any title
    /// that merely starts with it.
    private static func similarity(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }

        let setA = Set(a), setB = Set(b)
        let union = setA.union(setB).count
        let jaccard = union == 0 ? 0 : Double(setA.intersection(setB).count) / Double(union)

        return 0.6 * jaccard + 0.4 * dice(a.joined(), b.joined())
    }

    /// Sørensen–Dice over character bigrams, counted with multiplicity.
    private static func dice(_ a: String, _ b: String) -> Double {
        let left = bigrams(a), right = bigrams(b)
        guard !left.isEmpty, !right.isEmpty else { return a == b ? 1 : 0 }

        var pool: [String: Int] = [:]
        for gram in left { pool[gram, default: 0] += 1 }
        var shared = 0
        for gram in right where (pool[gram] ?? 0) > 0 {
            pool[gram]! -= 1
            shared += 1
        }
        return 2 * Double(shared) / Double(left.count + right.count)
    }

    private static func bigrams(_ text: String) -> [String] {
        let characters = Array(text)
        guard characters.count > 1 else { return characters.map(String.init) }
        return (0..<(characters.count - 1)).map { String(characters[$0...$0 + 1]) }
    }

    private static func isPlaceholder(_ value: String, equals placeholder: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == placeholder
    }

    // MARK: - Writing systems

    /// A coarse bucket, and coarse on purpose: the only question asked of it is whether two
    /// strings could be spellings of the same name at all. Han, kana and Hangul are one bucket
    /// rather than three, because a Japanese credit routinely mixes the first two and because
    /// merging them is the conservative direction — two names in the same bucket that share
    /// nothing keep the veto they have today.
    private enum Script: Hashable {
        case latin, cyrillic, greek, cjk, arabic, hebrew, devanagari, thai
    }

    private static func scripts(of text: String) -> Set<Script> {
        var found: Set<Script> = []
        for scalar in text.unicodeScalars {
            // Digits, punctuation and anything unlisted say nothing about the writing system —
            // "Кино 2" must not count as part-Latin because of the numeral.
            guard let script = script(of: scalar) else { continue }
            found.insert(script)
        }
        return found
    }

    private static func script(of scalar: Unicode.Scalar) -> Script? {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: return .latin
        case 0x370...0x3FF, 0x1F00...0x1FFF: return .greek
        case 0x400...0x52F: return .cyrillic
        case 0x590...0x5FF: return .hebrew
        case 0x600...0x6FF, 0x750...0x77F: return .arabic
        case 0x900...0x97F: return .devanagari
        case 0xE00...0xE7F: return .thai
        case 0x1100...0x11FF, 0x3040...0x30FF, 0x3130...0x318F,
             0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xAC00...0xD7AF, 0xF900...0xFAFF: return .cjk
        default: return nil
        }
    }

    // MARK: - Artists

    /// One side's artist credit, in the two forms it has to be compared in.
    ///
    /// The two catalogues never write this field the same way. Spotify comma-joins every credited
    /// artist; YouTube Music returns the artist runs comma-joined too (`parseSearchItem`), but
    /// usually names only the lead, and for a great many songs the "artist" is an auto-generated
    /// "<Artist> - Topic" channel or a label channel with the name run together and a suffix
    /// glued on. Equality is useless here and even token overlap fails on "TheWeekndVEVO", so
    /// both a token view and a run-together view are kept.
    private struct ArtistName {
        let tokens: Set<String>
        /// The same tokens in the order they were written. Only the *first* one distinguishes
        /// Nat King Cole from Natalie Cole, and a set has thrown that away.
        let ordered: [String]
        let compact: String
        let isReadable: Bool
        /// `variantWords` read off the credit rather than the title, so "Metallica Tribute Band"
        /// can be told from "Metallica". Counted over every token including the noise words,
        /// because "band" is noise but "tribute" is the entire point.
        let markers: [String: Int]
        /// Which writing systems the credit is written in, so that a romanised name and a native
        /// one can be recognised as two spellings rather than two artists.
        let scripts: Set<Script>

        init(_ raw: String) {
            let folded = TrackMatcher.fold(raw)
            let known = !folded.trimmingCharacters(in: .whitespaces).isEmpty
                && !TrackMatcher.isPlaceholder(folded, equals: "unknown artist")

            let all = TrackMatcher.tokenise(folded)
            ordered = all.filter { !ArtistName.noise.contains($0) }
            tokens = Set(ordered)
            markers = TrackMatcher.variantMarkers(in: all)

            var run = all.filter { !ArtistName.channelSuffixes.contains($0) }.joined()
            for suffix in ArtistName.channelSuffixes
            where run.hasSuffix(suffix) && run.count > suffix.count {
                run.removeLast(suffix.count)
            }
            compact = run
            scripts = TrackMatcher.scripts(of: run)
            isReadable = known && (!tokens.isEmpty || !compact.isEmpty)
        }

        /// 1 when one credit is contained in the other, 0 when they disagree, and nil when there
        /// is no evidence either way — which is not the same thing as a mismatch and must not be
        /// scored as one, because `score` treats a 0 as fatal.
        func agreement(with other: ArtistName) -> Double? {
            guard isReadable, other.isReadable else { return nil }

            let shared = tokens.intersection(other.tokens)
            let smaller = min(tokens.count, other.tokens.count)
            let containment = smaller == 0 ? 0 : Double(shared.count) / Double(smaller)
            if containment >= 1 { return 1 }

            // "The Weeknd" against "TheWeekndVEVO" shares no whitespace-separated token at all.
            // Restricted to a prefix or suffix, and to names long enough that the coincidence is
            // implausible, because a free substring test starts matching Sia inside Asia.
            let (short, long) = compact.count <= other.compact.count
                ? (compact, other.compact) : (other.compact, compact)
            if short.count >= 4, long.hasPrefix(short) || long.hasSuffix(short) { return 1 }

            // Spotify romanises where YouTube Music uses the catalogue's own name: "Kenshi
            // Yonezu" against "米津玄師", "BTS" against "방탄소년단", "Kino" against "Кино". Nothing
            // here transliterates, so those score 0 — and 0 is fatal, which made an identical
            // title and an exact duration count for nothing and turned every J-pop and K-pop
            // playlist into a wall of misses. Two credits with no letter-system in common are
            // an absence of evidence, exactly like an unreadable one, so they are worth the
            // same as one. Same-script names that share nothing still disagree, and still veto.
            if shared.isEmpty, !scripts.isEmpty, !other.scripts.isEmpty,
               scripts.isDisjoint(with: other.scripts) {
                return nil
            }

            // A single shared token, and it is not the name either credit leads with: that is a
            // shared surname, which is how "Unforgettable" by Nat King Cole matched Natalie
            // Cole's 1991 recording at 0.885, and "Just Breathe" by Willie Nelson matched Lukas
            // Nelson. Partial agreement stays usable when the leading name is the shared one —
            // "The Weeknd, Ariana Grande" against "The Weeknd, Doja Cat" is still the right
            // artist — but a surname on its own is not evidence, and treating it as weak
            // positive evidence is enough to carry a cover past the threshold on its own.
            if let mine = ordered.first, let theirs = other.ordered.first,
               !shared.contains(mine), !shared.contains(theirs) {
                return 0
            }

            return containment
        }

        /// Words that appear in a channel name without being part of anybody's name.
        static let noise: Set<String> = [
            "the", "topic", "vevo", "official", "officiel", "music", "channel", "records",
            "recordings", "band", "tv", "hd", "audio", "lyrics", "and", "feat", "ft",
            "featuring", "with",
        ]

        static let channelSuffixes: Set<String> = ["vevo", "topic", "official"]
    }
}
