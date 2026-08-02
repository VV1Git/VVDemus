import Foundation

/// A "daylist": a mix built from what this device knows the user actually listens to, at
/// this time of day. Refreshable on demand and auto-regenerated once the time-of-day bucket
/// changes (morning/afternoon/evening/night) — approximating Spotify's daylist without any
/// personalization backend.
///
/// The seeds, the ranking and the time-of-day bias all come from `TasteProfile`. This used to
/// be three unweighted recently-played tracks, a hardcoded mood search, and
/// `pool.shuffled()` — which meant a lounge track from "afternoon vibes" had exactly the same
/// odds of landing as something by an artist the user plays daily.
@MainActor
final class DaylistStore: ObservableObject {
    static let shared = DaylistStore()

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var title: String = ""
    @Published private(set) var generatedAt: Date?
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?

    /// Bumped to v2 to discard mixes built before hour-long compilations were filtered
    /// out (and before release years were being misread as track durations), to v3 so
    /// the last 30-song daylist doesn't sit there until the time-of-day bucket moves on,
    /// and to v4 because a v3 snapshot is a shuffle of a generic mood search wearing the
    /// name of a personalized mix — it would sit on Home looking current until the bucket
    /// turned over.
    private let key = "daylist_v4"

    /// How many songs a daylist holds.
    static let length = 50

    /// How many seed radios a daylist is built from.
    ///
    /// Four, not three, because the mood search that used to run alongside them is now a
    /// fallback: the request budget is unchanged, it just buys a fourth radio chosen from the
    /// user's own listening instead of a page of "afternoon vibes".
    private static let seedCount = 4

    private struct Snapshot: Codable {
        let title: String
        let tracks: [Track]
        let generatedAt: Date
    }

    private init() { load() }

    /// Regenerates only if the time-of-day bucket has moved on since the last mix, or
    /// there's nothing cached yet — avoids re-fetching every time Home appears.
    func refreshIfNeeded() async {
        if let generatedAt, Self.bucket(for: generatedAt) == Self.currentBucket, !tracks.isEmpty {
            return
        }
        await refresh()
    }

    func refresh() async {
        isRefreshing = true
        errorMessage = nil
        do {
            let bucket = Self.currentBucket
            let profile = TasteProfile.current()
            let seeds = profile.seedCandidates(Self.seedCount)

            var pool: [Track] = []
            var seen = Set<String>()
            // Track id -> the affinity of the seed whose radio it arrived in, so the ranking
            // below can tell a song that came out of the user's strongest seed from one that
            // came out of the mood-search fallback.
            var provenance: [String: Double] = [:]

            // Takes whatever's new, minus the hour-long compilations: the mood queries
            // ("morning chill mix", "late night vibes") are exactly the phrasing that
            // surfaces meditation and lounge mixes, which then sit in the daylist looking
            // like songs.
            func absorb(_ candidates: [Track], from seedAffinity: Double) {
                for track in candidates.excludingLongFormMixes() {
                    // A song that turns up in two seeds' radios keeps the stronger
                    // provenance. That's evidence *for* it, not a reason to file it under
                    // whichever concurrent fetch happened to land first.
                    provenance[track.id] = max(provenance[track.id] ?? 0, seedAffinity)
                    guard seen.insert(track.id).inserted else { continue }
                    pool.append(track)
                }
            }

            if !seeds.isEmpty {
                // Each seed reports its own failure rather than throwing, for the reason
                // spelled out in `RecommendationsBuilder.build`: `for try await` rethrows the
                // first error and cancels its siblings, so one flaky radio took the whole
                // daylist with it. A pool short of a few candidates still makes a mix.
                let radios = await withTaskGroup(of: (Double, [Track]).self) { group -> [(Double, [Track])] in
                    for seed in seeds {
                        group.addTask {
                            guard let mix = try? await APIClient.shared.radio(videoId: seed.track.videoId) else {
                                return (seed.affinity, [])
                            }
                            return (seed.affinity, Array(mix.dropFirst()))
                        }
                    }
                    var results: [(Double, [Track])] = []
                    for await result in group { results.append(result) }
                    return results
                }
                for (affinity, list) in radios { absorb(list, from: affinity) }
            }

            // The generic mood search is a *fallback* now, not a co-equal source. Four seed
            // radios fill the pool several times over, so on anyone with listening history
            // this doesn't run at all — which is the point: "afternoon vibes" describes the
            // clock, not the person, and it used to be shuffled in on equal footing with the
            // user's own radios. On a cold start it is still the only thing there is.
            //
            // Search returns a fixed page whatever limit is asked for, so taking all of it
            // costs no more than a slice — see `InnerTubeClient.dataSaverLimit`.
            if pool.count < Self.length,
               let mood = try? await APIClient.shared.search(bucket.searchQuery, limit: Self.length) {
                absorb(mood, from: 0)
            }

            // With no listening history yet, the mood search is the only source and its page
            // holds 20 songs — well short of a full daylist. Rather than paging search, grow
            // the pool the way the rest of the app does: a radio seeded from a song already
            // in it. Each one adds ~50 candidates, so this almost never needs a second pass,
            // and it doesn't run at all once there's history to build from.
            var topUpIndex = 0
            while pool.count < Self.length, topUpIndex < min(2, pool.count) {
                let seed = pool[topUpIndex]
                topUpIndex += 1
                guard let mix = try? await APIClient.shared.radio(videoId: seed.videoId) else { continue }
                absorb(Array(mix.dropFirst()), from: 0)
            }

            guard !pool.isEmpty else {
                throw APIError.server("No recommendations available right now.")
            }

            let mix = profile.rank(pool, provenance: provenance, limit: Self.length)
            tracks = mix
            title = Self.title(for: bucket, mix: mix, anchor: seeds.first?.track.artist)
            generatedAt = Date()
            save()
        } catch {
            errorMessage = "Couldn't build your Daylist right now."
        }
        isRefreshing = false
    }

    // MARK: - Time-of-day bucket

    /// The bucket itself lives in `TasteProfile.swift`, which has to sort thirteen months of
    /// play events into buckets from outside the main actor. `nonisolated` for the same
    /// reason: these are pure functions of the clock and nothing here reads store state.
    typealias Bucket = TimeOfDayBucket

    nonisolated static var currentBucket: Bucket { .current }

    nonisolated static func bucket(for date: Date) -> Bucket { Bucket(at: date) }

    /// Names the mix after the artist it was actually built around, when one of them really
    /// anchors it — Spotify's daylist names itself after its contents, and "Saturday Afternoon
    /// Mix" only repeats the greeting sitting directly above the card. The anchor has to turn
    /// up in the finished mix at least twice: a seed whose radio came back full of other
    /// people would put a name on the card that one scroll disproves.
    private static func title(for bucket: Bucket, mix: [Track], anchor: String?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        let day = formatter.string(from: Date())
        guard let anchor, !anchor.isEmpty else { return "\(day) \(bucket.label) Mix" }
        let key = TasteProfile.artistKey(anchor)
        let presence = mix.filter { TasteProfile.artistKey($0.artist) == key }.count
        guard presence >= 2 else { return "\(day) \(bucket.label) Mix" }
        return "\(day) \(bucket.label) with \(anchor)"
    }

    // MARK: - Persistence

    private func load() {
        guard let snapshot = DefaultsSnapshot.load(Snapshot.self, forKey: key) else { return }
        title = snapshot.title
        tracks = snapshot.tracks
        generatedAt = snapshot.generatedAt
    }

    private func save() {
        guard let generatedAt else { return }
        let snapshot = Snapshot(title: title, tracks: tracks, generatedAt: generatedAt)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
