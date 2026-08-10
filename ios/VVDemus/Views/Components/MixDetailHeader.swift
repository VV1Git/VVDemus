import SwiftUI

/// Hero section for a radio/playlist/daylist detail screen: artwork, title, byline,
/// song/duration stats, and a Play / Shuffle / Download-all action row.
///
/// Applies **no horizontal padding of its own** — every detail screen sets
/// `.listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 16, trailing: 16))` on the header
/// row, so the hero and the track rows below it share one leading edge.
struct MixDetailHeader: View {
    let title: String
    let subtitle: String
    // No `badge`: the collection kind belongs in `subtitle`. A Radio's title already ends
    // in " Radio", so the old artwork badge printed the word twice.
    let imageURL: String?
    let trackCount: Int
    let totalDuration: TimeInterval
    let tracks: [Track]
    let onPlay: () -> Void
    let onShuffle: () -> Void

    @ObservedObject private var downloads = DownloadManager.shared
    /// Still observed although the body reads `peer` for state: `displayed*` is computed and
    /// subscribes to nothing, so without this the button would miss a local play/pause.
    @ObservedObject private var player = PlayerService.shared
    @ObservedObject private var peer = PeerPlayback.shared
    @State private var showCancelConfirm = false

    /// True when the thing this header describes is the thing currently coming out of the
    /// speaker — on whichever device that is. Tapping Play and having the button go on saying
    /// "Play" gave no acknowledgement at all that anything had happened.
    ///
    /// Asked of the local player, that was exactly what a mirroring device did: its own player is
    /// empty, so the button was stuck on "Play" and the next tap took the wrong branch, restarting
    /// the collection from track one instead of pausing the device that was playing it.
    private var isPlayingThisCollection: Bool {
        guard peer.displayedIsPlaying, let current = peer.displayedTrack else { return false }
        return tracks.contains { $0.id == current.id }
    }

    /// One O(n) pass instead of the three separate `tracks.filter`/`tracks.contains` scans this
    /// replaced — the body re-evaluates on every progress publish, and each of those scans was
    /// walking the whole collection to answer a question the manager already tracks.
    private var aggregate: CollectionDownloadProgress { downloads.collectionProgress(for: tracks) }

    var body: some View {
        // Two different questions, deliberately kept apart. `collection` is "how much of this is
        // on disk", which is what the checkmark and VoiceOver answer. `job` is "what did Download
        // All start", which is what the bar and the Stop control *are* — and it is nil while the
        // only downloads running are rows the user tapped one at a time.
        //
        // Both resolved once and threaded through, including into the `isComplete` the button
        // reads: each is O(tracks.count), and this body re-evaluates on every progress publish.
        let collection = aggregate
        let job = downloads.downloadJob(for: tracks)
        return VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HeroArtwork(url: imageURL)

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title)
                    .font(.heroTitle)
                    .lineLimit(2)
                    // A radio title is "<song> Radio" and used to run three or four lines.
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.rowSubtitle)
                        .foregroundStyle(.secondary)
                }
                Text(statsLine)
                    .font(.meta)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Theme.Space.md) {
                Button {
                    // Already playing this collection: the button is a pause control, not a
                    // "start over" control — restarting from track one is the last thing a
                    // second tap should do.
                    if isPlayingThisCollection {
                        player.togglePlayPause()
                    } else {
                        onPlay()
                    }
                } label: {
                    Label(
                        isPlayingThisCollection ? "Pause" : "Play",
                        systemImage: isPlayingThisCollection ? "pause.fill" : "play.fill"
                    )
                    // Explicit, because a prominent button colours its title and its symbol
                    // differently: the title came out white but the glyph took the accent
                    // tint, leaving a green play icon inside a green button.
                    .foregroundStyle(.white)
                    // Without a stable identity the label cross-dissolves its whole frame and
                    // the capsule visibly resizes between "Play" and "Pause".
                    .contentTransition(.identity)
                }
                .buttonStyle(.borderedProminent)
                .animation(.snappy, value: isPlayingThisCollection)
                .accessibilityLabel(isPlayingThisCollection ? "Pause" : "Play")

                Button(action: onShuffle) {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.bordered)

                Spacer()

                downloadAllButton(collection: collection, job: job)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .tint(Theme.accent)

            // Deliberately *under* the button row rather than inside it: threading a progress
            // bar through a row of capsules either squashes them or shoves them sideways.
            // Sitting below, the bar reads as the status of the thing that was just tapped.
            // Zero height when idle — no reserved gap.
            //
            // Driven by `job`, never by the collection aggregate. A single-tap download is
            // described by its own row's ring, and raising a collection-wide bar for one is
            // both the wrong scale and the wrong scope.
            if let job, job.progress.isActive || job.progress.hasFailures {
                CollectionDownloadStrip(
                    progress: job.progress,
                    onStop: { showCancelConfirm = true },
                    onRetry: job.progress.hasFailures ? { downloads.retryFailed(in: job.videoIds) } : nil,
                    // Without this a permanently failed track kept the strip — and the hero's
                    // orange retry button — on the screen for the rest of the session.
                    onDismiss: job.progress.hasFailures ? { downloads.dismissFailed(in: job.videoIds) } : nil
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, Theme.Space.md)
        // Value-scoped, so the strip's own four-times-a-second fraction updates never animate
        // the hero — only its appearance and disappearance do.
        .animation(.snappy(duration: 0.28), value: job?.progress.isActive ?? false)
        .confirmationDialog("Stop downloading \(title)?", isPresented: $showCancelConfirm, titleVisibility: .visible) {
            // A forty-track batch is too expensive to lose to a mis-tap, and the cancel control
            // occupies exactly the spot the user tapped to start it. Scoped to the job, so a
            // song the user is separately downloading from a row is not collateral.
            if let job {
                Button("Stop \(job.progress.active) Downloads", role: .destructive) {
                    downloads.cancelAll(videoIds: job.videoIds)
                }
            }
            Button("Keep Downloading", role: .cancel) {}
        }
    }

    /// Stop / retry / download, in that order of precedence — but only ever for a *job*. With
    /// this driven by the collection aggregate, tapping download on one row turned this into a
    /// Stop control for the entire playlist.
    @ViewBuilder
    private func downloadAllButton(
        collection: CollectionDownloadProgress,
        job: CollectionDownloadJob?
    ) -> some View {
        let progress = job?.progress
        let isFullyDownloaded = collection.isComplete
        Button {
            if progress?.isActive == true {
                showCancelConfirm = true
            } else if let job, job.progress.hasFailures {
                downloads.retryFailed(in: job.videoIds)
            } else {
                downloads.downloadAll(tracks, title: title, artworkURL: imageURL)
            }
        } label: {
            ZStack {
                if let progress, progress.isActive {
                    // The ring is a pure function of the aggregate fraction, so it is fed a
                    // synthetic byte pair rather than any one track's real counters.
                    DownloadRing(
                        state: .transferring(received: Int64(progress.fraction * 10_000), expected: 10_000),
                        diameter: DownloadProgressStyle.headerRingDiameter,
                        showsCenterGlyph: false,
                        tint: progress.isRateLimited(at: .now) ? Theme.warning : Theme.accent
                    )
                } else if isFullyDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                } else if progress?.hasFailures == true {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.title3)
                        .foregroundStyle(Theme.warning)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(.primary)
                }
            }
            // Fixed box in every state: `arrow.down.circle` at `.title3` and a 24pt ring have
            // different intrinsic sizes, and the capsules beside it would shift each time a
            // download started or finished. 32pt of drawing, 44pt of touch.
            .frame(width: Theme.Metrics.trailingControl, height: Theme.Metrics.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        // No longer disabled while downloading — that state is now the cancel control.
        // `PressableButtonStyle` dims a disabled label, so the finished checkmark no longer
        // draws at full strength while doing nothing.
        .disabled(tracks.isEmpty || isFullyDownloaded)
        .accessibilityLabel(downloadAllLabel(progress, isFullyDownloaded: isFullyDownloaded))
        .accessibilityValue(downloadAllValue(progress ?? collection))
    }

    private func downloadAllLabel(_ progress: CollectionDownloadProgress?, isFullyDownloaded: Bool) -> String {
        if progress?.isActive == true { return "Stop downloading \(title)" }
        if isFullyDownloaded { return "Downloaded" }
        if progress?.hasFailures == true { return "Retry failed downloads" }
        return "Download all"
    }

    /// Spoken against the job while one is running, so it agrees with the strip beneath it, and
    /// against the collection otherwise — which is what an idle Download All button is about.
    private func downloadAllValue(_ progress: CollectionDownloadProgress) -> String {
        guard progress.total > 0 else { return "" }
        if progress.isActive {
            return "\(progress.completed) of \(progress.total) downloaded, \(progress.fraction.formatted(.percent.precision(.fractionLength(0))))"
        }
        if progress.hasFailures {
            return "\(progress.completed) of \(progress.total) downloaded, \(progress.failed) failed"
        }
        return "\(progress.completed) of \(progress.total) downloaded"
    }

    private var statsLine: String {
        let songs = trackCount == 1 ? "1 song" : "\(trackCount) songs"
        guard totalDuration > 0 else { return songs }
        let hours = Int(totalDuration) / 3600
        let minutes = (Int(totalDuration) % 3600) / 60
        let durationText = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
        return "\(songs) • \(durationText)"
    }
}

/// Centred hero artwork sized to the row it lands in: 62% of the available width, capped at
/// `Theme.ArtSize.heroMax`. A fixed 260pt was 81% of an SE and 60% of a Pro Max.
///
/// The width is measured rather than expressed with `containerRelativeFrame` because
/// `RemoteImage` takes its side length as a value — it drives the clip radius *and* the pixel
/// size actually requested, so a modifier that only resizes the box would fetch the wrong
/// bitmap. Measuring is loop-free: the reported width comes from the parent and never depends
/// on `side`.
private struct HeroArtwork: View {
    let url: String?
    @State private var side: CGFloat = Theme.ArtSize.heroMax

    var body: some View {
        Color.clear
            .frame(height: side)
            .overlay {
                RemoteImage(url: url, size: side, cornerRadius: Theme.Radius.artHero)
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                guard width > 0 else { return }
                side = min(width * 0.62, Theme.ArtSize.heroMax)
            }
    }
}
