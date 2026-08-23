import SwiftUI

/// The words to a track, scrolling themselves when — and only when — that is trustworthy.
///
/// Shared by both targets: pushed as a `LibraryDestination` on the phone, presented over
/// `NowPlayingView`, and embedded in `MacLyricsPanel` on the desktop. Nothing in here is
/// iOS-only, and nothing reaches for `RootView` or `MiniPlayerBar`, both of which the Mac
/// target excludes.
///
/// Two axes decide what this screen is. Whether the words came back timed — which
/// `LyricsMatch` refuses to say yes to for a live cut or a remix, so `.plain` is a normal
/// answer and not a failure — and whether `track` is the one actually playing. A track that
/// is not playing has no playhead, so there is no cursor to draw, nothing to scroll and
/// nothing a tap could seek: it is text.
struct LyricsView: View {
    let track: Track
    @ObservedObject var player: PlayerService
    /// The session as the transport shows it, which is this device's own or the paired
    /// device's. Read for the same reason `NowPlayingView` reads it for everything on screen:
    /// while the peer owns the session this device's `player.currentTrack` is deliberately
    /// empty, so asking `player` whether this track is playing answers "no" for the song whose
    /// transport controls are an inch below these words. Written to through `player`, which
    /// relays a seek to the owner itself.
    @ObservedObject private var peer = PeerPlayback.shared
    @ObservedObject private var cache = LyricsCacheStore.shared
    @ObservedObject private var network = NetworkMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phase: Phase = .loading

    /// Bumped by "Try Again", and part of the `.task` id so that a retry is a *structured*
    /// child of this view rather than a bare `Task { }`. An unstructured retry outlives the
    /// track it was started for: it is tied neither to the view's lifetime nor to the id, so
    /// nothing cancels it when the song advances and it finishes by writing the previous
    /// track's words into the state now belonging to the next one.
    @State private var retryCount = 0

    /// Whether the scroll is still chasing the song. Starts true and only ever goes false by a
    /// deliberate drag — see `suspendFollowing()`, which is the load-bearing part of this screen.
    @State private var isFollowing = true

    /// True from the moment an auto-scroll is issued until the scroll view goes idle again.
    /// Only used to tell our own momentum apart from the reader's; see the phase handler.
    @State private var autoScrollInFlight = false

    /// What `.task(id:)` restarts on: a different track, or the reader asking again.
    private struct LoadRequest: Equatable {
        let videoId: String
        let attempt: Int
    }

    private enum Phase: Equatable {
        case loading
        case loaded(Lyrics)
        /// Neither host has these words. Distinct from `.failed`: this one is cached, that one
        /// must not be.
        case absent
        case failed(String)
    }

    /// Where the active line settles: a little above the middle, so the lines still to come get
    /// more of the screen than the ones already sung. Dead centre wastes the lower half on text
    /// nobody is going to look at again.
    private static let activeLineAnchor = UnitPoint(x: 0, y: 0.35)

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // None of these three is a scroll view, so none of them is covered by the
                    // clearance on the content inside `synced` and `untimed`. Centred in a
                    // panel that runs to the window's bottom edge, a spinner or a placeholder
                    // sits half the transport bar's height too low, with its description text
                    // the part that goes under — which is the exact reason `MacLyricsPanel`
                    // clears its own "Nothing Playing" branch.
                    .transportClearance()
            case .failed(let message):
                ErrorRow(message: message) { retryCount += 1 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transportClearance()
            case .absent:
                ContentUnavailableView(
                    "No Lyrics",
                    systemImage: "text.quote",
                    description: Text("Nobody has written these words down yet. This is checked again from time to time.")
                )
                .transportClearance()
            case .loaded(let lyrics):
                content(lyrics)
            }
        }
        .background(Theme.background)
        .task(id: LoadRequest(videoId: track.videoId, attempt: retryCount)) { await load() }
        // A download fetches lyrics of its own after the audio lands, and the store is
        // `@Published` for exactly this: a screen sitting on "No Lyrics" while the words arrive
        // behind it would stay wrong until it was closed and reopened.
        .onChange(of: cache.lyrics(for: track.videoId)) { _, found in
            if let found { phase = .loaded(found) }
        }
        // This track becoming the playing one is a track change as far as this screen is
        // concerned: there was no cursor a moment ago and now there is, so following starts
        // fresh rather than inheriting a suspension from a scroll made while it was static.
        .onChange(of: isLive) { _, live in
            if live { isFollowing = true }
        }
    }

    // MARK: - What is on screen

    /// Whether these are the words to the song the transport is driving — not whether *this*
    /// device is the one making the sound. A phone mirroring a paired Mac has no local track at
    /// all, and asking `player` gave "no cursor, and here is a note telling you to play the
    /// song" over a song that was already playing.
    private var isLive: Bool { peer.displayedTrack?.id == track.id }

    private var syncedLines: [LyricsLine]? {
        guard case .loaded(let lyrics) = phase, case .synced(let lines) = lyrics.body else { return nil }
        return lines
    }

    /// `nil` whenever there is nothing to highlight — untimed words, a track that is not
    /// playing, or a playhead sitting before the first line.
    private var activeIndex: Int? {
        guard isLive, let lines = syncedLines else { return nil }
        // The owner's playhead, which is `player.progress` when this device owns the session
        // and the peer's reported position when it does not. The scrubber on `NowPlayingView`
        // already reads it from here for the same reason.
        return LyricsCursor.activeIndex(in: lines, at: peer.displayedProgress)
    }

    @ViewBuilder
    private func content(_ lyrics: Lyrics) -> some View {
        switch lyrics.body {
        case .synced(let lines) where isLive:
            synced(lines, of: lyrics)
        case .synced(let lines):
            // Timed words, no playhead to time them against. Rendered as text, and said so —
            // otherwise this looks identical to a track whose lyrics simply have no timings,
            // with no explanation for why nothing lights up.
            untimed(lines.map(\.text), of: lyrics, note: "Play this song to follow along.")
        case .plain(let lines):
            untimed(lines, of: lyrics, note: nil)
        }
    }

    // MARK: - Timed

    private func synced(_ lines: [LyricsLine], of lyrics: Lyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A plain `VStack`, not a `LazyVStack`: "Jump to current" can be a hop of fifty
                // lines, and a proxy can only scroll to an id that has been laid out.
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    attribution(lyrics)

                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Button {
                            player.seek(to: line.at)
                        } label: {
                            lineText(line.text, active: index == activeIndex)
                        }
                        .buttonStyle(.pressableRow)
                        .id(index)
                    }
                }
                .padding(.horizontal, Theme.Metrics.gutter)
                .padding(.vertical, Theme.Space.xl)
                // On the content, never on the `ScrollView` — padding the container moves the
                // viewport and leaves the last line scrolling under the Mac transport bar
                // exactly as before.
                .transportClearance()
            }
            .onScrollPhaseChange { _, newPhase in
                switch newPhase {
                case .interacting:
                    // A drag, and the only unambiguous "a human is moving this" signal there is.
                    //
                    // Deliberately NOT `.tracking`. That phase means a finger has landed and may
                    // or may not go on to drag — which is also what tapping a line to seek looks
                    // like. Suspending there would break following on a tap, silently, and the
                    // reader would have no idea why the words stopped moving.
                    suspendFollowing()
                case .decelerating:
                    // Momentum after a drag. Belt and braces for input that never reports
                    // `.interacting` (a mouse wheel has nothing to touch), but skipped while one
                    // of our own scrolls is still settling, so the screen cannot suspend itself.
                    if !autoScrollInFlight { suspendFollowing() }
                case .idle:
                    autoScrollInFlight = false
                default:
                    break
                }
            }
            .onChange(of: activeIndex) { _, index in
                follow(to: index, proxy: proxy, animated: true)
            }
            .onAppear {
                // Opened mid-song: land on the current line rather than at the first verse, and
                // without an animation, which would read as the screen scrolling on its own the
                // instant it appeared.
                follow(to: activeIndex, proxy: proxy, animated: false)
            }
            .overlay(alignment: .top) {
                if !isFollowing {
                    jumpToCurrent(proxy: proxy)
                }
            }
            .animation(.easeOut(duration: 0.2), value: isFollowing)
        }
    }

    /// Following stops here and resumes in exactly two places: this control, and the track
    /// changing. It never resumes on a timer, on the next line, or when the active line happens
    /// to scroll back into view — a screen that yanks itself away mid-verse is worse than one
    /// that never scrolled at all, and worse still because it does it under your thumb while you
    /// are reading.
    private func suspendFollowing() {
        guard isFollowing else { return }
        isFollowing = false
    }

    private func follow(to index: Int?, proxy: ScrollViewProxy, animated: Bool) {
        guard isFollowing, let index else { return }
        autoScrollInFlight = true
        if animated && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(index, anchor: Self.activeLineAnchor)
            }
        } else {
            proxy.scrollTo(index, anchor: Self.activeLineAnchor)
            // Nothing to settle, so nothing will report idle on our behalf.
            autoScrollInFlight = false
        }
    }

    /// Pinned to the top, not the bottom. Both platforms already keep something at the foot of
    /// the screen — the Mac transport bar, the phone's tab-bar accessory — and this project has
    /// a history of floating controls quietly landing underneath one of them.
    private func jumpToCurrent(proxy: ScrollViewProxy) -> some View {
        Button {
            isFollowing = true
            follow(to: activeIndex, proxy: proxy, animated: true)
        } label: {
            Label("Jump to current", systemImage: "location.fill")
                .font(.controlLabel)
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, Theme.Space.sm)
                .background(Theme.cardLight, in: Capsule())
        }
        .buttonStyle(.pressable)
        .padding(.top, Theme.Space.md)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Untimed, or not playing

    private func untimed(_ lines: [String], of lyrics: Lyrics, note: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                attribution(lyrics)

                if let note {
                    Text(note)
                        .font(.meta)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    lineText(line, active: nil)
                }
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.vertical, Theme.Space.xl)
            .transportClearance()
        }
    }

    // MARK: - Pieces

    /// `active: nil` means there is no cursor at all, which is not the same as "some other line
    /// is current" — every line reads at full strength rather than the whole screen being dimmed.
    private func lineText(_ text: String, active: Bool?) -> some View {
        // An empty line is a real instrumental gap the parser was careful to keep, so it gets
        // its height rather than collapsing the verses together.
        Text(text.isEmpty ? " " : text)
            .font(.rowTitle)
            // Weight rather than a font of its own: `Theme`'s type roles are the one place a
            // font may be composed, and there is no lyric role there yet.
            .fontWeight(active == true ? .semibold : .regular)
            .foregroundStyle(active == false ? Color.secondary : Color.primary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    /// Where the words came from, above them rather than at the foot: "shown, not hidden" is
    /// the point of the field, and a footer under two hundred lines is hidden by any ordinary
    /// meaning of the word.
    ///
    /// It doubles as the note that the timing was not trusted. `LyricsClient` writes that into
    /// the attribution because it is the only field of `Lyrics` that reaches a screen, so the
    /// difference between "this source had no timings" and "we declined to scroll the timings it
    /// had" is one string comparison rather than a second flag threaded through the model. A
    /// cache entry written by a build with different wording just reads as ordinary attribution.
    @ViewBuilder
    private func attribution(_ lyrics: Lyrics) -> some View {
        if let attribution = lyrics.attribution {
            if attribution == LyricsClient.untrustedTimingAttribution {
                Label(attribution, systemImage: "exclamationmark.triangle.fill")
                    .font(.meta)
                    .foregroundStyle(Theme.warning)
            } else {
                Text(attribution)
                    .font(.meta)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        // Reached again when `track` changes under a reused view identity, which is the other
        // half of "changing track resumes following". A retry lands here too, where there is
        // nothing being followed anyway.
        isFollowing = true
        autoScrollInFlight = false

        if let cached = cache.lyrics(for: track.videoId) {
            phase = .loaded(cached)
            return
        }

        // A recorded miss is an answer, and re-asking two hosts on every open of an instrumental
        // is exactly what the store exists to stop. It expires on its own, so this is not a
        // permanent "no".
        if cache.isMissFresh(track.videoId) {
            phase = .absent
            return
        }

        phase = .loading
        do {
            let found = try await LyricsClient.lyrics(for: track)
            // `phase` is `@State`, and this view's identity is reused across track changes —
            // `MacLyricsPanel` and `NowPlayingView` both rebuild it from `peer.displayedTrack`
            // with no `.id(...)`. So the box being written to here may already belong to the
            // next song, and a response that lands in the moment between the song advancing
            // and the cancellation arriving would put the previous track's words on screen and
            // leave them there: the next track's own load has already finished.
            //
            // What was learned is still worth keeping, so the cache write happens either way —
            // it is keyed by the videoId this ran for and cannot land on the wrong track.
            guard !Task.isCancelled else {
                if let found { cache.store(found, for: track.videoId) }
                return
            }
            if let found {
                cache.store(found, for: track.videoId)
                phase = .loaded(found)
            } else {
                cache.storeMiss(for: track.videoId)
                phase = .absent
            }
        } catch is CancellationError {
            // The screen went away mid-request. Writing anything now would either cache a
            // non-answer or set state on a view that no longer exists.
        } catch {
            // Same reasoning as the success path: a failure that belongs to a track this screen
            // has already moved on from must not caption the one now on it.
            guard !Task.isCancelled else { return }
            // Deliberately not a miss. "The host was unreachable" and "nobody has typed these
            // up" are different facts, and caching the first as the second would hold a week's
            // worth of silence over a track whose lyrics were there all along.
            phase = .failed(
                network.isConnected
                    ? "Couldn't load the lyrics. Try again in a moment."
                    : "You're offline, so the lyrics couldn't be fetched."
            )
        }
    }
}
