import CryptoKit
import Foundation

/// Another device in the group, once pairing has succeeded. Persisted, so pairing is a one-time act.
struct PairedPeer: Codable, Equatable, Identifiable {
    let peerId: String
    var name: String
    /// Raw X25519 public key. Together with this device's private key it re-derives the session
    /// token on every launch, so the token itself is never stored.
    let publicKey: Data
    var isDesktop: Bool
    /// Where the peer answered last. Tried before Bonjour on every reconnect: it is almost
    /// always still right, and a direct hit beats waiting for a browse.
    var lastKnownHost: String?
    /// And on which port. Not assumed to match this device's: when both apps run on one machine
    /// — a simulator beside the Mac app — the second to start falls back to the next port, so
    /// reusing the local port here would reconnect to itself or to nothing.
    var lastKnownPort: Int?
    var pairedAt: Date
    /// The device that told this one about it, when the two never typed a code at each other.
    ///
    /// Nil for a device paired here directly, and for every record written before groups
    /// existed — which were all direct.
    var introducedBy: String?

    var id: String { peerId }
}

/// One device as another device describes it, in a sync round. See `PairedPeerStore.merge`.
///
/// Either a live device (key, name, when it joined) or a removal (`removedAt`), never both — a
/// removal carries nothing but the id, since there is nobody left to describe.
struct DeviceRecord: Codable, Equatable {
    var peerId: String
    var name: String?
    /// Base64, as `PairRequest` carries it.
    var publicKey: String?
    var isDesktop: Bool?
    /// Where the describing device last reached it — a head start for the device being told,
    /// which would otherwise have only Bonjour to go on.
    var host: String?
    var port: Int?
    var pairedAt: Date?
    var removedAt: Date?
}

/// The devices this one is linked to.
///
/// A *group*, not a pair: pairing with any one member is enough to join all of them. Each sync
/// round carries this device's list (`deviceRecords`), and the other side adds whoever it has not
/// met (`merge`). Every two members still derive their own token from their own two keys — the
/// device doing the introducing passes on a public key and an address, never a secret, so it
/// could not listen in on the two it introduced even if it wanted to.
@MainActor
final class PairedPeerStore: ObservableObject {
    static let shared = PairedPeerStore()

    /// Oldest pairing first, so lists and pickers keep a stable order.
    @Published private(set) var peers: [PairedPeer] = []

    /// When each device that has left the group did so, by id.
    ///
    /// Remembered and passed on rather than simply forgotten, because otherwise the next round
    /// with anyone who has not heard yet introduces the removed device straight back. A device
    /// paired again *after* its removal is newer than the removal and wins, which is what lets a
    /// removed device rejoin with a fresh code.
    private(set) var removals: [String: Date] = [:]

    private let defaults: UserDefaults
    private let localPeerId: String
    /// What else has to forget a device when it leaves — the cursors, the mirror, the radio. A
    /// closure so a store built for a test can leave the app's real singletons alone.
    private let onForget: (String) -> Void

    private static let key = "paired_peers_v2"
    /// The single peer the app could hold before groups.
    private static let legacyKey = "paired_peer_v1"

    private struct Stored: Codable {
        var peers: [PairedPeer]
        var removals: [String: Date]
    }

    private convenience init() {
        self.init(
            defaults: .standard,
            localPeerId: PeerIdentity.shared.peerId,
            onForget: PairedPeerStore.forgetEverywhere
        )
    }

    /// Injectable for the same reason as `SessionOwnership.init(defaults:localPeerId:)`.
    init(defaults: UserDefaults, localPeerId: String, onForget: @escaping (String) -> Void = { _ in }) {
        self.defaults = defaults
        self.localPeerId = localPeerId
        self.onForget = onForget
        if let stored = DefaultsSnapshot.load(Stored.self, forKey: Self.key, from: defaults) {
            peers = stored.peers
            removals = stored.removals
        } else if let legacy = DefaultsSnapshot.load(PairedPeer.self, forKey: Self.legacyKey, from: defaults) {
            // The one device this install was paired with becomes a group of one. Its sync
            // cursors are keyed by peer id already, so nothing else has to move.
            peers = [legacy]
            persist()
            defaults.removeObject(forKey: Self.legacyKey)
        }
    }

    var hasPeers: Bool { !peers.isEmpty }

    func peer(id: String) -> PairedPeer? {
        peers.first { $0.peerId == id }
    }

    /// Records a device paired here, by code. Replaces any record of the same device.
    func save(_ peer: PairedPeer) {
        guard peer.peerId != localPeerId else { return }
        // A pairing made now outranks any earlier removal of the same device, here and — via the
        // record it produces — everywhere else.
        if let removedAt = removals[peer.peerId], removedAt <= peer.pairedAt {
            removals[peer.peerId] = nil
        }
        upsert(peer)
        persist()
    }

    func rememberAddress(host: String, port: Int, for peerId: String) {
        // The guard that was missing. See `PeerDiscovery.isWorthRemembering`: a self-assigned
        // address stored here outlives the interface that invented it and is then preferred over
        // discovery on every reconnect, so the link can only get worse from the moment it lands.
        guard PeerDiscovery.isWorthRemembering(host) else { return }
        guard var peer = peer(id: peerId), peer.lastKnownHost != host || peer.lastKnownPort != port else { return }
        peer.lastKnownHost = host
        peer.lastKnownPort = port
        upsert(peer)
        persist()
    }

    /// Takes a device out of the group — here now, and on every other member at its next round.
    func remove(peerId: String, at date: Date = Date()) {
        removals[peerId] = max(removals[peerId] ?? .distantPast, date)
        drop(peerId)
        persist()
    }

    /// This device leaves the group. Nobody is told here — `PeerLink.leaveGroup` does that first,
    /// while it still holds the keys to say it with.
    ///
    /// No removals are recorded. They would describe the others as having left, and if this
    /// device later pairs with one of them again they would have to be outranked one by one.
    func forgetAll() {
        let ids = peers.map(\.peerId)
        removals = [:]
        for id in ids { drop(id) }
        persist()
    }

    // MARK: - Tokens

    /// The bearer token both devices derive independently. Never transmitted during pairing —
    /// only the public keys are — so watching the pairing exchange does not yield it.
    func sessionToken(for peer: PairedPeer) -> String? {
        if let cached = tokens[peer.peerId], cached.publicKey == peer.publicKey { return cached.token }
        guard let key = try? PeerIdentity.shared.sharedSecret(with: peer.publicKey, peerId: peer.peerId) else {
            return nil
        }
        let token = key.withUnsafeBytes { Data($0).base64EncodedString() }
        tokens[peer.peerId] = (peer.publicKey, token)
        return token
    }

    /// Kept because the server asks on every authenticated request — which, with two peers each
    /// polling once a second, is a key agreement per peer per request just to find out who is
    /// knocking. Keyed with the public key so a re-pair under the same id cannot serve a stale one.
    private var tokens: [String: (publicKey: Data, token: String)] = [:]

    /// The paired device whose token this is, or nil.
    ///
    /// Every candidate is compared in full, with no early exit inside a comparison and none
    /// across them either — so the time a wrong token takes to refuse says nothing about how
    /// close it was, or to whose.
    func peer(presenting token: String) -> PairedPeer? {
        var match: PairedPeer?
        for peer in peers {
            guard let expected = sessionToken(for: peer), expected.utf8.count == token.utf8.count else { continue }
            var difference: UInt8 = 0
            for (lhs, rhs) in zip(token.utf8, expected.utf8) { difference |= lhs ^ rhs }
            if difference == 0 { match = peer }
        }
        return match
    }

    // MARK: - Introductions

    /// This device's view of the group, for a sync round.
    func deviceRecords() -> [DeviceRecord] {
        let live = peers.map { peer in
            DeviceRecord(
                peerId: peer.peerId,
                name: peer.name,
                publicKey: peer.publicKey.base64EncodedString(),
                isDesktop: peer.isDesktop,
                host: peer.lastKnownHost,
                port: peer.lastKnownPort,
                pairedAt: peer.pairedAt
            )
        }
        let gone = removals.map { DeviceRecord(peerId: $0.key, removedAt: $0.value) }
        return live + gone
    }

    /// Folds in another member's view of the group, reporting how many devices joined, left, or
    /// were paired again.
    ///
    /// Last writer wins, by `pairedAt` against `removedAt` and against the record already held —
    /// so a device paired again under the same id replaces the old record everywhere, key and
    /// all. That is the case that needs it: restoring an app's data onto a reinstall keeps its
    /// peer id (UserDefaults) but not its key (the Keychain, which does not move with a container
    /// or survive a change of signing team). Typing a code with one member then fixes that one
    /// link, and the newer pairing carries the new key to the rest. Only a member's word is taken
    /// for it, and the list it arrives in is signed — see `signature(of:for:)`.
    @discardableResult
    func merge(_ records: [DeviceRecord], from sender: String) -> Int {
        var changed = 0
        for record in records where record.peerId != localPeerId && record.peerId != sender {
            if let removedAt = record.removedAt {
                if removedAt > (removals[record.peerId] ?? .distantPast) {
                    removals[record.peerId] = removedAt
                }
                if let existing = peer(id: record.peerId), existing.pairedAt < removedAt {
                    PairLog.info("\(existing.name) was removed from the group on another device")
                    drop(record.peerId)
                    changed += 1
                }
                continue
            }
            let existing = peer(id: record.peerId)
            guard let pairedAt = record.pairedAt,
                  let encodedKey = record.publicKey,
                  let publicKey = Data(base64Encoded: encodedKey),
                  // Only a newer pairing replaces one already known.
                  existing.map({ $0.pairedAt < pairedAt }) ?? true,
                  // A device removed after this record was made stays removed.
                  (removals[record.peerId] ?? .distantPast) < pairedAt
            else { continue }
            let introduced = PairedPeer(
                peerId: record.peerId,
                name: record.name ?? existing?.name ?? "Another device",
                publicKey: publicKey,
                isDesktop: record.isDesktop ?? existing?.isDesktop ?? false,
                lastKnownHost: record.host.flatMap { PeerDiscovery.isWorthRemembering($0) ? $0 : nil } ?? existing?.lastKnownHost,
                lastKnownPort: record.port.flatMap { (1...65535).contains($0) ? $0 : nil } ?? existing?.lastKnownPort,
                pairedAt: pairedAt,
                introducedBy: sender
            )
            if existing == nil {
                PairLog.info("introduced to \(introduced.name) (peerId \(introduced.peerId.prefix(8))) by \(sender.prefix(8))")
            } else {
                PairLog.info("\(introduced.name) was paired again on \(sender.prefix(8)) — taking its newer record\(existing?.publicKey == publicKey ? "" : ", and its new key")")
            }
            removals[record.peerId] = nil
            upsert(introduced)
            changed += 1
        }
        if changed > 0 { persist() }
        return changed
    }

    // MARK: - Signing the list

    /// What separates the key that signs device lists from the session key and the beacon key —
    /// the same reason as `PeerBeaconPayload.keyInfo`. The session token travels in the clear on
    /// every request, so a list signed with it could be forged by anyone who has watched one go
    /// past; this key is derived on each end and never sent anywhere.
    static let signingKeyInfo = "vvdemus-device-list-v1"

    /// A signature over `records` that only `peer` — and this device — can produce or check.
    ///
    /// Signed because a list is the one thing in a round that can widen trust. A reply is not
    /// authenticated (whoever answers at the peer's address answers), and a request is only as
    /// authenticated as a token that goes over plain HTTP; either could otherwise add a device of
    /// the sender's choosing to every member of the group.
    func signature(of records: [DeviceRecord], for peer: PairedPeer) -> String? {
        guard let data = Self.canonical(records), let key = signingKey(for: peer) else { return nil }
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key)).base64EncodedString()
    }

    func verify(_ signature: String?, of records: [DeviceRecord], from peer: PairedPeer) -> Bool {
        guard let signature,
              let provided = Data(base64Encoded: signature),
              let data = Self.canonical(records),
              let key = signingKey(for: peer)
        else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(provided, authenticating: data, using: key)
    }

    private func signingKey(for peer: PairedPeer) -> SymmetricKey? {
        try? PeerIdentity.shared.sharedSecret(with: peer.publicKey, peerId: peer.peerId, info: Self.signingKeyInfo)
    }

    /// The same bytes on both ends: keys sorted, dates at the wire's second resolution. The
    /// receiver signs what it decoded, so this has to survive a trip through the wire unchanged.
    private static func canonical(_ records: [DeviceRecord]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(records)
    }

    // MARK: - Storage

    private func upsert(_ peer: PairedPeer) {
        if let index = peers.firstIndex(where: { $0.peerId == peer.peerId }) {
            peers[index] = peer
        } else {
            peers.append(peer)
            peers.sort { $0.pairedAt < $1.pairedAt }
        }
    }

    private func drop(_ peerId: String) {
        guard peers.contains(where: { $0.peerId == peerId }) else { return }
        peers.removeAll { $0.peerId == peerId }
        tokens[peerId] = nil
        onForget(peerId)
    }

    private func persist() {
        DefaultsSnapshot.save(Stored(peers: peers, removals: removals), forKey: Self.key, to: defaults)
    }

    /// Everything outside this store that holds something about one peer.
    private static func forgetEverywhere(_ peerId: String) {
        // The sync high-water marks describe a relationship that no longer exists; left
        // behind, re-pairing with the same device would start from them and silently skip
        // everything that changed in between.
        SyncCursor.reset(peerId: peerId)
        PeerClient.forget(peerId: peerId)
        // The ownership record is worse: if it names the device that has just gone, this one
        // goes on believing it is a mirror. Every transport press would be relayed into nowhere
        // and swallowed, with no way back short of relaunching the app.
        if SessionOwnership.shared.current.ownerPeerId == peerId {
            SessionOwnership.shared.resetToLocal()
        }
        PeerPlayback.shared.forget(peerId: peerId)
        // Re-sealed for whoever is left, or stopped if nobody is — otherwise the radio keeps
        // offering this device's address, sealed to a peer that is no longer paired.
        PeerBeacon.shared.groupDidChange()
    }
}
