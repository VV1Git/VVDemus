import SwiftUI

/// Shared geometry and timing for every download indicator, so a ring in a track row, the
/// ring in a detail hero and the bar on the Downloads screen visibly belong to one system.
enum DownloadProgressStyle {
    static let ringDiameter: CGFloat = 20
    static let ringLineWidth: CGFloat = 2.5
    static let headerRingDiameter: CGFloat = 24
    static let barHeight: CGFloat = 4
    /// A real 0% arc is invisible, so a just-started transfer looked identical to a queued
    /// one for the first seconds of a large file. A 3% stub is the "it's moving" signal.
    static let minimumTrim: Double = 0.03
    /// Length of the indeterminate arc, as a fraction of the circle.
    static let sweepLength: Double = 0.18
    /// Matches `DownloadManager`'s 250 ms coalescing flush, so the fill glides between
    /// publishes instead of stepping once a quarter second.
    static let fill: Animation = .linear(duration: 0.25)
    static let spinDuration: Double = 1.1
}

/// A ring that actually reflects its value.
///
/// `ProgressView(value:).progressViewStyle(.circular)` discards the value on iOS and draws an
/// indeterminate spinner — the reason a download looked identical at 2% and at 98%. The arc
/// here is a trimmed `Circle`, so the sweep is the fraction.
///
/// The frame is a fixed `diameter × diameter` in every state: this sits inline in list rows
/// and in the detail hero's button strip, and a state change that resized it would shove its
/// neighbours around every time a download started or finished.
struct DownloadRing: View {
    let state: DownloadState
    var diameter: CGFloat = DownloadProgressStyle.ringDiameter
    var lineWidth: CGFloat = DownloadProgressStyle.ringLineWidth
    /// Suppresses the queued dot and the "stop" square. The hero's ring sits beside a status
    /// label that already says what is happening, and a 6pt glyph inside a 24pt ring next to
    /// a 56pt play button is noise. The failure glyph is never suppressed — it is the only
    /// thing distinguishing a failed ring from an empty one.
    var showsCenterGlyph: Bool = true
    /// Overridden to `Theme.warning` while a batch is waiting out a 429, so a paused queue
    /// doesn't read as a healthy one.
    var tint: Color = Theme.accent

    var body: some View {
        ZStack {
            Circle()
                .stroke(state.isFailed ? Theme.warning.opacity(0.5) : Theme.cardLight,
                        lineWidth: lineWidth)
                // `.queued` is dimmer than the rest: nothing is happening to this track yet,
                // and thirty-nine equally bright rings read as thirty-nine live transfers.
                .opacity(state == .queued ? 0.55 : 1)

            arc
            glyph
        }
        .frame(width: diameter, height: diameter)
        // The enclosing control speaks for this; a ring that announced itself would make
        // every row two swipes deep in VoiceOver.
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var arc: some View {
        if let fraction = state.fraction {
            Circle()
                .trim(from: 0, to: max(DownloadProgressStyle.minimumTrim, fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // Starts the sweep at twelve o'clock rather than three.
                .rotationEffect(.degrees(-90))
                .animation(DownloadProgressStyle.fill, value: fraction)
        } else if case .resolving = state {
            IndeterminateSweep(lineWidth: lineWidth, color: .secondary)
        } else if case .transferring = state {
            // Bytes are arriving but the server sent no Content-Length, so there is no honest
            // fraction to draw — ever, for this transfer. Tinted like a live download because
            // it is one; swept because the length is unknowable, not because it is stalled.
            IndeterminateSweep(lineWidth: lineWidth, color: tint)
        }
    }

    /// Every glyph is a fraction of `diameter` rather than a fixed point size, so the 24pt
    /// hero ring and the 20pt row ring stay the same drawing at two scales.
    @ViewBuilder
    private var glyph: some View {
        switch state {
        case .queued where showsCenterGlyph:
            Circle()
                .fill(.secondary)
                .frame(width: diameter * 0.25, height: diameter * 0.25)
        case .transferring where showsCenterGlyph:
            // A "stop" square, because tapping the ring cancels.
            Theme.Radius.rect(diameter * 0.05)
                .fill(.secondary)
                .frame(width: diameter * 0.3, height: diameter * 0.3)
        case .failed:
            Image(systemName: "arrow.clockwise")
                .font(.system(size: diameter * 0.5, weight: .bold))
                .foregroundStyle(Theme.warning)
        default:
            EmptyView()
        }
    }
}

/// The rotating arc used while a length is unknown.
///
/// Split into its own view so the `repeatForever` animation exists only while an
/// indeterminate state is on screen. Left on a permanently-mounted view it would keep a
/// display-link running for every idle row in the list.
private struct IndeterminateSweep: View {
    let lineWidth: CGFloat
    let color: Color

    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .trim(from: 0, to: DownloadProgressStyle.sweepLength)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            // -90 → 270 is one full turn that also parks the arc at twelve o'clock when
            // reduce-motion holds `spinning` visually still.
            .rotationEffect(.degrees(spinning ? 270 : -90))
            .animation(
                reduceMotion
                    ? nil
                    : .linear(duration: DownloadProgressStyle.spinDuration).repeatForever(autoreverses: false),
                value: spinning
            )
            .onAppear { spinning = true }
    }
}

/// The per-track download control: idle affordance, live progress, cancel, and retry, in a
/// 32 × 44pt target — 32pt of row width, a full 44pt of touch.
///
/// Observes `DownloadManager` here rather than in `TrackRow` for the same reason
/// `EqualizerBars` observes `PlayerService` there — a progress publish re-evaluates the body
/// of every visible row, and there is no reason for that to drag the artwork, labels and
/// heart button along with it.
struct DownloadButton: View {
    let track: Track

    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        // `isDownloading` is false for a retained `.failed` entry, so "idle" can only be
        // read off `state(for:)` being nil — never off `!isDownloading`.
        let phase = downloads.state(for: track)
        let isIdle = phase == nil
        let isDone = isIdle && downloads.isDownloaded(track)

        Group {
            if isDone {
                // A statement, not a control — the Apple Music "on device" convention.
                // Drawn outside the Button because a *disabled* button still reads as
                // something you tapped and missed; deleting a download lives in the
                // `.trackActions` menu, as it always has.
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Downloaded")
            } else {
                control(phase: phase, isIdle: isIdle)
            }
        }
        // One type size for the two icons and the ring, so nothing in this slot resizes as
        // a download starts or lands.
        .font(.system(size: DownloadProgressStyle.ringDiameter))
        .frame(width: Theme.Metrics.trailingControl, height: Theme.Metrics.hitTarget)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isDone)
        .animation(.easeOut(duration: 0.18), value: isIdle)
    }

    private func control(phase: DownloadState?, isIdle: Bool) -> some View {
        Button {
            tap(phase)
        } label: {
            ZStack {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .opacity(isIdle ? 1 : 0)

                // A fixed child rather than `if let` + `.transition`: these rows live in a
                // List that recycles cells, and an insertion transition fires again on every
                // scroll-in — rows kept re-playing the progress animation as you scrolled
                // past them. `.queued` is an inert stand-in while hidden; it draws one dimmed
                // circle and starts no animation.
                DownloadRing(state: phase ?? .queued)
                    .opacity(isIdle ? 0 : 1)
            }
            // 32pt of layout width, but the whole 44pt height is live.
            .frame(width: Theme.Metrics.trailingControl, height: Theme.Metrics.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(phase: phase))
        .accessibilityValue(accessibilityValue(phase: phase))
        // Only while there is a number that actually moves — VoiceOver re-announces elements
        // with this trait, and "Preparing" repeated every second is just noise.
        .accessibilityAddTraits(phase?.fraction != nil ? [.updatesFrequently] : [])
    }

    private func tap(_ phase: DownloadState?) {
        guard let phase else {
            // The downloaded state isn't a button at all, so this is only ever the
            // fresh-download tap. Deletion stays in the `.trackActions` menu: a bare tap on a
            // control in a forty-row list is far too cheap for a destructive action.
            downloads.download(track)
            return
        }
        if phase.isFailed {
            // `download(_:)` is the retry path — its guard passes for a `.failed` entry and
            // overwrites it.
            downloads.download(track)
        } else {
            // No confirmation: cancelling one track is a tap away from being undone, and a
            // dialog per row would be worse than the occasional mis-tap. The batch-level
            // cancel, which is expensive to lose, does confirm.
            Haptics.impact()
            downloads.cancel(track)
        }
    }

    /// Only ever asked about the interactive states — "Downloaded" is spoken by the plain
    /// image that replaces this button.
    private func accessibilityLabel(phase: DownloadState?) -> String {
        guard let phase else { return "Download" }
        return phase.isFailed ? "Retry download" : "Cancel download"
    }

    private func accessibilityValue(phase: DownloadState?) -> String {
        guard let phase else { return "" }
        switch phase {
        case .queued: return "Queued"
        case .resolving: return "Preparing"
        case .transferring:
            // nil here means the server sent no Content-Length; "0 percent" would be a lie
            // that never resolves.
            guard let fraction = phase.fraction else { return "Downloading" }
            return fraction.formatted(.percent.precision(.fractionLength(0)))
        case .failed(let reason): return reason
        }
    }
}

#Preview("Ring states") {
    VStack(spacing: 24) {
        ForEach(DownloadRing.previewStates) { item in
            HStack(spacing: 16) {
                DownloadRing(state: item.state)
                DownloadRing(state: item.state, diameter: DownloadProgressStyle.headerRingDiameter,
                             showsCenterGlyph: false)
                Text(item.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        HStack(spacing: 16) {
            DownloadRing(state: .transferring(received: 40, expected: 100), tint: Theme.warning)
            Text("rate-limited tint")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.background)
}

#Preview("Determinate sweep") {
    HStack(spacing: 18) {
        ForEach([0.0, 0.08, 0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
            VStack(spacing: 6) {
                DownloadRing(state: .transferring(received: Int64(fraction * 100), expected: 100))
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.background)
}

private struct RingPreviewCase: Identifiable {
    let label: String
    let state: DownloadState
    var id: String { label }
}

extension DownloadRing {
    /// Every state the ring can be asked to draw, so the preview can't silently miss one.
    fileprivate static let previewStates: [RingPreviewCase] = [
        RingPreviewCase(label: "queued", state: .queued),
        RingPreviewCase(label: "resolving", state: .resolving),
        RingPreviewCase(label: "transferring 35%", state: .transferring(received: 35, expected: 100)),
        RingPreviewCase(label: "transferring, unknown size",
                        state: .transferring(received: 1_200_000, expected: nil)),
        RingPreviewCase(label: "failed", state: .failed(reason: "Couldn't download \"Song\".")),
    ]
}
