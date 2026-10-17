import Foundation

/// How much of each peer's listening log this device already holds, and how much of this one's
/// each peer holds.
///
/// Only the event log needs a cursor. Everything else — likes, playlists, radios, the generated
/// caches — is small enough to exchange whole every round, and exchanging it whole removes a
/// class of "we disagree about what you already have" bugs entirely. The log is the one store
/// that grows without bound, and it is append-only and immutable, which makes "everything after
/// this point" an exact request rather than an optimisation that can skip something.
enum SyncCursor {
    private static let prefix = "sync_events_since_"
    private static let marksPrefix = "sync_peer_marks_"

    /// The newest play received from `peerId`, which is how far plays logged before
    /// `PlayEvent.origin` existed are pushed to it. See `EventMarks.select`.
    static func eventsSince(peerId: String) -> Date? {
        let value = UserDefaults.standard.double(forKey: prefix + peerId)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    static func setEventsSince(_ date: Date, peerId: String) {
        // Never moves backwards: a round that happened to carry nothing new must not widen the
        // window the next round asks for.
        if let existing = eventsSince(peerId: peerId), existing >= date { return }
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: prefix + peerId)
    }

    /// What `peerId` said it held, the last time it said — what a push to it is chosen after.
    ///
    /// Out of date the moment it is read, but only ever in one direction: a peer's marks never
    /// move backwards, so these are at or below what it holds now and a push chosen by them
    /// sends a little too much rather than leaving a hole. Nil for a peer on a build that does
    /// not report marks, which is pushed to by `eventsSince` exactly as before.
    static func confirmedMarks(peerId: String) -> EventMarks.Marks? {
        DefaultsSnapshot.load(EventMarks.Marks.self, forKey: marksPrefix + peerId)
    }

    static func setConfirmedMarks(_ marks: EventMarks.Marks, peerId: String) {
        DefaultsSnapshot.save(marks, forKey: marksPrefix + peerId)
    }

    /// Called when a device leaves the group. The cursors describe a relationship that no
    /// longer exists; left behind, pairing with the same device again would resume from them
    /// and silently skip everything that changed while the two were apart.
    static func reset(peerId: String) {
        UserDefaults.standard.removeObject(forKey: prefix + peerId)
        UserDefaults.standard.removeObject(forKey: marksPrefix + peerId)
    }
}
