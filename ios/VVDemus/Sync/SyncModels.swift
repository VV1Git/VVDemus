import Foundation

/// When a record last changed, and on which device.
///
/// The device id is not decoration: two edits can carry the same instant (clocks are coarse,
/// and a merge can replay a batch), and without a deterministic tiebreak the two peers can pick
/// different winners and never converge.
struct EditStamp: Codable, Equatable {
    var editedAt: Date
    var editedBy: String

    static func now() -> EditStamp {
        EditStamp(editedAt: Date(), editedBy: PeerIdentityBox.currentPeerId)
    }

    /// Strictly newer than `other`. Equal stamps are *not* newer — merging must be idempotent,
    /// so re-receiving the same record has to be a no-op.
    func isNewerThan(_ other: EditStamp) -> Bool {
        if editedAt != other.editedAt { return editedAt > other.editedAt }
        return editedBy > other.editedBy
    }
}

/// Reading `PeerIdentity.shared` is main-actor work, and stamps are made from wherever a store
/// happens to be mutated. The id never changes after first launch, so it is cached here once.
enum PeerIdentityBox {
    nonisolated(unsafe) static var currentPeerId: String = UserDefaults.standard
        .string(forKey: "peer_identity_id_v1") ?? "unknown"
}

// MARK: - Records

/// One liked track. A tombstone rather than a deletion, so an unlike on one device survives
/// meeting a device that still has the like.
struct LikeRecord: Codable, Equatable {
    var track: Track
    var likedAt: Date
    var removedAt: Date?
    var stamp: EditStamp

    var isPresent: Bool { removedAt == nil }
}

/// One track's membership of one playlist.
///
/// Membership is per-entry precisely so that adding a different song on each device is two
/// edits to two different records, which both survive. A playlist merged as a whole object
/// would keep one side's track list and silently drop the other's addition.
struct PlaylistEntry: Codable, Equatable {
    var track: Track
    var addedAt: Date
    var removedAt: Date?
    /// Fractional position key. A reorder rewrites this one entry's key instead of shuffling an
    /// array, so a move on one device and an add on the other do not compete.
    var order: String
    var stamp: EditStamp

    var isPresent: Bool { removedAt == nil }
}

struct PlaylistRecord: Codable, Equatable {
    var id: UUID
    var name: String
    /// Separate from the entries' stamps: renaming on one device while adding a track on the
    /// other must keep both.
    var nameStamp: EditStamp
    var createdAt: Date
    var removedAt: Date?
    var entries: [PlaylistEntry]

    var isPresent: Bool { removedAt == nil }

    /// The tracks as the UI wants them: present entries, in merged order, with `videoId` as the
    /// final tiebreak so both devices agree without having to talk.
    var orderedTracks: [Track] {
        sortedPresentEntries.map(\.track)
    }

    var sortedPresentEntries: [PlaylistEntry] {
        let present = entries.filter { $0.isPresent }
        return present.sorted(by: PlaylistEntry.precedes)
    }
}

extension PlaylistEntry {
    /// Broken out of the sort closure: inline, the ternary plus two comparisons was enough to
    /// stall the type checker.
    static func precedes(_ lhs: PlaylistEntry, _ rhs: PlaylistEntry) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        return lhs.track.videoId < rhs.track.videoId
    }
}

extension PlaylistRecord {
    /// Folds `incoming` into `local`, returning the merged record and whether anything moved.
    ///
    /// A free function rather than a method on the store so the rules can be exercised
    /// directly — two divergent copies in, one merged copy out, no singletons, no UserDefaults
    /// and no network. This is the piece the whole additive-merge promise rests on.
    static func merging(_ local: PlaylistRecord, _ incoming: PlaylistRecord) -> (record: PlaylistRecord, changed: Bool) {
        var result = local
        var changed = false

        // Name and existence resolve on their own stamp, independently of membership — so
        // renaming on one device while adding a track on the other keeps both.
        if incoming.nameStamp.isNewerThan(local.nameStamp) {
            result.name = incoming.name
            result.removedAt = incoming.removedAt
            result.nameStamp = incoming.nameStamp
            changed = true
        }

        for entry in incoming.entries {
            guard let index = result.entries.firstIndex(where: { $0.track.videoId == entry.track.videoId }) else {
                result.entries.append(entry)
                changed = true
                continue
            }
            guard entry.stamp.isNewerThan(result.entries[index].stamp) else { continue }
            result.entries[index] = entry
            changed = true
        }
        return (result, changed)
    }
}

struct RadioRecord: Codable, Equatable {
    var seedTrack: Track
    var lastPlayedAt: Date
    var removedAt: Date?
    var stamp: EditStamp

    var isPresent: Bool { removedAt == nil }
}

/// One release the user has opened. A tombstone for the same reason as everything else here:
/// removing an album on one device must survive meeting a device that still has it.
///
/// The whole `Album` is carried rather than just its `browseId`. The peer may never have
/// opened it, so there is nowhere for it to look the title and cover up — and going to
/// YouTube for them would make a sync depend on the network reaching further than the room.
struct AlbumRecord: Codable, Equatable {
    var album: Album
    var lastOpenedAt: Date
    var removedAt: Date?
    var stamp: EditStamp

    var isPresent: Bool { removedAt == nil }
}

extension AlbumRecord {
    /// Folds `incoming` into `local`, returning the merged set and how many records moved.
    ///
    /// A free function for the same reason `PlaylistRecord.merging` is one: this is where the
    /// promise that a removal survives a sync actually lives, and `AlbumHistoryStore` is a
    /// singleton over `UserDefaults.standard` — reaching the rule through it means a test
    /// writes into the app's own library on whatever simulator it happens to run on.
    ///
    /// Whole-record newest-wins, unlike a playlist's per-entry merge: a release has no
    /// contents of its own to lose, so there is nothing here that two devices can each hold
    /// half of. The only fields are "when did you open it" and "have you removed it", and for
    /// both the later edit is simply the right answer.
    static func merging(
        _ local: [AlbumRecord],
        _ incoming: [AlbumRecord]
    ) -> (records: [AlbumRecord], changed: Int) {
        var result = local
        var changed = 0
        for record in incoming {
            guard let index = result.firstIndex(where: { $0.album.browseId == record.album.browseId }) else {
                result.append(record)
                changed += 1
                continue
            }
            // Equal stamps are not newer — merging has to be idempotent, so re-receiving a
            // record the peer already sent is a no-op rather than a reported change.
            guard record.stamp.isNewerThan(result[index].stamp) else { continue }
            result[index] = record
            changed += 1
        }
        return (result, changed)
    }

    /// The tombstone-free projection the UI reads: present records, newest first, capped.
    ///
    /// The cap is applied *here* and not to storage. Trimming the records would make falling
    /// off the end indistinguishable from a deletion, and the next sync would hand every
    /// trimmed album straight back.
    static func present(_ records: [AlbumRecord], limit: Int) -> [Album] {
        records
            .filter(\.isPresent)
            .sorted { $0.lastOpenedAt == $1.lastOpenedAt
                ? $0.album.browseId < $1.album.browseId
                : $0.lastOpenedAt > $1.lastOpenedAt }
            .prefix(limit)
            .map(\.album)
    }
}

/// A cache that is generated whole — the daylist, Home's shelves, one station's track list.
///
/// Merged newest-wins rather than unioned: these are single generated artefacts, and half of
/// one day's mix spliced into another's is not something the user ever had.
struct GeneratedRecord: Codable, Equatable {
    var id: String
    var payload: Data
    var generatedAt: Date
    var stamp: EditStamp
}

// MARK: - The wire payload

/// Everything one peer sends the other in a sync round.
///
/// Full state for the small stores — likes and playlists are a few hundred records at most, and
/// exchanging them whole removes a whole class of "we disagree about what you already have"
/// bugs. The listening log is the one that grows without bound, so it is asked for by time:
/// events are immutable and append-only, which makes "everything after T" exact.
struct SyncPayload: Codable {
    var peerId: String
    var likes: [LikeRecord]
    var playlists: [PlaylistRecord]
    var radios: [RadioRecord]
    /// Optional purely for wire compatibility, and read through `openedAlbums`. The two
    /// devices update independently, so a build that knows about albums has to be able to
    /// decode a payload from one that does not — and a synthesised `Decodable` throws on a
    /// missing key even when the property has a default.
    var albums: [AlbumRecord]?
    var generated: [GeneratedRecord]
    var recentSearches: [String]
    var events: [PlayEvent]
    /// The newest event the sender already holds from the recipient, so the reply can skip
    /// everything older.
    var eventsSince: Date?

    /// The album records, with "the peer is on an older build" folded into "the peer has no
    /// albums" — which is the same thing as far as merging goes.
    var openedAlbums: [AlbumRecord] { albums ?? [] }
}

// MARK: - Fractional order keys

/// Positions that can be inserted between without renumbering anything else.
///
/// A plain index would mean a move rewrites every row after it, and two devices reordering
/// different tracks would then produce conflicting rewrites of the same numbers. A key that
/// only its own row owns keeps concurrent moves independent.
enum OrderKey {
    private static let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")

    /// A key strictly between `lower` and `upper`. `nil` means "no bound on that side".
    static func between(_ lower: String?, _ upper: String?) -> String {
        let lo = Array(lower ?? "")
        let hi = Array(upper ?? "")
        var result = ""
        var index = 0
        while true {
            let low = index < lo.count ? (alphabet.firstIndex(of: lo[index]) ?? 0) : 0
            let high = index < hi.count ? (alphabet.firstIndex(of: hi[index]) ?? 0) : alphabet.count
            if low + 1 < high {
                result.append(alphabet[(low + high) / 2])
                return result
            }
            // The digits are adjacent or equal, so no key fits at this position — take the
            // lower bound's digit and look one place further right. `lo` is finite, so this
            // runs out and terminates.
            result.append(index < lo.count ? lo[index] : alphabet[0])
            index += 1
        }
    }

    /// Evenly spaced keys for a list being stamped for the first time.
    static func initialKeys(count: Int) -> [String] {
        var keys: [String] = []
        var previous: String?
        for _ in 0..<count {
            let key = between(previous, nil)
            keys.append(key)
            previous = key
        }
        return keys
    }
}
