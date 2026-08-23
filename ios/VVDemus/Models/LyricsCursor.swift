import Foundation

/// Which line is being sung right now.
///
/// Pulled out of the view for the reason `CLAUDE.md` gives: this runs on every progress tick and is
/// the only thing deciding what is highlighted, so it is worth being able to ask it about a
/// backward seek or a half-second boundary without a song, a screen or a simulator.
///
/// Stateless on purpose. The tempting version remembers the last index and walks forward from it —
/// which is faster, and wrong the moment someone seeks backwards or the track changes underneath it.
enum LyricsCursor {

    /// The last line at or before `time`, or `nil` when the playhead sits before the first line.
    ///
    /// Expects `lines` sorted by `at`, which `LyricsBody.synced` guarantees at construction.
    static func activeIndex(in lines: [LyricsLine], at time: TimeInterval) -> Int? {
        // `NowPlayingView`'s scrubber emits negative times while a drag runs past the left edge and
        // `PlayerService.progress` passes them through unchanged. A negative playhead is not a
        // position in the song, so nothing is current — which also spares a file whose first
        // timestamp an `[offset:]` tag pushed below zero from lighting up before the song starts.
        guard time >= 0, let first = lines.first, first.at <= time else { return nil }

        // Upper bound: the answer is the last index in the run of equal timestamps, because every
        // line in that run is at or before the playhead and the one furthest down the file is the
        // one not yet sung past. Picking the first instead leaves the highlight a line behind for
        // as long as the tie lasts.
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = low + (high - low + 1) / 2
            if lines[mid].at <= time {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }
}
