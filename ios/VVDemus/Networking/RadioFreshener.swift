import Foundation

/// Where a refresh gets songs from. A protocol so the gathering below can be tested without
/// the network — and, unlike the app's `RadioFetching`, deliberately not `@MainActor`, since
/// the control server awaits a refresh from one of Swifter's worker threads.
protocol RadioSource: Sendable {
    func page(seed: String, limit: Int) async throws -> RadioPage
    func continuationPage(_ token: String) async throws -> RadioPage
}

struct InnerTubeRadioSource: RadioSource {
    func page(seed: String, limit: Int) async throws -> RadioPage {
        try await InnerTubeClient.radioPage(videoId: seed, limit: limit)
    }

    func continuationPage(_ token: String) async throws -> RadioPage {
        try await InnerTubeClient.radioContinuation(token: token)
    }
}

/// Collects songs a station has not shown yet, for `RadioRefreshPolicy` to fold in.
///
/// Three seams, in the order they are worth spending a request on:
///
/// 1. **The station's own next page.** A radio is infinite and every page carries a token for
///    the one after it. Measured: pages two, three and four of one station contributed 22, 19
///    and 14 songs the earlier pages had not. This is the right answer — same station, new
///    songs — and the token is kept so the *next* refresh pages deeper still rather than
///    starting over at page two.
/// 2. **Page one again.** Worth about 19 new songs of 50 against a list you already have,
///    which is not enough on its own (that is the bug) but is useful alongside the rest. It
///    also re-mints a token when the stored one has gone stale.
/// 3. **A neighbour's radio**, seeded from a song already in the list and rotated per refresh
///    so consecutive refreshes never pick the same one. This is the same move autoplay makes
///    at the end of a queue, and it drifts furthest from the seed — so it goes last.
enum RadioFreshener {
    /// Ceiling on upstream calls for one refresh. Six is roughly four seconds against a
    /// warm network, and a refresh is something the user is watching a spinner for.
    static let maximumRequests = 6

    struct Supply {
        let tracks: [Track]
        /// Where the station's paging got to, to be stored and resumed next time.
        let continuation: String?
    }

    /// - Parameters:
    ///   - recentlyShown: songs the station has put on screen within the last few refreshes.
    ///     Never offered — without this a song retired two refreshes ago comes straight back,
    ///     and "nothing you started with survives three refreshes" quietly stops being true.
    ///   - recyclable: songs it showed longer ago than that. Offered only after everything
    ///     genuinely new has been collected, and this is what keeps a station that has
    ///     exhausted YouTube's suggestions from dead-ending: measured, a seed runs out of new
    ///     material somewhere around the fifth refresh in a sitting, and without a way back to
    ///     its older material Refresh would answer "nothing new" from then on forever.
    ///   - needed: how many genuinely new ones are wanted. Gathering stops as soon as the
    ///     count is met — the recycled ones ride along, they are not worth a request of their
    ///     own.
    static func candidates(
        seed: String,
        body: [Track],
        recentlyShown: Set<String>,
        recyclable: Set<String> = [],
        needed: Int,
        continuation: String?,
        rotation: Int,
        limit: Int = InnerTubeClient.radioLength,
        source: RadioSource = InnerTubeRadioSource()
    ) async -> Supply {
        var fresh: [Track] = []
        var recycled: [Track] = []
        var picked = recentlyShown.union(body.map(\.videoId)).union([seed])
        var token = continuation
        var pivots = pivotSeeds(from: body, seed: seed, rotation: rotation)
        var triedSeed = false
        var requests = 0

        /// Returns how many *new* songs the page contributed — recycled ones do not count
        /// towards the quota, and a page of nothing but those means the seam is spent.
        func absorb(_ page: RadioPage) -> Int {
            var added = 0
            for track in page.tracks where !track.isLongFormMix {
                guard picked.insert(track.videoId).inserted else { continue }
                if recyclable.contains(track.videoId) {
                    recycled.append(track)
                } else {
                    fresh.append(track)
                    added += 1
                }
            }
            return added
        }

        while fresh.count < needed, requests < maximumRequests {
            if let resuming = token {
                requests += 1
                guard let page = try? await source.continuationPage(resuming) else {
                    token = nil
                    continue
                }
                // A page that is entirely songs we already hold means this seam is spent;
                // paging further down it burns the request budget for nothing. (An expired
                // token answers with an empty page rather than an error, and looks the same
                // from here — which is fine, the response is the same either way.)
                token = absorb(page) == 0 ? nil : page.continuation
            } else if !triedSeed {
                triedSeed = true
                requests += 1
                guard let page = try? await source.page(seed: seed, limit: limit) else { continue }
                _ = absorb(page)
                token = page.continuation
            } else if !pivots.isEmpty {
                let pivot = pivots.removeFirst()
                requests += 1
                guard let page = try? await source.page(seed: pivot, limit: limit) else { continue }
                _ = absorb(page)
                // Deliberately not adopting the pivot's token: it belongs to a different
                // station, and storing it would page this station off into someone else's.
            } else {
                break
            }
        }

        // New first, always: the policy takes them in order, so the older material is only
        // reached once there is nothing better to fill the list with.
        return Supply(tracks: fresh + recycled, continuation: token)
    }

    /// Up to two songs from the list to seed a neighbouring radio with, rotated so that a
    /// second refresh in a row asks a different pair.
    static func pivotSeeds(from body: [Track], seed: String, rotation: Int, count: Int = 2) -> [String] {
        let ids = body.map(\.videoId).filter { $0 != seed }
        guard !ids.isEmpty else { return [] }
        let start = abs(rotation * count) % ids.count
        return (0..<min(count, ids.count)).map { ids[(start + $0) % ids.count] }
    }
}
