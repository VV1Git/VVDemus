import SwiftUI

/// Two-layer bar: solid for tracks already on disk, translucent for bytes still arriving.
///
/// Drawn rather than wrapped around a `ProgressView` so the determinate and indeterminate
/// cases are the same 4pt height — a system bar switching between the two changes its
/// intrinsic size, and everything below it hops. `settled <= fraction` always holds, so the
/// two capsules never cross.
struct DownloadProgressBar: View {
    /// Fraction of the collection actually downloaded. The solid layer.
    let settled: Double
    /// Leading edge including partial transfers and permanent failures. The translucent layer.
    let fraction: Double
    var tint: Color = Theme.accent
    var height: CGFloat = DownloadProgressStyle.barHeight

    /// The first publish after a recycled bar scrolls in would otherwise re-sweep 0 → value,
    /// so every scroll down the Downloads list replayed forty fills. Only changes that happen
    /// while the bar is on screen animate.
    @State private var hasAppeared = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.cardLight)
                Capsule()
                    .fill(tint.opacity(0.45))
                    .frame(width: fillWidth(fraction, in: width))
                Capsule()
                    .fill(tint)
                    .frame(width: fillWidth(settled, in: width))
            }
        }
        .frame(height: height)
        // 0.25s matches the manager's coalescing flush, so consecutive publishes hand off to
        // each other and the fill glides instead of stepping four times a second.
        .animation(hasAppeared ? DownloadProgressStyle.fill : nil, value: fraction)
        .animation(hasAppeared ? DownloadProgressStyle.fill : nil, value: settled)
        .onAppear { hasAppeared = true }
        // The strip's status line already carries the numbers; a second element saying the
        // same thing just doubles the swipes.
        .accessibilityHidden(true)
    }

    /// The bar's equivalent of the ring's `minimumTrim`: 1% of a forty-track batch is a
    /// sub-pixel sliver that draws as nothing, so anything non-zero gets at least one round
    /// capsule end.
    private func fillWidth(_ value: Double, in width: CGFloat) -> CGFloat {
        let fraction = clamped(value)
        guard fraction > 0 else { return 0 }
        return max(width * fraction, height)
    }

    private func clamped(_ value: Double) -> Double { min(1, max(0, value)) }
}

/// Bar + status line + Stop/Retry: the aggregate readout for an album, playlist or radio,
/// shared by the detail hero and the Downloads screen's batch card so the two can never drift.
struct CollectionDownloadStrip: View {
    /// Carries its own cool-down (`progress.rateLimitedUntil`), scoped to this collection. It
    /// used to arrive as a separate process-wide date, which meant one refused download tinted
    /// every batch card on screen orange and captioned them all "Paused".
    let progress: CollectionDownloadProgress
    let onStop: () -> Void
    /// nil hides the Retry affordance, e.g. when there are no retained failures.
    let onRetry: (() -> Void)?
    /// nil hides Dismiss. Offered beside Retry once a batch has stopped with losses, because
    /// a retained failure is otherwise unclearable short of relaunching the app.
    var onDismiss: (() -> Void)?

    var body: some View {
        // The timeline is mounted only while a cool-down is pending, and it drives the *whole*
        // strip rather than just the countdown label. A body-time `Date.now` decided the paused
        // branch once per publish — and a deadline lapsing is exactly a moment when nothing
        // publishes, so a fully-failed batch sat frozen on "Resuming in 0:00" with the bar still
        // tinted orange. Hoisting it also keeps the tint and the caption from disagreeing.
        if progress.rateLimitedUntil != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(now: context.date)
            }
        } else {
            content(now: .now)
        }
    }

    private func content(now: Date) -> some View {
        let isRateLimited = progress.isRateLimited(at: now)
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            DownloadProgressBar(
                settled: progress.settled,
                fraction: progress.fraction,
                tint: isRateLimited ? Theme.warning : Theme.accent
            )

            HStack(spacing: Theme.Space.sm) {
                statusLabel(isRateLimited: isRateLimited, now: now)
                Spacer(minLength: Theme.Space.sm)
                trailingButtons
            }
        }
    }

    @ViewBuilder
    private func statusLabel(isRateLimited: Bool, now: Date) -> some View {
        if isRateLimited, let until = progress.rateLimitedUntil {
            let remaining = Self.countdown(to: until, from: now)
            // The column beside the buttons is ~230pt, and a one-line caption truncates from
            // the end — so spelling out *why* it is paused cost the countdown, the only part
            // that answers "should I wait?". The explanation moves to VoiceOver, which has no
            // width limit.
            statusText(
                "Paused · Resuming in \(remaining)",
                icon: "pause.circle.fill",
                tint: Theme.warning,
                spokenValue: "Paused, YouTube is limiting requests. Resuming in \(remaining)"
            )
        } else {
            statusText(statusString, icon: nil, tint: .secondary)
        }
    }

    private func statusText(_ string: String, icon: String?, tint: Color,
                            spokenValue: String? = nil) -> some View {
        HStack(spacing: Theme.Space.xs) {
            if let icon {
                Image(systemName: icon).font(.caption2)
            }
            Text(string)
                .lineLimit(1)
                // So "12 of 40" ticks over rather than crossfading — and so a radio refresh
                // growing the collection to "12 of 55" reads as a change, not a regression.
                .contentTransition(.numericText())
        }
        .font(.caption)
        .foregroundStyle(tint)
        // Applied here rather than to the enclosing VStack: `children: .ignore` on the
        // container would swallow the Stop button, which has to stay separately reachable.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Download progress")
        .accessibilityValue(spokenValue ?? string)
        .accessibilityAddTraits(progress.isActive ? [.updatesFrequently] : [])
    }

    /// Ordered by what the user most needs to know: why nothing is moving, then what is being
    /// prepared, then how much has landed, then what lost.
    private var statusString: String {
        let counts = "\(progress.completed) of \(progress.total)"
        if progress.isActive {
            // `preparingTitle` is only meaningful before the first transfer starts; once bytes
            // are arriving the counts are a better answer than whichever track is resolving.
            if let preparing = progress.preparingTitle, progress.bytesReceived == 0, progress.partial == 0 {
                return "Preparing \"\(preparing)\"…"
            }
            // Bytes and failures are additive clauses rather than alternatives: a batch that is
            // both moving and losing tracks used to report only the bytes, so the losses stayed
            // invisible until the whole thing stopped.
            var parts = ["Downloading \(counts)"]
            if progress.bytesReceived > 0 {
                parts.append(progress.bytesReceived.formatted(.byteCount(style: .file)))
            }
            if progress.hasFailures { parts.append("\(progress.failed) failed") }
            return parts.joined(separator: " · ")
        }
        if progress.hasFailures {
            return "\(counts) downloaded · \(progress.failed) failed"
        }
        return "\(counts) downloaded"
    }

    /// Real bordered buttons rather than bare text: as 11pt labels these were ~30 × 14pt of
    /// tappable area, well under the 44pt minimum, and nothing about them said "button".
    /// `.bordered` at `.small` supplies the target, the press feedback and the shape.
    @ViewBuilder
    private var trailingButtons: some View {
        if progress.isActive {
            Button("Stop", action: onStop)
                .tint(Color(.systemGray))
                .accessibilityLabel("Stop downloading")
                .modifier(StripButton())
        } else if progress.hasFailures {
            // Both, not one. A batch that has stopped with permanent losses is finished, and
            // offering only Retry meant a track that will never download could not be got rid
            // of at all — it sat on the Downloads screen until the app was relaunched.
            HStack(spacing: Theme.Space.md) {
                if let onRetry {
                    // Accent, not warning: retry is the recommended action here, and the
                    // orange is reserved for the thing that went wrong.
                    Button("Retry", action: onRetry)
                        .tint(Theme.accent)
                        .accessibilityLabel("Retry failed downloads")
                        .modifier(StripButton())
                }
                if let onDismiss {
                    Button("Dismiss", action: onDismiss)
                        .tint(Color(.systemGray))
                        .accessibilityLabel("Dismiss failed downloads")
                        .modifier(StripButton())
                }
            }
        }
    }

    /// m:ss. Rounded up, so a countdown never shows 0:00 while still waiting.
    static func countdown(to date: Date, from now: Date) -> String {
        let remaining = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        return "\(remaining / 60):\(String(format: "%02d", remaining % 60))"
    }
}

/// One shape for the strip's Stop / Retry / Dismiss controls, so the three can't drift.
/// Each caller supplies only its own `.tint`.
private struct StripButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.controlLabel)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

private struct BarPreviewCase: Identifiable {
    let settled: Double
    let fraction: Double
    var id: Double { settled * 10 + fraction }

    static let all: [BarPreviewCase] = [
        BarPreviewCase(settled: 0, fraction: 0),
        BarPreviewCase(settled: 0, fraction: 0.12),
        BarPreviewCase(settled: 0.3, fraction: 0.45),
        BarPreviewCase(settled: 0.75, fraction: 0.9),
        BarPreviewCase(settled: 1, fraction: 1),
    ]
}

#Preview("Bar layers") {
    VStack(alignment: .leading, spacing: 22) {
        ForEach(BarPreviewCase.all) { item in
            VStack(alignment: .leading, spacing: 6) {
                DownloadProgressBar(settled: item.settled, fraction: item.fraction)
                Text("settled \(item.settled.formatted()) · fraction \(item.fraction.formatted())")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        DownloadProgressBar(settled: 0.2, fraction: 0.35, tint: Theme.warning)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Theme.background)
}

#Preview("Strip states") {
    VStack(alignment: .leading, spacing: 28) {
        // Preparing: the resolver hasn't produced a single byte yet.
        CollectionDownloadStrip(
            progress: CollectionDownloadProgress(
                total: 40, completed: 0, failed: 0, active: 40,
                partial: 0, bytesReceived: 0, preparingTitle: "Everything In Its Right Place"
            ),
            onStop: {}, onRetry: nil
        )

        // Mid-batch.
        CollectionDownloadStrip(
            progress: CollectionDownloadProgress(
                total: 40, completed: 12, failed: 0, active: 28,
                partial: 0.4, bytesReceived: 48_000_000, preparingTitle: nil
            ),
            onStop: {}, onRetry: nil
        )

        // Rate-limited: the bar deliberately holds still, because nothing is advancing.
        CollectionDownloadStrip(
            progress: CollectionDownloadProgress(
                total: 40, completed: 12, failed: 1, active: 27,
                partial: 0, bytesReceived: 48_000_000, preparingTitle: nil,
                rateLimitedUntil: Date().addingTimeInterval(184)
            ),
            onStop: {}, onRetry: nil
        )

        // Finished with losses: retry or clear it away, because nothing else will.
        CollectionDownloadStrip(
            progress: CollectionDownloadProgress(
                total: 40, completed: 37, failed: 3, active: 0,
                partial: 0, bytesReceived: 0, preparingTitle: nil
            ),
            onStop: {}, onRetry: {}, onDismiss: {}
        )
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Theme.background)
}
