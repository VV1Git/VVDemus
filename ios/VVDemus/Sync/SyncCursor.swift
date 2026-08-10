import Foundation

/// How much of the peer's listening log this device already holds.
///
/// Only the event log needs a cursor. Everything else — likes, playlists, radios, the generated
/// caches — is small enough to exchange whole every round, and exchanging it whole removes a
/// class of "we disagree about what you already have" bugs entirely. The log is the one store
/// that grows without bound, and it is append-only and immutable, which makes "everything after
/// this instant" an exact request rather than an optimisation that can skip something.
enum SyncCursor {
    private static let prefix = "sync_events_since_"

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

    /// Called on unpair. The cursors describe a relationship that no longer exists; left
    /// behind, re-pairing with the same device would resume from them and silently skip
    /// everything that changed while the two were apart.
    static func reset() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
