import Foundation

/// The one path a radio refresh takes, wherever it was asked for.
///
/// The phone's radio screen, the Mac's, and the web remote's Refresh button all land here, so
/// the guarantee `RadioRefreshPolicy` makes is the same on all three and the three cannot
/// drift apart. (They already shared a cache; what they did not share was the decision, which
/// is how the screen and the browser could disagree about what a refresh even means.)
///
/// Deliberately not `@MainActor`, though `RadioCacheStore` is: the control server awaits this
/// from one of Swifter's worker threads, and a main-actor refresh would put several YouTube
/// round trips on the main thread while that worker blocks on a semaphore waiting for them.
/// It hops onto the actor twice — once to read the station, once to write it — and does the
/// waiting off it.
enum RadioRefreshService {
    enum Failure: Error {
        /// The station could not be found and no seed was offered to build one from.
        case unknownStation
        /// YouTube had nothing new to give. The caller keeps the mix it has; see
        /// `RadioRefreshPolicy.Outcome.metRequirement` for why a partial refresh is worse
        /// than none at all.
        case notEnoughNewSongs(found: Int, needed: Int)
    }

    /// Refreshes `seedVideoId`'s station and returns the new mix.
    ///
    /// - Parameter fallbackSeed: used only when the station has no cached mix at all — the
    ///   radio screen has the seed track in hand, the web remote's route has only an id.
    @discardableResult
    static func refresh(
        seedVideoId: String,
        fallbackSeed: Track? = nil,
        length: Int = InnerTubeClient.radioLength,
        source: RadioSource = InnerTubeRadioSource()
    ) async throws -> [Track] {
        let state = await MainActor.run { RadioCacheStore.shared.refreshState(for: seedVideoId) }

        // A station nobody has opened yet has nothing to refresh — build it instead. This is
        // the web remote refreshing a radio that only exists as a history entry.
        guard let seed = state.tracks.first ?? fallbackSeed else {
            let page = try await source.page(seed: seedVideoId, limit: length)
            guard !page.tracks.isEmpty else { throw Failure.unknownStation }
            await MainActor.run {
                RadioCacheStore.shared.store(page.tracks, for: seedVideoId, continuation: page.continuation)
            }
            return page.tracks
        }

        let body = state.tracks.filter { $0.videoId != seed.videoId }
        // Asked for generously rather than exactly: the policy takes what it needs and the
        // spare is what absorbs a page that turns out to be mostly songs we already hold.
        let needed = RadioRefreshPolicy.requiredNewCount(bodyLength: max(body.count, length - 1))
        let supply = await RadioFreshener.candidates(
            seed: seed.videoId,
            body: body,
            recentlyShown: state.recentlyShown,
            recyclable: state.recyclable,
            needed: needed,
            continuation: state.continuation,
            rotation: state.generation,
            limit: length,
            source: source
        )

        let outcome = RadioRefreshPolicy.apply(
            seed: seed,
            current: state.tracks,
            generations: state.generations,
            generation: state.generation,
            candidates: supply.tracks,
            length: length
        )

        guard outcome.metRequirement else {
            // The paging position is still worth keeping even though the mix is not: the
            // songs those requests found are recorded as seen only when a refresh lands, so
            // without this the next attempt would walk the same pages to the same dead end.
            await MainActor.run {
                RadioCacheStore.shared.rememberPagingPosition(supply.continuation, for: seedVideoId)
            }
            throw Failure.notEnoughNewSongs(found: outcome.newCount, needed: outcome.requiredNewCount)
        }

        await MainActor.run {
            RadioCacheStore.shared.applyRefresh(
                outcome.tracks,
                generations: outcome.generations,
                generation: state.generation,
                continuation: supply.continuation,
                for: seedVideoId
            )
        }
        return outcome.tracks
    }
}
