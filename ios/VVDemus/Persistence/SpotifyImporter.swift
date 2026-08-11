import Foundation

/// What the import sheet shows once the run is over. It is a value, not a live view of the
/// store, because the summary has to survive the playlist being renamed or deleted from
/// another screen while the sheet is still up.
struct ImportSummary: Equatable {
    let playlistName: String
    /// How many songs Spotify's embed gave us — not how many the playlist really has, which
    /// is unknowable past 100. See `truncated`.
    let requested: Int
    let added: Int
    /// The Spotify rows nothing acceptable came back for, carried whole so the sheet can
    /// print "Title — Artist" and the user can go find them by hand.
    let misses: [SpotifyTrack]
    let truncated: Bool
    /// The rate limiter cut the run short. Everything matched before that point was still
    /// written: throwing away twenty good matches because the twenty-first was throttled
    /// would be the worst of both worlds.
    let stoppedEarly: Bool

    /// Whether there is now a playlist in the library at all.
    ///
    /// `SpotifyImporter.write` refuses to create one when nothing matched — an empty playlist
    /// named after the Spotify one is litter — so a finished run is not the same thing as a
    /// successful one. The sheet led with a green "Imported "Deep Cuts"" over "Added 0 of 12
    /// songs" and the user went looking in the Library for a playlist that had never been
    /// created. Derived here rather than re-decided in the view so the two cannot drift.
    var didCreatePlaylist: Bool { added > 0 }
}

/// The seam that keeps this class testable.
///
/// `PlaylistStore` is a singleton over `UserDefaults.standard` with a `private init` and a
/// hardcoded key, and every `save()` pokes `PeerLink.shared.libraryDidChange()`, which
/// schedules a real sync push to a paired device. A test that asserted import ordering
/// against the real store would therefore leave tombstoned playlists in the simulator's
/// defaults forever and could push them at whatever phone happens to be paired. The
/// importer only ever needs two calls, so it takes them as a protocol and the test passes a
/// recording double.
@MainActor
protocol PlaylistWriting {
    @discardableResult func create(name: String) -> Playlist
    func addTrack(_ track: Track, to playlist: Playlist)
}

extension PlaylistStore: PlaylistWriting {}

/// Copies a public Spotify playlist into a local one: fetch the embed page, match every row
/// against YouTube Music's search, then write the survivors in Spotify's order.
///
/// Two rules shape the whole class. The playlist is created only after the last search has
/// come back, so Cancel — or a crash, or the sheet being swiped away — leaves nothing
/// half-built in the library. And results are collected into a fixed-size array **by index**
/// rather than appended as they arrive, because searches run three at a time and finish in
/// whatever order YouTube feels like: appending would silently shuffle the album into
/// response-time order, which looks like a working import right up until someone plays it.
@MainActor
final class SpotifyImporter: ObservableObject {
    enum Phase: Equatable {
        case idle
        case fetching
        case matching(completed: Int, total: Int, current: String)
        case finished(ImportSummary)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Three at a time. One at a time makes a 100-song import take minutes; opening all 100
    /// at once is the reliable way to trip `RateLimitGate` on the first playlist anyone
    /// tries, and the gate is process-wide, so it would take Search and Home down with it.
    static let concurrentSearches = 3

    /// Deliberately larger than the matcher usually needs. The candidate list costs nothing
    /// extra — the response page size is fixed — and a bad first hit with the right song at
    /// position five is the common case for anything with a lyric video.
    static let searchLimit = 10

    private let fetchPage: (String) async throws -> SpotifyPlaylistPage
    private let search: (String) async throws -> [Track]
    private let store: any PlaylistWriting

    /// Which run owns the importer's state. Every path that publishes a phase or writes to the
    /// store compares the token it started with against this one, so a run that has been
    /// cancelled or superseded can no longer touch anything no matter how long its awaits take
    /// to unwind. It replaces a plain `isCancelled` flag, which could only say *that* a
    /// cancellation had happened and not *which* run it belonged to.
    private var runToken = 0

    /// The token of the run the user is still waiting on, or nil when there is none.
    ///
    /// Separate from `runToken` because "a run is in flight" and "the user still wants it" stop
    /// being the same thing the moment Cancel is pressed. Clearing it there is what makes the
    /// next Import work: this used to be a single `isRunning` flag cleared by a `defer`, so
    /// after Cancel the sheet went back to an enabled Import button while the abandoned fetch
    /// was still retrying against a 15-second timeout — and every tap in that window hit the
    /// re-entrancy guard and returned in silence, with no spinner, no message and no change of
    /// phase. Tens of seconds of a dead button, recoverable only by closing the sheet.
    private var liveToken: Int?

    init(
        fetchPage: @escaping (String) async throws -> SpotifyPlaylistPage = {
            try await SpotifyImportClient.fetch(playlistId: $0)
        },
        search: @escaping (String) async throws -> [Track] = {
            try await APIClient.shared.search($0, limit: SpotifyImporter.searchLimit)
        },
        // Nil rather than `= PlaylistStore.shared`, which is what this said first. A default
        // argument expression is evaluated in a *nonisolated* context even when the
        // initialiser it belongs to is `@MainActor`, and `PlaylistStore.shared` is
        // main-actor state — so the obvious spelling compiles with a warning today and stops
        // compiling outright under the Swift 6 language mode. Resolving it inside the body,
        // which really is on the main actor, keeps `SpotifyImporter()` meaning the same thing
        // at every call site.
        store: (any PlaylistWriting)? = nil
    ) {
        self.fetchPage = fetchPage
        self.search = search
        self.store = store ?? PlaylistStore.shared
    }

    /// - Parameter name: what the user typed over the pre-filled field. Blank means "keep
    ///   Spotify's name", which is not known until the page has been fetched.
    func run(link: String, name: String?) async {
        // The sheet's button is disabled while a run is in flight, but a hardware keyboard
        // return, a double tap and an Apple Watch relay have all managed to fire an action
        // twice elsewhere in this app. A second run here would race two task groups onto
        // one `phase` and burn a second set of searches against the rate limiter for the same
        // playlist. A run the user has *cancelled* is deliberately not covered: it no longer
        // holds `liveToken`, so the retry the user is asking for starts immediately.
        guard liveToken == nil else { return }

        guard let playlistId = SpotifyPlaylistLink.playlistId(from: link) else {
            phase = .failed(message(for: SpotifyImportError.notAPlaylistLink))
            return
        }

        runToken &+= 1
        let token = runToken
        liveToken = token
        // Only if this run still owns the slot: a superseded run must not free the slot the run
        // that replaced it is holding.
        defer { if liveToken == token { liveToken = nil } }

        phase = .fetching
        let page: SpotifyPlaylistPage
        do {
            page = try await fetchPage(playlistId)
        } catch {
            guard token == runToken else { return }
            phase = .failed(message(for: error))
            return
        }
        guard token == runToken else { return }

        let outcome = await match(page.tracks, token: token)
        guard token == runToken else { return }

        let requestedName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let playlistName = requestedName.isEmpty ? page.name : requestedName
        let added = write(outcome.matches, named: playlistName)

        phase = .finished(
            ImportSummary(
                playlistName: playlistName,
                requested: page.tracks.count,
                added: added,
                misses: outcome.misses,
                truncated: page.isPossiblyTruncated,
                stoppedEarly: outcome.stoppedEarly
            )
        )
    }

    /// Safe at any point, including before a run and after one has finished.
    ///
    /// Moving the token is the whole mechanism: the abandoned run keeps going until its awaits
    /// unwind, but every path in it that could publish a phase, launch another search or write
    /// to the store compares its own token first, so none of them fire. That is what the user
    /// asked for — no playlist appears — and it is also what frees the importer for the next
    /// Import straight away instead of after the last retry ladder has run out.
    ///
    /// The searches already in flight are not torn down here: `match` calls `group.cancelAll()`
    /// at the next result boundary, which propagates into their `URLSession` tasks, and the one
    /// or two responses that land before then cost nothing because nobody reads them. Not, as
    /// this comment used to say, because a cancelled request would land in `RateLimitGate` as a
    /// transport failure — it would not. Cancellation surfaces as `URLError.cancelled`, which
    /// `RateLimit.isRetryable` deliberately excludes and `InnerTubeClient.send` rethrows without
    /// ever touching the gate. The wrong reason is recorded because it is what made leaving a
    /// cancelled run to unwind on its own look mandatory, and that is how the dead Import
    /// button survived as long as it did.
    func cancel() {
        runToken &+= 1
        liveToken = nil
        switch phase {
        case .fetching, .matching:
            phase = .idle
        case .idle, .finished, .failed:
            // A finished summary is left on screen; the sheet's own dismiss takes it away.
            // Wiping it here would blank the sheet if Cancel and the last result raced.
            break
        }
    }

    /// Drops a failure message once the link it was about is no longer the one in the field.
    ///
    /// The sheet keeps the form up under a `.failed` phase on purpose — a private playlist
    /// swapped for a public one is a one-keystroke fix and throwing the pasted link away would
    /// be rude — but nothing cleared the message, so "Spotify won't share that playlist" sat
    /// above a corrected link and, while the replacement was half-typed, alongside a second
    /// orange line about a different problem. Only a failure is cleared: a run in flight and a
    /// finished summary are both left exactly as they are.
    func clearFailure() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Matching

    private struct MatchOutcome {
        /// One slot per Spotify row, in Spotify's order. `nil` is "no acceptable match, or
        /// never attempted".
        let matches: [Track?]
        let misses: [SpotifyTrack]
        let stoppedEarly: Bool
    }

    private func match(_ tracks: [SpotifyTrack], token: Int) async -> MatchOutcome {
        guard !tracks.isEmpty else { return MatchOutcome(matches: [], misses: [], stoppedEarly: false) }

        var matches = [Track?](repeating: nil, count: tracks.count)
        /// Held as indices rather than tracks so the miss list can be rebuilt in Spotify's
        /// order at the end — results land in completion order, and a summary that lists the
        /// misses in a different order from the playlist is confusing to read against it.
        var missed: Set<Int> = []
        var stoppedEarly = false
        var completed = 0
        /// The rows that have been handed to the group and have not come back. `current` is
        /// the lowest of them, so the sheet names a song that is genuinely being worked on
        /// rather than the last one that happened to finish.
        var inFlight: Set<Int> = []

        let search = self.search

        await withTaskGroup(of: (Int, Result<Track?, Error>).self) { group in
            var next = 0

            // Annotated even though the closure around it already runs on the main actor: a
            // *local* function does not inherit the isolation its enclosing closure inferred,
            // so without this it is nonisolated and cannot read `runToken` at all.
            @MainActor func launchNext() {
                guard next < tracks.count, token == runToken, !stoppedEarly else { return }
                let index = next
                let spotify = tracks[index]
                next += 1
                inFlight.insert(index)
                group.addTask {
                    do {
                        let candidates = try await search(Self.searchQuery(for: spotify))
                        return (index, .success(TrackMatcher.bestMatch(for: spotify, among: candidates)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            for _ in 0..<min(Self.concurrentSearches, tracks.count) { launchNext() }
            publishProgress(completed: completed,
                            total: tracks.count,
                            current: current(in: inFlight, of: tracks),
                            token: token)

            while let (index, result) = await group.next() {
                completed += 1
                inFlight.remove(index)

                switch result {
                case .success(let track):
                    if let track {
                        matches[index] = track
                    } else {
                        missed.insert(index)
                    }
                case .failure(let error):
                    if (error as? APIError)?.isRateLimit == true {
                        // Hammering through the remaining rows would only deepen the
                        // cool-down and take the rest of the app down with it. The rows
                        // already in flight are left to land — they are past the gate.
                        // This row is not reported as a miss: nothing says it would not
                        // have matched, and listing it under "couldn't find" would be a lie.
                        stoppedEarly = true
                    } else {
                        // One search failing on its own — a 500, a dropped connection — is
                        // a miss for that song and nothing more. Aborting a 90-song import
                        // over one flaky response is not a trade anyone wants.
                        missed.insert(index)
                    }
                }

                if token != runToken {
                    group.cancelAll()
                    break
                }

                launchNext()
                publishProgress(
                    completed: completed,
                    total: tracks.count,
                    current: current(in: inFlight, of: tracks) ?? tracks[index].title,
                    token: token
                )
            }
        }

        let misses = missed.sorted().map { tracks[$0] }
        return MatchOutcome(matches: matches, misses: misses, stoppedEarly: stoppedEarly)
    }

    private func current(in inFlight: Set<Int>, of tracks: [SpotifyTrack]) -> String? {
        inFlight.min().map { tracks[$0].title }
    }

    private func publishProgress(completed: Int, total: Int, current: String?, token: Int) {
        guard token == runToken else { return }
        phase = .matching(completed: min(completed, total), total: total, current: current ?? "")
    }

    /// Title plus the *primary* artist only.
    ///
    /// Spotify's `subtitle` comma-joins every credited artist, and pasting all six of them
    /// into a YouTube Music query pushes the real song off the first page in favour of
    /// remix compilations that happen to name the same people. The full artist string is
    /// still what `TrackMatcher` scores against, so dropping the features here costs
    /// nothing in precision and buys a lot of recall.
    static func searchQuery(for track: SpotifyTrack) -> String {
        let primaryArtist = track.artist
            .split(separator: ",", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return "\(track.title) \(primaryArtist)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Writing

    /// - Returns: how many songs the playlist actually gained.
    private func write(_ matches: [Track?], named name: String) -> Int {
        // Two Spotify rows can match the same YouTube video — a single released twice, an
        // album and its deluxe edition in one playlist. `PlaylistStore.addTrack` is a no-op
        // for a videoId it already holds, so counting successful matches would report more
        // songs than the playlist contains. Dedupe here instead, and count what we wrote.
        var seen: Set<String> = []
        let toAdd = matches.compactMap { $0 }.filter { seen.insert($0.videoId).inserted }

        // Nothing matched: an empty playlist named after the Spotify one is litter the user
        // then has to delete. The summary already says what happened.
        guard !toAdd.isEmpty else { return 0 }

        let playlist = store.create(name: name)
        for track in toAdd { store.addTrack(track, to: playlist) }
        return toAdd.count
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Couldn't import that playlist."
    }
}
