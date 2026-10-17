import Foundation

/// How far each device's listening log is held without a gap, and what that says to send.
///
/// The log used to be exchanged by one date: "send me everything after the newest play I have".
/// Between two devices that is nearly right. Across three it loses plays outright — the newest
/// play here may have come from a third device, so everything the second device played *before*
/// it falls behind the date and is never asked for again. Phone at 8:00, iPad at 8:30, the iPad
/// syncs with the Mac, and the Mac then asks the phone for everything after 8:30.
///
/// So the date is kept per device that did the playing (`PlayEvent.origin`). Each device's plays
/// happen in order on that device, and every exchange below sends *all* of one device's plays
/// after a mark, never a selection — so what any device holds of another's log is always an
/// unbroken prefix of it, and its newest entry is an exact answer to "what am I missing".
///
/// A value-level enum for the same reason as `PlaybackMirror`: the cases worth pinning are three
/// devices in an awkward order, which is cheap here and miserable with three real ones.
enum EventMarks {
    typealias Marks = [String: Date]

    /// Whole seconds, which is all the wire carries (`.iso8601`). A local play at 10:00:00.7 is
    /// 10:00:00 everywhere else, and a mark compared at finer grain than that would send the
    /// same play back to its own device every round.
    static func second(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    /// What a device holding `marks` is missing, out of `events`.
    ///
    /// A play from a device the holder has no mark for is sent whatever its date — that is a
    /// device it has never heard from. Plays logged before origins existed have no device to
    /// file them under, so they go by the old single date, on or after `legacySince`.
    static func select(_ events: [PlayEvent], after marks: Marks, legacySince: Date?) -> [PlayEvent] {
        events.filter { event in
            guard let origin = event.origin else {
                guard let legacySince else { return true }
                return event.playedAt >= legacySince
            }
            guard let mark = marks[origin] else { return true }
            return second(event.playedAt) > mark
        }
    }

    /// `local`, moved on by what arrived with a payload.
    ///
    /// `senderMarks` says how far the sender holds each device's log without a gap. `base` is
    /// what the payload's plays were chosen after: everything of each device's the sender had
    /// beyond `base`, with a device missing from `base` meaning *all* of it. Nil means no claim
    /// at all — a push picked by the old date, which may have skipped something — and moves
    /// nothing.
    ///
    /// A device's mark here can then move up to the sender's only if nothing lies between: if
    /// the plays started at or below what is already held. Starting above it would leave a hole
    /// that no later round would ever ask about, since asking is done by mark.
    static func advance(_ local: Marks, senderMarks: Marks?, base: Marks?, localPeerId: String) -> Marks {
        guard let senderMarks, let base else { return local }
        var result = local
        for (origin, theirs) in senderMarks where origin != localPeerId {
            let held = local[origin]
            let joinsUp: Bool
            if let start = base[origin] {
                guard let held else { continue }
                joinsUp = start <= held
            } else {
                joinsUp = true
            }
            guard joinsUp else { continue }
            if held.map({ theirs > $0 }) ?? true {
                result[origin] = theirs
            }
        }
        return result
    }
}
