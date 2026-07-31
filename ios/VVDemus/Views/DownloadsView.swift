import SwiftUI

struct DownloadsView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var isSelecting = false
    @State private var selectedIDs = Set<String>()
    @State private var batchToStop: DownloadBatch?

    private var allSelected: Bool {
        !downloads.downloadedTracks.isEmpty && selectedIDs.count == downloads.downloadedTracks.count
    }

    /// Batches whose members are all finished are pruned by the manager, but a card can outlive
    /// its last live member by one publish — filtering on the aggregate keeps an empty card from
    /// flashing. Resolved once and threaded through: `collectionProgress` is O(members), and
    /// three separate call sites were each paying for it.
    private var batchCards: [BatchCard] {
        downloads.batches.compactMap { batch in
            let progress = downloads.collectionProgress(forVideoIds: batch.videoIds)
            guard progress.isActive || progress.hasFailures else { return nil }
            return BatchCard(batch: batch, progress: progress)
        }
    }

    /// Single-tap downloads: they belong to no batch, so a card would be a heavier answer than
    /// the row itself.
    private var looseEntries: [DownloadEntry] {
        downloads.activeEntries.filter { $0.batchId == nil }
    }

    /// The title doubles as the selection counter while selecting, so the count doesn't need a
    /// bar of its own.
    private var title: LocalizedStringKey {
        guard isSelecting else { return "Downloads" }
        return selectedIDs.isEmpty
            ? "Select Items"
            : "^[\(selectedIDs.count) Item](inflect: true) Selected"
    }

    var body: some View {
        let cards = batchCards
        let loose = looseEntries
        // Split by whether anything is actually still happening. A finished-but-failed download
        // filed under "In Progress" was a flat lie — nothing was in progress and nothing ever
        // would be — and it was the header the user had to read to work out why the row would
        // not go away.
        let liveCards = cards.filter { $0.progress.isActive }
        let failedCards = cards.filter { !$0.progress.isActive && $0.progress.hasFailures }
        let liveEntries = loose.filter { !$0.state.isFailed }
        let failedEntries = loose.filter { $0.state.isFailed }

        return Group {
            // Was `downloadedTracks.isEmpty` alone: starting a forty-track download and opening
            // this tab showed "nothing here yet" over forty running transfers.
            if downloads.downloadedTracks.isEmpty && downloads.activeEntries.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Downloaded songs play without using data.")
                )
            } else {
                List {
                    section("Downloading", cards: liveCards, entries: liveEntries)
                    section("Couldn't Download", cards: failedCards, entries: failedEntries)
                    downloadedSection(hasOtherSections: !cards.isEmpty || !loose.isEmpty)
                }
                .listStyle(.plain)
            }
        }
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Select mode addresses `downloadedTracks` only, so it stays gated on that list
            // rather than on whether the screen has any content at all.
            if !downloads.downloadedTracks.isEmpty {
                // Select All and Delete live in the nav bar, not `.bottomBar`: the bottom bar
                // sits under the mini-player accessory and the minimizing tab bar.
                if isSelecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(allSelected ? "Deselect All" : "Select All") {
                            withAnimation(.snappy) {
                                selectedIDs = allSelected ? [] : Set(downloads.downloadedTracks.map(\.id))
                            }
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isSelecting {
                        Button(role: .destructive) {
                            deleteSelected()
                        } label: {
                            Text(selectedIDs.isEmpty ? "Delete" : "Delete (\(selectedIDs.count))")
                        }
                        .disabled(selectedIDs.isEmpty)
                    }
                    Button(isSelecting ? "Done" : "Select") {
                        withAnimation(.snappy) {
                            isSelecting.toggle()
                            if !isSelecting { selectedIDs.removeAll() }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            batchToStop.map { "Stop downloading \($0.title)?" } ?? "Stop downloading?",
            isPresented: Binding(get: { batchToStop != nil }, set: { if !$0 { batchToStop = nil } }),
            titleVisibility: .visible
        ) {
            if let batch = batchToStop {
                let remaining = downloads.collectionProgress(forVideoIds: batch.videoIds).active
                Button("Stop \(remaining) Downloads", role: .destructive) {
                    downloads.cancelBatch(batch.id)
                    batchToStop = nil
                }
            }
            Button("Keep Downloading", role: .cancel) { batchToStop = nil }
        }
    }

    @ViewBuilder
    private func section(_ title: String, cards: [BatchCard], entries: [DownloadEntry]) -> some View {
        if !cards.isEmpty || !entries.isEmpty {
            Section(title) {
                ForEach(cards) { card in
                    DownloadBatchCard(
                        batch: card.batch,
                        progress: card.progress,
                        onStop: { batchToStop = card.batch },
                        onRetry: card.progress.hasFailures
                            ? { downloads.retryFailed(in: card.batch.videoIds) }
                            : nil,
                        // A batch that has stopped with permanent losses shows Retry *and*
                        // Dismiss: `onStop` is only rendered while something is still active, so
                        // without this there was no control on the card that could clear it.
                        onDismiss: card.progress.hasFailures
                            ? { downloads.dismissFailed(in: card.batch.videoIds) }
                            : nil
                    )
                    .trackRowMetrics()
                }
                ForEach(entries) { entry in
                    // No tap-to-play and no `.trackActions`: the row's own `DownloadButton`
                    // already carries progress, cancel and retry, and a half-downloaded track
                    // has nothing else worth offering yet.
                    TrackRow(track: entry.track, isActive: player.currentTrack?.id == entry.id)
                        .trackRowMetrics()
                        // The ring retries; this is the other half of the answer. A failure that
                        // will never succeed had no exit at all — no swipe, no menu, no button —
                        // short of relaunching the app.
                        .swipeActions(edge: .trailing) {
                            if entry.state.isFailed {
                                Button(role: .destructive) {
                                    Haptics.impact()
                                    downloads.dismissFailed(in: [entry.id])
                                } label: {
                                    Label("Dismiss", systemImage: "xmark")
                                }
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func downloadedSection(hasOtherSections: Bool) -> some View {
        if !downloads.downloadedTracks.isEmpty {
            Section {
                ForEach(downloads.downloadedTracks) { track in
                    downloadedRow(track)
                }
            } header: {
                // Only worth a header once the list is actually split; a lone "Downloaded"
                // label above the only section is noise.
                if hasOtherSections {
                    Text("Downloaded")
                }
            }
        }
    }

    @ViewBuilder
    private func downloadedRow(_ track: Track) -> some View {
        // Select mode owns the tap, so the row stops offering play.
        let playAction: (() -> Void)? = isSelecting
            ? nil
            : { player.play(track: track, context: downloads.downloadedTracks, contextTitle: "Downloads") }

        // Every track here is downloaded by definition, so the row's own download control would
        // be a column of identical inert checkmarks restating the screen's title.
        let row = HStack(spacing: Theme.Space.md) {
            if isSelecting {
                Image(systemName: selectedIDs.contains(track.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedIDs.contains(track.id) ? Theme.accent : .secondary)
            }
            TrackRow(
                track: track,
                isActive: player.currentTrack?.id == track.id,
                showsDownloadControl: false,
                onTap: playAction
            )
            // While selecting, the row's controls must be inert: with the heart still live,
            // tapping it liked the song instead of ticking the row.
            .allowsHitTesting(!isSelecting)
        }
        .trackRowMetrics()

        if isSelecting {
            row
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy) { toggleSelection(track.id) } }
                // The row's own button traits are gone with hit testing, so the whole row
                // has to announce itself as the selection control.
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(selectedIDs.contains(track.id) ? .isSelected : [])
        } else {
            row.trackActions(track: track, player: player)
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func deleteSelected() {
        let tracksToDelete = downloads.downloadedTracks.filter { selectedIDs.contains($0.id) }
        downloads.removeAll(tracksToDelete)
        selectedIDs.removeAll()
        isSelecting = false
    }
}

/// One row for a whole "download this album" action, so a forty-track batch doesn't bury the
/// completed list under forty near-identical rows.
///
/// Private to this screen rather than shared: there is no batch detail push, so it has no second
/// call site to keep in sync.
/// A batch paired with the aggregate it renders, so the split into sections and the rows
/// themselves read the manager once rather than twice each.
private struct BatchCard: Identifiable {
    let batch: DownloadBatch
    let progress: CollectionDownloadProgress
    var id: UUID { batch.id }
}

private struct DownloadBatchCard: View {
    let batch: DownloadBatch
    let progress: CollectionDownloadProgress
    let onStop: () -> Void
    let onRetry: (() -> Void)?
    let onDismiss: (() -> Void)?

    /// A row, not a floating card: it carries no padding of its own, so `trackRowMetrics()`
    /// at the call site gives it the same gutter and 6pt vertical inset as a `TrackRow`.
    var body: some View {
        HStack(spacing: Theme.Space.md) {
            RemoteImage(url: batch.artworkURL, size: Theme.ArtSize.row)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(batch.title)
                    .font(.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                CollectionDownloadStrip(
                    progress: progress,
                    onStop: onStop,
                    onRetry: onRetry,
                    onDismiss: onDismiss
                )
            }
        }
    }
}
