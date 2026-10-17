import SwiftUI

/// A radio of several songs: the picked songs first, then songs like the set of them.
/// The single-seed counterpart is `RadioDetailView`; see `MixRadioBlend` for the difference.
struct MixRadioDetailView: View {
    let radio: MixRadio
    @ObservedObject var player: PlayerService
    @ObservedObject private var tray = MixRadioSeedsStore.shared
    /// The station's songs live here rather than in this view, exactly as a single-seed
    /// radio's do. They used to sit in an in-memory dictionary, so the station was rebuilt on
    /// every launch and on each device separately — and YouTube answers differently every
    /// time, so it changed constantly and never matched between the phone and the Mac.
    @ObservedObject private var radioCache = RadioCacheStore.shared
    private var tracks: [Track] { radioCache.tracks(for: radio.cacheKey) ?? [] }
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var sortOption: MixSortOption = .order
    @State private var isRefreshing = false

    private var title: String { radio.title }

    private var subtitle: String {
        let names = radio.seeds.map(\.title)
        switch names.count {
        case 0: return ""
        case 1: return "From \(names[0])"
        case 2, 3: return "From \(names.dropLast().joined(separator: ", ")) and \(names.last!)"
        default: return "From \(names.prefix(2).joined(separator: ", ")) and \(names.count - 2) more"
        }
    }

    private var visibleTracks: [Track] {
        sortOption.apply(to: filterTracks(tracks, matching: searchText))
    }

    /// Sorted but not filtered, as on `RadioDetailView` — see the note on its own.
    private var playbackContext: [Track] {
        sortOption.apply(to: tracks)
    }

    /// Whether this screen is showing the songs currently in the tray. A station opened before
    /// the tray changed is a snapshot of the older pick, and clearing the tray from it would
    /// clear a pick the screen is not about.
    private var isCurrentPick: Bool { tray.seeds == radio.seeds }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, tracks.isEmpty {
                ErrorRow(message: errorMessage) { Task { await load() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                ContentUnavailableView(
                    "No Songs",
                    systemImage: "music.note.list",
                    description: Text("This radio came back empty. Refresh to build it again.")
                )
            } else {
                trackList
            }
        }
        .background(Theme.screenBackground)
        .navigationTitle(title)
        .compactNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .trailingActions) {
                Menu {
                    MixSortPicker(selection: $sortOption)
                    Section {
                        Button {
                            Task { await refresh() }
                        } label: {
                            Label(isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(isRefreshing)
                    }
                    if isCurrentPick {
                        Section {
                            Button(role: .destructive) {
                                tray.clear()
                            } label: {
                                Label("Clear Picked Songs", systemImage: "xmark.circle")
                            }
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        // Keyed on the picks, so a screen kept on through a change of them — the Mac's sidebar
        // row follows the picks rather than being rebuilt — loads the new station.
        .task(id: radio.id) { await load() }
    }

    private var trackList: some View {
        List {
            MixDetailHeader(
                title: title,
                subtitle: subtitle,
                imageURL: radio.seeds.first?.thumbnailUrl,
                trackCount: tracks.count,
                totalDuration: totalDuration(of: tracks),
                tracks: tracks,
                onPlay: { playAll(shuffled: false) },
                onShuffle: { playAll(shuffled: true) }
            )
            .mixHeaderRowMetrics()

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
                    .listRowInsets(Theme.Metrics.rowInsets)
                    .listRowSeparator(.hidden)
                    .contentShape(Rectangle())
                    .onTapGesture { self.errorMessage = nil }
                    .accessibilityHint("Tap to dismiss")
            }

            if visibleTracks.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(visibleTracks) { track in
                    TrackRow(track: track, isActive: player.currentTrack?.id == track.id) {
                        play(from: track, in: playbackContext)
                    }
                    .trackRowMetrics()
                    .trackActions(track: track, player: player)
                }
            }

            TransportClearanceRow()
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Find on this page")
    }

    private func playAll(shuffled: Bool) {
        guard !tracks.isEmpty else { return }
        let ordered = shuffled ? tracks.shuffled() : playbackContext
        play(from: ordered[0], in: ordered)
    }

    /// No `contextSeed`. That records a single-seed station in the radio history, and this
    /// one has no single seed: recording the first pick would put a "<first song> Radio"
    /// shortcut on Home that opens a different station from the one that was played.
    private func play(from track: Track, in context: [Track]) {
        player.play(track: track, context: context, contextTitle: title)
    }

    private func load() async {
        errorMessage = nil
        // Built once, here or on the paired device, and kept until Refresh.
        guard tracks.isEmpty else {
            isLoading = false
            return
        }
        isLoading = true
        do {
            let built = try await MixRadioService.build(seeds: radio.seeds)
            // A station that arrived from the paired device while this one was being built
            // wins: replacing it would put the two devices on different lists again.
            if tracks.isEmpty, !built.isEmpty { keep(built) }
        } catch {
            errorMessage = "Couldn't load this radio. Check your connection."
        }
        isLoading = false
    }

    /// Saves the station and tells the paired device straight away. Storing a station is not
    /// itself a library change, so without the nudge the other device would only hear of it
    /// at the next sync — and, opening the station before then, build a different one.
    private func keep(_ built: [Track]) {
        RadioCacheStore.shared.store(built, for: radio.cacheKey)
        PeerLink.shared.libraryDidChange()
    }

    /// Rebuilds the station with what it showed pushed to the back, so Refresh brings new
    /// songs forward rather than reshuffling the same ones. The picked songs stay on top.
    private func refresh() async {
        isRefreshing = true
        errorMessage = nil
        let seedIds = Set(radio.seeds.map(\.videoId))
        let shown = Set(tracks.map(\.videoId)).subtracting(seedIds)
        do {
            let built = try await MixRadioService.build(seeds: radio.seeds, avoiding: shown)
            if built.isEmpty {
                errorMessage = "No new songs for this radio right now. Try again later."
            } else {
                keep(built)
            }
        } catch {
            errorMessage = "Couldn't refresh this radio. Check your connection."
        }
        isRefreshing = false
    }
}
