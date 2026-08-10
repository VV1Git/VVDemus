import Foundation

/// A download's *phase*, not just its fraction.
///
/// `progress[id] = 0` was set the instant a track was accepted, so a forty-track playlist
/// showed thirty-nine rows indistinguishable from "downloading, 0% done" for the minute
/// `downloadAll` spends resolving stream URLs one at a time. A failed resolve dropped the
/// entry entirely, so the row silently reverted to a plain download arrow and the user had
/// no idea which of forty tracks lost.
enum DownloadState: Equatable {
    /// Accepted into a bulk queue; the sequential resolver hasn't reached it yet.
    case queued
    /// This is the one track currently asking InnerTube for a stream URL.
    case resolving
    /// Handed to the background session. `expected` is nil when the server sent no
    /// Content-Length (`NSURLSessionTransferSizeUnknown`); callers MUST branch on nil rather
    /// than coerce it to 0, which the user reads as a stall. The old code's
    /// `guard totalBytesExpectedToWrite > 0 else { return }` dropped those updates outright,
    /// pinning such a transfer at zero for its entire life.
    case transferring(received: Int64, expected: Int64?)
    /// Terminal but *retained*, so the row offers a retry instead of reverting to a download
    /// arrow that gives no hint the last attempt failed. Never persisted.
    case failed(reason: String)

    var isInFlight: Bool {
        if case .failed = self { return false }
        return true
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// nil means "genuinely unknown", never "zero".
    var fraction: Double? {
        guard case .transferring(let received, let expected) = self,
              let expected, expected > 0 else { return nil }
        return min(1, Double(received) / Double(expected))
    }

    var receivedBytes: Int64 {
        if case .transferring(let received, _) = self { return received }
        return 0
    }
}

/// One in-flight (or recently failed) download, with the track needed to render it.
///
/// The track is carried here rather than looked up in `pendingDownloads` because a `.failed`
/// entry outlives its pending record — the pending record must be cleared on failure or a
/// relaunch would try to adopt a transfer that no longer exists.
struct DownloadEntry: Identifiable, Equatable {
    let track: Track
    /// `var`, because a collection can claim a download that started outside one: tapping
    /// Download All over tracks the user had already tapped individually adopts those transfers
    /// into the new batch rather than leaving them running beside it.
    var batchId: UUID?
    /// Monotonic insertion counter. `active` is a dictionary and has no order of its own, and
    /// the Downloads list must not reshuffle every time a fraction publishes.
    let order: Int
    var state: DownloadState

    var id: String { track.videoId }
}

/// A "download this collection" action, so the Downloads screen can show one row for forty
/// transfers and cancel them as a unit.
///
/// Persisted because the transfers outlive the app: a background session finishing a batch
/// while VVDemus is dead must not come back as forty anonymous downloads.
struct DownloadBatch: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let artworkURL: String?
    /// The full collection, not just the subset that needed downloading, so the card reads
    /// "10 of 40" rather than "0 of 30" when ten were already on disk.
    let videoIds: [String]
    let startedAt: Date
}

/// The collection-level download job running over a screen's tracks: which of them it covers,
/// and how far along it is.
///
/// Deliberately not the same question as `collectionProgress(for:)`, which answers "how much of
/// this collection is on disk" over every track regardless of how it got there. A detail hero's
/// progress strip is the readout of a *job* — the thing Download All started — and conflating
/// the two meant tapping download on three rows of a fifty-song playlist raised a bar captioned
/// "Downloading 0 of 50". Nobody asked for fifty, and the three rings that did describe the
/// request were the only honest thing on the screen. The Downloads screen has always drawn this
/// line — a batch gets a card, a single-tap download gets its own row — and the hero was the one
/// place that didn't.
struct CollectionDownloadJob: Equatable {
    /// The job's tracks that are also in the collection asking, so a batch started elsewhere
    /// reports only the part of itself that is on this screen. Also the scope of the strip's
    /// Stop, Retry and Dismiss, which must not reach a loose download the user started by hand.
    let videoIds: [String]
    let progress: CollectionDownloadProgress
}

/// Aggregate download state of an arbitrary set of tracks — an album, a playlist, a radio.
///
/// Deliberately unit-weighted rather than byte-weighted. `downloadAll` resolves stream URLs
/// one at a time, so for most of a forty-track batch thirty-nine tracks have no known content
/// length at all; a byte denominator that grows as each one resolves makes the bar slide
/// backwards for a minute straight. Bytes are still reported, but only ever as an absolute
/// quantity, never as a denominator.
struct CollectionDownloadProgress: Equatable {
    let total: Int
    let completed: Int
    let failed: Int
    /// queued + resolving + transferring. Excludes `.failed`.
    let active: Int
    /// Σ of the in-flight tracks' own known fractions. Unsized transfers contribute 0 —
    /// pessimistic, so the bar only ever moves forward.
    let partial: Double
    /// Bytes already on disk *plus* bytes still arriving.
    ///
    /// The completed half is not optional. Summing only live transfers meant a track finishing
    /// took its own multi-megabyte contribution out of the total in the same publish that
    /// incremented "N of M", so the one absolute quantity on screen counted backwards once per
    /// completed track — sawtoothing for the length of an album, and rendered digit-by-digit by
    /// `.contentTransition(.numericText())`.
    let bytesReceived: Int64
    /// Title of the track currently resolving, when nothing is transferring yet.
    let preparingTitle: String?
    /// When one of *these* tracks is parked waiting out a 429, and only then.
    ///
    /// Scoped to the collection rather than read off a process-wide date: a single global value
    /// tinted every batch card on screen orange and captioned them "Paused" because one
    /// unrelated download had been refused. Nil also means nil while transfers keep landing —
    /// a media host refusing one file does not pause the queue, so nothing claims it did.
    var rateLimitedUntil: Date? = nil

    static let empty = CollectionDownloadProgress(
        total: 0, completed: 0, failed: 0, active: 0,
        partial: 0, bytesReceived: 0, preparingTitle: nil
    )

    /// Takes the clock as a parameter rather than reading `.now`, so the view can re-decide this
    /// on a `TimelineView` tick. Evaluated at body time it is only re-read when something
    /// publishes, and the deadline lapsing is precisely a moment when nothing does — which left
    /// the strip frozen on "Resuming in 0:00" over a batch that had permanently failed.
    func isRateLimited(at date: Date) -> Bool {
        guard let rateLimitedUntil else { return false }
        // A cool-down with nothing left in flight behind it is over by definition; only a queue
        // that still has tracks to resolve can be said to be resuming.
        return rateLimitedUntil > date && active > 0
    }

    /// Solid portion of the bar: tracks actually on disk.
    var settled: Double { total > 0 ? Double(completed) / Double(total) : 0 }

    /// Leading (translucent) edge. Failures count toward it: a batch with three permanent
    /// failures is *finished*, and letting a failed track's 60%-transferred contribution
    /// vanish from the numerator is the one way this metric could run backwards.
    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, (Double(completed + failed) + partial) / Double(total))
    }

    var isActive: Bool { active > 0 }
    var hasFailures: Bool { failed > 0 }
    var isComplete: Bool { total > 0 && completed == total }
}
