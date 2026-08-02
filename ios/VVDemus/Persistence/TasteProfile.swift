import Foundation

/// Morning / afternoon / evening / night — the granularity the daylist and the Home greeting
/// both work in.
///
/// Declared here rather than nested inside `DaylistStore` because the taste profile buckets
/// every play event by it, and `DaylistStore` is `@MainActor`: a main-actor-isolated enum
/// can't be touched from the pure scoring code below. `DaylistStore.Bucket` stays as a
/// typealias so existing call sites read exactly as they did.
enum TimeOfDayBucket: Equatable {
    case morning, afternoon, evening, night

    init(at date: Date) {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: self = .morning
        case 12..<17: self = .afternoon
        case 17..<21: self = .evening
        default: self = .night
        }
    }

    static var current: TimeOfDayBucket { TimeOfDayBucket(at: Date()) }

    /// The generic mood query, kept only for the cold-start daylist — see
    /// `DaylistStore.refresh()` for why it is no longer a first-class source.
    var searchQuery: String {
        switch self {
        case .morning: return "morning chill mix"
        case .afternoon: return "afternoon vibes"
        case .evening: return "evening chill mix"
        case .night: return "late night vibes"
        }
    }

    var label: String {
        switch self {
        case .morning: return "Morning"
        case .afternoon: return "Afternoon"
        case .evening: return "Evening"
        case .night: return "Late Night"
        }
    }
}

/// What this device knows about the user's taste, derived from the local listening log.
///
/// The recommendation code used to seed itself from `PlayHistoryStore.recentSeeds(3)` — the
/// three most recently played tracks, unweighted — while `ListeningStatsStore` sat next to it
/// holding thirteen months of *timestamped* plays with how much of each track was actually
/// heard, and was read by nothing but the Stats screen. That's the signal this type turns
/// into seeds and rankings:
///
/// - **How much was heard**, not how many rows are in the log. A six-second sample and a full
///   play are one event each; only one of them is evidence.
/// - **When it was heard.** Weight decays with a half-life, so this month outranks last
///   spring without ever hard-cutting a range the way the Stats screen's pickers do.
/// - **When in the day it was heard.** Plays inside the current time-of-day bucket are mixed
///   in on top of the all-time picture, which is the difference between a daylist and a
///   playlist named after the clock.
/// - **Liked songs**, the one explicit statement of taste the app has.
///
/// Everything here is pure and off the main actor; `current()` is the main-actor entry point
/// that reads the stores and memoizes.
struct TasteProfile {
    struct ScoredTrack {
        let track: Track
        /// 0...1, relative to the strongest candidate in this profile.
        let affinity: Double
    }

    /// Seed candidates, strongest first.
    let candidates: [ScoredTrack]
    /// Artist key -> 0...1 affinity, relative to the user's strongest artist.
    let artistAffinity: [String: Double]
    /// Artists with at least one liked song.
    let likedArtists: Set<String>
    /// Every track the profile has seen, for the familiarity bonus when ranking a pool.
    let knownTrackIds: Set<String>
    /// How strongly the current time-of-day bucket steered this profile, 0...1. Zero means
    /// the bucket was too thin to trust and the profile is all-time.
    let timeOfDayWeight: Double

    /// Nothing played, nothing liked — a fresh install. Callers fall back to generic content
    /// rather than showing an empty screen.
    var isEmpty: Bool { candidates.isEmpty }

    // MARK: - Tuning

    /// Half-life of a play's weight, in days. At 45 days, a song played daily last spring is
    /// worth roughly a tenth of one played once this week — taste moves, but not overnight.
    static let recencyHalfLifeDays: Double = 45

    /// The fraction of a track that counts as having heard all of it. Queues advance a beat
    /// early, tracks fade out, and stated durations run a second or two long; none of that
    /// should cost a complete play its full weight.
    static let completePlayFraction: Double = 0.9

    /// Stand-in length for a track whose duration never came back from InnerTube, so those
    /// events contribute something rather than being silently dropped.
    static let assumedTrackSeconds: Double = 180

    /// A liked song is worth one recent complete play even if it has never been played on
    /// this device, and multiplies whatever plays it does have.
    static let likedCredit: Double = 1
    static let likedBoost: Double = 1.4

    /// How many plays a time-of-day bucket needs before it is trusted on its own, and the
    /// most of the profile it may ever steer.
    ///
    /// There are four buckets, so one holds roughly a quarter of a history. Forty plays is a
    /// couple of weeks of mornings; below that "what you play in the mornings" is three songs,
    /// and letting three songs pick a fifty-track daylist is worse than ignoring the clock.
    static let timeOfDayConfidencePlays: Double = 40
    static let maxTimeOfDayWeight: Double = 0.7

    /// Seed candidates kept. Nothing reads the tail, and this is held for the app's lifetime.
    static let candidateLimit = 60

    /// Weights for scoring a fetched pool against the profile.
    static let artistWeight: Double = 1
    static let provenanceWeight: Double = 0.5
    static let likedArtistBonus: Double = 0.35
    static let familiarTrackBonus: Double = 0.15
    /// Below this, an artist counts as new to the user — and so as exploration.
    static let familiarArtistThreshold: Double = 0.05

    // MARK: - Scoring primitives

    /// How much of the track was actually heard, 0...1.
    ///
    /// `ListeningStatsStore` already drops anything under five seconds, so every event here is
    /// at least deliberate — but "tapped it and bailed" and "played it through" are both one
    /// row in the log, and counting rows is exactly what made three consecutive skips look
    /// like a favourite artist.
    static func engagement(of event: PlayEvent) -> Double {
        let played = Double(event.secondsPlayed)
        guard let duration = event.track.durationSeconds, duration > 0 else {
            return min(1, played / assumedTrackSeconds)
        }
        return min(1, played / (Double(duration) * completePlayFraction))
    }

    /// Exponential decay rather than a cutoff: a range boundary would make a play worth full
    /// weight one day and nothing the next, and the daylist would visibly lurch when it
    /// crossed.
    static func recency(of date: Date, now: Date) -> Double {
        let ageDays = max(0, now.timeIntervalSince(date)) / 86_400
        return pow(0.5, ageDays / recencyHalfLifeDays)
    }

    /// Artists are matched on a trimmed, lowercased name: the same artist comes back as
    /// "Radiohead" from search and "radiohead" (or with a trailing space) from a radio, and an
    /// exact-string match quietly files those as two different people — halving the affinity
    /// of whoever the user listens to most.
    static func artistKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Building

    /// - Parameters:
    ///   - recents: `PlayHistoryStore`'s MRU list, used *only* when there are no events to
    ///     score. It carries neither timestamps nor listen time, so it can't take part in the
    ///     weighting — but it is the only thing there is for someone on their very first
    ///     track (a play is logged to `ListeningStatsStore` when it's *replaced*, not when it
    ///     starts), for history written before that store existed, and for plays that all
    ///     fell under its five-second recording floor.
    static func build(
        events: [PlayEvent],
        liked: [Track] = [],
        recents: [Track] = [],
        bucket: TimeOfDayBucket,
        now: Date = Date()
    ) -> TasteProfile {
        var trackScore: [String: Double] = [:]
        var bucketTrackScore: [String: Double] = [:]
        var artistScore: [String: Double] = [:]
        var bucketArtistScore: [String: Double] = [:]
        var trackById: [String: Track] = [:]
        var bucketPlays = 0

        for event in events {
            let weight = engagement(of: event) * recency(of: event.playedAt, now: now)
            guard weight > 0 else { continue }
            let track = event.track
            let artist = artistKey(track.artist)
            trackById[track.id] = track
            trackScore[track.id, default: 0] += weight
            artistScore[artist, default: 0] += weight
            guard TimeOfDayBucket(at: event.playedAt) == bucket else { continue }
            bucketPlays += 1
            bucketTrackScore[track.id, default: 0] += weight
            bucketArtistScore[artist, default: 0] += weight
        }

        let hasEvents = !trackScore.isEmpty

        var likedArtists: Set<String> = []
        for track in liked {
            let artist = artistKey(track.artist)
            likedArtists.insert(artist)
            if trackById[track.id] == nil { trackById[track.id] = track }
            trackScore[track.id] = max(trackScore[track.id] ?? 0, likedCredit) * likedBoost
            // The boost has to reach the bucket table too, or the blend below quietly undoes
            // it for anyone whose time-of-day history is strong enough to be trusted.
            if let played = bucketTrackScore[track.id] { bucketTrackScore[track.id] = played * likedBoost }
            artistScore[artist, default: 0] += likedCredit
        }

        if !hasEvents {
            for (index, track) in recents.prefix(candidateLimit).enumerated() {
                let artist = artistKey(track.artist)
                if trackById[track.id] == nil { trackById[track.id] = track }
                // Position is the only signal an MRU list has.
                let weight = 1 - Double(index) / Double(candidateLimit)
                trackScore[track.id] = max(trackScore[track.id] ?? 0, weight)
                artistScore[artist, default: 0] += weight
            }
        }

        let confidence = min(1, Double(bucketPlays) / timeOfDayConfidencePlays)
        let timeOfDayWeight = maxTimeOfDayWeight * confidence

        let trackAffinity = blended(all: trackScore, bucket: bucketTrackScore, weight: timeOfDayWeight)
        let candidates = trackAffinity
            .compactMap { entry -> ScoredTrack? in
                // A three-hour compilation makes a terrible seed: its radio is more of the
                // same, and one landing in a mix hijacks the queue for the afternoon.
                guard let track = trackById[entry.key], !track.isLongFormMix else { return nil }
                return ScoredTrack(track: track, affinity: entry.value)
            }
            // Ties broken on id, not left to dictionary order — otherwise the seeds (and so
            // the whole daylist) reshuffle between two builds of an identical profile.
            .sorted { $0.affinity == $1.affinity ? $0.track.id < $1.track.id : $0.affinity > $1.affinity }
            .prefix(candidateLimit)

        return TasteProfile(
            candidates: Array(candidates),
            artistAffinity: blended(all: artistScore, bucket: bucketArtistScore, weight: timeOfDayWeight),
            likedArtists: likedArtists,
            knownTrackIds: Set(trackScore.keys),
            timeOfDayWeight: timeOfDayWeight
        )
    }

    /// Mixes an all-time score table with the same table restricted to the current
    /// time-of-day bucket, and renormalizes so the strongest entry is 1.
    ///
    /// Both sides are normalized to their own maximum *before* blending. The bucket table is a
    /// strict subset of the all-time one and so is always numerically smaller; blending the
    /// raw sums would have left "what you play in the mornings" as a rounding error on top of
    /// the all-time picture, which is the signal that makes this a daylist at all.
    private static func blended(
        all: [String: Double],
        bucket: [String: Double],
        weight: Double
    ) -> [String: Double] {
        guard let allMax = all.values.max(), allMax > 0 else { return [:] }
        let bucketMax = bucket.values.max() ?? 0
        var result: [String: Double] = [:]
        result.reserveCapacity(all.count)
        var peak = 0.0
        for (key, value) in all {
            let bucketPart = bucketMax > 0 ? (bucket[key] ?? 0) / bucketMax : 0
            let score = (value / allMax) * (1 - weight) + bucketPart * weight
            result[key] = score
            peak = max(peak, score)
        }
        guard peak > 0 else { return [:] }
        return result.mapValues { $0 / peak }
    }

    // MARK: - Seeds

    /// Up to `count` seed tracks, strongest first and at most one per artist.
    ///
    /// The artist spread is the whole point of this over `recentSeeds(3)`: three songs from
    /// one album in a row produced three "Because you listened to…" shelves of what is
    /// effectively the same radio, and a daylist that only knew about one artist. Repeats are
    /// allowed only when the profile genuinely doesn't know `count` different artists.
    func seedCandidates(_ count: Int) -> [ScoredTrack] {
        guard count > 0 else { return [] }
        var picked: [ScoredTrack] = []
        var pickedIds: Set<String> = []
        var usedArtists: Set<String> = []
        for candidate in candidates where picked.count < count {
            guard usedArtists.insert(Self.artistKey(candidate.track.artist)).inserted else { continue }
            pickedIds.insert(candidate.track.id)
            picked.append(candidate)
        }
        for candidate in candidates where picked.count < count {
            guard pickedIds.insert(candidate.track.id).inserted else { continue }
            picked.append(candidate)
        }
        return picked
    }

    func seeds(_ count: Int) -> [Track] {
        seedCandidates(count).map(\.track)
    }

    // MARK: - Ranking a fetched pool

    private struct Pick {
        let track: Track
        let artist: String
        let score: Double
        /// The user has heard this artist before, so it isn't discovery.
        let isFamiliar: Bool
    }

    /// Picks `limit` tracks out of a fetched pool by affinity, instead of `pool.shuffled()`.
    ///
    /// A uniform shuffle gave a lounge track from a generic mood search exactly the same odds
    /// as something by an artist the user plays every day. This scores each candidate on the
    /// artist's affinity, whether the user has liked that artist, how strong the seed whose
    /// radio it arrived in was, and whether the track itself is already known.
    ///
    /// - Parameters:
    ///   - provenance: track id -> the affinity of the seed whose radio it came from.
    ///   - maxPerArtist: a cap, so one artist can't eat the mix. Relaxed rather than honoured
    ///     to the point of returning a short list — see below.
    ///   - explorationShare: the fraction of slots reserved for artists the profile has never
    ///     seen. Without it this is a closed loop: the profile picks the seeds, the seeds
    ///     decide the pool, the profile then picks its own artists back out of the pool, and
    ///     the user hears the same twenty songs until they break the cycle by hand.
    ///   - jitter: a little noise so two refreshes over a similar pool don't produce an
    ///     identical list. Tests pass 0.
    func rank(
        _ pool: [Track],
        provenance: [String: Double] = [:],
        limit: Int,
        maxPerArtist: Int = 3,
        explorationShare: Double = 0.2,
        jitter: Double = 0.12
    ) -> [Track] {
        guard limit > 0, !pool.isEmpty else { return [] }

        // Spelled out as a loop with explicit types rather than a `map { … }.sorted { … }`
        // chain: with everything inferred, this one expression took the type checker past its
        // time limit and failed the build outright.
        var scored: [Pick] = []
        scored.reserveCapacity(pool.count)
        for track in pool {
            let artist = Self.artistKey(track.artist)
            let artistScore: Double = artistAffinity[artist] ?? 0
            let seedAffinity: Double = provenance[track.id] ?? 0
            var score: Double = artistScore * Self.artistWeight
            score += seedAffinity * Self.provenanceWeight
            if likedArtists.contains(artist) { score += Self.likedArtistBonus }
            if knownTrackIds.contains(track.id) { score += Self.familiarTrackBonus }
            if jitter > 0 { score += Double.random(in: 0...jitter) }
            let isFamiliar: Bool = artistScore >= Self.familiarArtistThreshold
            scored.append(Pick(track: track, artist: artist, score: score, isFamiliar: isFamiliar))
        }
        let picks = scored.sorted { $0.score == $1.score ? $0.track.id < $1.track.id : $0.score > $1.score }

        let unfamiliar = picks.filter { !$0.isFamiliar }.count
        let exploreTarget = min(unfamiliar, Int((Double(limit) * explorationShare).rounded()))

        var chosenIds: Set<String> = []
        var perArtist: [String: Int] = [:]
        var core: [Pick] = []
        var explore: [Pick] = []

        func take(_ pick: Pick, into list: inout [Pick]) {
            list.append(pick)
            chosenIds.insert(pick.track.id)
            perArtist[pick.artist, default: 0] += 1
        }

        for pick in picks where core.count < limit - exploreTarget {
            guard !chosenIds.contains(pick.track.id),
                  perArtist[pick.artist, default: 0] < maxPerArtist else { continue }
            take(pick, into: &core)
        }
        for pick in picks where explore.count < exploreTarget {
            guard !pick.isFamiliar, !chosenIds.contains(pick.track.id),
                  perArtist[pick.artist, default: 0] < maxPerArtist else { continue }
            take(pick, into: &explore)
        }
        // The cap is a preference, not a promise. A pool that is genuinely two or three
        // artists deep — a cold start where one lounge channel owns the mood search — has to
        // still produce a full daylist rather than a twelve-song one.
        for pick in picks where core.count + explore.count < limit {
            guard chosenIds.insert(pick.track.id).inserted else { continue }
            core.append(pick)
        }

        return Self.merge(Self.spreadByArtist(core), inserting: explore).map(\.track)
    }

    /// Round-robin over artists, artists in descending score order: everyone gets one track
    /// before anyone gets a second.
    ///
    /// `shuffled()` used to do this spreading by accident. Straight score order does not — the
    /// user's most-played artist takes the opening slots and the mix starts sounding like a
    /// single-artist radio, which is the thing the per-artist cap exists to prevent.
    private static func spreadByArtist(_ picks: [Pick]) -> [Pick] {
        var byArtist: [String: [Pick]] = [:]
        var order: [String] = []
        for pick in picks {
            if byArtist[pick.artist] == nil { order.append(pick.artist) }
            byArtist[pick.artist, default: []].append(pick)
        }
        var result: [Pick] = []
        result.reserveCapacity(picks.count)
        var round = 0
        while result.count < picks.count {
            var placed = false
            for artist in order {
                guard let tracks = byArtist[artist], round < tracks.count else { continue }
                result.append(tracks[round])
                placed = true
            }
            // Can't happen — every round places at least one pick until all are placed — but
            // this loop runs on the main actor, so a bad edit here should not hang the app.
            guard placed else { break }
            round += 1
        }
        return result
    }

    /// Threads the exploration picks through the mix at a regular stride, instead of leaving
    /// them in a low-scoring clump at the end where they are the part nobody reaches.
    private static func merge(_ core: [Pick], inserting extras: [Pick]) -> [Pick] {
        guard !extras.isEmpty else { return core }
        guard !core.isEmpty else { return extras }
        let gap = max(1, core.count / extras.count)
        var result: [Pick] = []
        result.reserveCapacity(core.count + extras.count)
        var next = 0
        for (position, pick) in core.enumerated() {
            result.append(pick)
            if next < extras.count, (position + 1) % gap == 0 {
                result.append(extras[next])
                next += 1
            }
        }
        result.append(contentsOf: extras[next...])
        return result
    }
}

// MARK: - Live profile

@MainActor
private enum ProfileMemo {
    struct Fingerprint: Equatable {
        let events: Int
        let liked: Int
        let recents: Int
        let bucket: TimeOfDayBucket
    }

    static var profile: TasteProfile?
    static var fingerprint: Fingerprint?
}

extension TasteProfile {
    /// The profile for right now, built from the live stores.
    ///
    /// Memoized against a cheap fingerprint of its inputs rather than rebuilt per call: Home
    /// appearing kicks off the recommendation shelves and the daylist within the same run
    /// loop, and both want the same answer. Scoring thirteen months of events is a single
    /// pass over an array — a millisecond or two — but doing it twice for an identical result
    /// while the first track of a mix is loading is the kind of thing this app has paid for
    /// before. Any recorded play, any like, and the turn of the time-of-day bucket all move
    /// the fingerprint, so a stale profile can't outlive the listening that changed it.
    @MainActor
    static func current() -> TasteProfile {
        let stats = ListeningStatsStore.shared
        let liked = LikedSongsStore.shared
        let history = PlayHistoryStore.shared
        let fingerprint = ProfileMemo.Fingerprint(
            events: stats.events.count,
            liked: liked.tracks.count,
            recents: history.tracks.count,
            bucket: .current
        )
        if let cached = ProfileMemo.profile, ProfileMemo.fingerprint == fingerprint { return cached }

        let profile = build(
            events: stats.events,
            liked: liked.tracks,
            recents: history.tracks,
            bucket: fingerprint.bucket
        )
        ProfileMemo.profile = profile
        ProfileMemo.fingerprint = fingerprint
        return profile
    }
}
