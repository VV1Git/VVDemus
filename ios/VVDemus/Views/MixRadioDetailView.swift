import SwiftUI

/// A named radio of several songs: the picked songs first, then songs like the set of them,
/// steered away from songs like the ones removed from it. The single-seed counterpart is
/// `RadioDetailView`; see `MixRadioBlend` for the difference.
struct MixRadioDetailView: View {
    let mixId: UUID
    @ObservedObject var player: PlayerService
    @ObservedObject private var mixes = MixRadioStore.shared
    /// The station's songs live in the store rather than in this view, so they are kept across
    /// launches and are the same on every linked device — see `MixStationStore`.
    @ObservedObject private var stations = MixStationStore.shared
    @ObservedObject private var builder = MixStationBuilder.shared
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var sortOption: MixSortOption = .order
    @State private var isRefreshing = false
    @State private var showRename = false
    @State private var newName = ""
    @State private var confirmDelete = false

    private var mix: MixRadio? { mixes.mix(mixId) }
    private var station: MixStationStore.Station? { stations.station(for: mixId) }

    /// The station, less anything removed since it was built — so a removal leaves the list
    /// at once, rather than when the rebuild that steers away from it lands.
    private var tracks: [Track] {
        guard let station else { return [] }
        let removed = Set((mix?.removed ?? []).map(\.videoId))
        return station.tracks.filter { !removed.contains($0.videoId) }
    }

    private var title: String { mix?.name ?? "Mix Radio" }

    private var subtitle: String {
        let names = (mix?.seeds ?? []).map(\.title)
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

    var body: some View {
        Group {
            if mix == nil {
                ContentUnavailableView(
                    "Mix Deleted",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("This mix radio was deleted.")
                )
            } else if mix?.seeds.isEmpty == true {
                ContentUnavailableView(
                    "No Picks",
                    systemImage: "plus.square.on.square",
                    description: Text("Add songs from any song\u{2019}s menu with Add to Mix Radio.")
                )
            } else if station == nil {
                if let errorMessage {
                    ErrorRow(message: errorMessage) { Task { await ensureStation(force: true) } }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                trackList
            }
        }
        .background(Theme.screenBackground)
        .navigationTitle(title)
        .compactNavigationTitle()
        .toolbar {
            if mix != nil {
                ToolbarItem(placement: .trailingActions) {
                    Menu {
                        MixSortPicker(selection: $sortOption)
                        Section {
                            Button {
                                Task { await refresh() }
                            } label: {
                                Label(isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                            }
                            .disabled(isRefreshing || builder.building.contains(mixId))
                            Button {
                                newName = mix?.name ?? ""
                                showRename = true
                            } label: {
                                Label("Rename…", systemImage: "pencil")
                            }
                        }
                        Section {
                            Button(role: .destructive) {
                                confirmDelete = true
                            } label: {
                                Label("Delete Mix", systemImage: "trash")
                            }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
        }
        .alert("Rename Mix", isPresented: $showRename) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { mixes.rename(mixId, to: newName) }
        }
        .confirmationDialog("Delete \u{201C}\(title)\u{201D}?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Mix", role: .destructive) {
                mixes.delete(mixId)
                dismiss()
            }
        }
        // Keyed on what the station is built from, so every edit — here, from a song's menu
        // anywhere, or arriving from another device — brings the station up to date.
        .task(id: mix?.signature) { await ensureStation() }
    }

    private var trackList: some View {
        List {
            MixDetailHeader(
                title: title,
                subtitle: subtitle,
                imageURL: mix?.seeds.first?.thumbnailUrl,
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
                    .trackActions(track: track, player: player) {
                        // A pick and a suggested song alike: gone, and the station steers away
                        // from songs like it. Adding it back as a pick undoes that.
                        Button(role: .destructive) {
                            withAnimation { mixes.remove(track, from: mixId) }
                        } label: {
                            Label("Remove from Mix", systemImage: "hand.thumbsdown")
                        }
                    }
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

    /// Builds the station if the one kept is not for the mix as it stands.
    ///
    /// An edit made on another device is left to that device for a while: it builds as soon as
    /// it edits, and its station arrives with the edit. Building here as well would make a
    /// second, different station, and the newer of the two would replace the older on every
    /// device — the list changing once, under you, for no reason you could see.
    private func ensureStation(force: Bool = false) async {
        guard let mix, !mix.seeds.isEmpty, station?.signature != mix.signature else { return }
        if !force, !builder.shouldBuildHere(mix) {
            let wait = MixStationBuilder.peerGrace - Date().timeIntervalSince(mix.stamp.editedAt)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, station?.signature != mix.signature else { return }
        }
        errorMessage = nil
        do {
            try await builder.build(mixId)
        } catch {
            errorMessage = "Couldn't load this radio. Check your connection."
        }
    }

    /// New songs for the same picks, with what was showing pushed to the back.
    private func refresh() async {
        isRefreshing = true
        errorMessage = nil
        do {
            try await builder.refresh(mixId)
        } catch MixStationBuilder.Failure.noNewSongs {
            errorMessage = "No new songs for this radio right now. Try again later."
        } catch {
            errorMessage = "Couldn't refresh this radio. Check your connection."
        }
        isRefreshing = false
    }
}
