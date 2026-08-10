import CryptoKit
import Foundation

/// The other device, once pairing has succeeded. Persisted, so pairing is a one-time act.
struct PairedPeer: Codable, Equatable {
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
}

@MainActor
final class PairedPeerStore: ObservableObject {
    static let shared = PairedPeerStore()

    @Published private(set) var peer: PairedPeer?

    private let key = "paired_peer_v1"

    private init() {
        peer = DefaultsSnapshot.load(PairedPeer.self, forKey: key)
    }

    func save(_ peer: PairedPeer) {
        self.peer = peer
        persist()
    }

    func rememberAddress(host: String, port: Int) {
        guard var peer, peer.lastKnownHost != host || peer.lastKnownPort != port else { return }
        peer.lastKnownHost = host
        peer.lastKnownPort = port
        self.peer = peer
        persist()
    }

    func unpair() {
        peer = nil
        UserDefaults.standard.removeObject(forKey: key)
        // The sync high-water marks describe a relationship that no longer exists; left
        // behind, re-pairing with the same device would start from them and silently skip
        // everything that changed in between.
        SyncCursor.reset()
        // So does the ownership record, and that one is worse: it still names the device that has
        // just gone, so this one goes on believing it is a mirror. Every transport press would be
        // relayed into nowhere and swallowed, with no way back short of relaunching the app.
        SessionOwnership.shared.resetToLocal()
        PeerPlayback.shared.forgetPeer()
    }

    /// The bearer token both sides derive independently. Never transmitted during pairing —
    /// only the public keys are — so watching the pairing exchange does not yield it.
    func sessionToken() -> String? {
        guard let peer,
              let key = try? PeerIdentity.shared.sharedSecret(with: peer.publicKey, peerId: peer.peerId)
        else { return nil }
        return key.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    private func persist() {
        guard let peer, let data = try? JSONEncoder().encode(peer) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
