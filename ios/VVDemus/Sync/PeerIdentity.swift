import CryptoKit
import Foundation

#if os(iOS)
import UIKit
#endif

/// This install's identity to the other device: a stable id, a name to show while pairing, and
/// a long-term key pair.
///
/// CryptoKit and the Keychain are both entitlement-free, which matters here — the app is signed
/// by a free personal team, so anything needing a provisioning profile (iCloud, App Groups) is
/// off the table.
@MainActor
final class PeerIdentity {
    static let shared = PeerIdentity()

    let peerId: String
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    var publicKey: Data { privateKey.publicKey.rawRepresentation }

    /// What the other device shows while pairing. The machine's own name, so "iPhone" and
    /// "Vedant's MacBook Pro" are what you pick between rather than two UUIDs.
    let name: String

    /// `true` on the Mac. Carried in the Bonjour TXT record and in the now-playing checkpoint,
    /// because the desktop wins a tie when both devices are playing — see `NowPlayingCheckpoint`.
    let isDesktop: Bool

    private static let peerIdKey = "peer_identity_id_v1"

    private init() {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: Self.peerIdKey) {
            peerId = existing
        } else {
            let fresh = UUID().uuidString
            defaults.set(fresh, forKey: Self.peerIdKey)
            peerId = fresh
        }

        // The key lives in the Keychain rather than next to the id in UserDefaults: it is the
        // only thing standing between a paired peer and anything else on the same WiFi.
        if let stored = KeychainStore.read(account: "peer-identity-key"),
           let restored = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored) {
            privateKey = restored
        } else {
            let fresh = Curve25519.KeyAgreement.PrivateKey()
            KeychainStore.write(fresh.rawRepresentation, account: "peer-identity-key")
            privateKey = fresh
        }

        #if os(iOS)
        name = UIDevice.current.name
        isDesktop = false
        #else
        name = Host.current().localizedName ?? "Mac"
        isDesktop = true
        #endif
    }

    /// The symmetric key shared with `peerPublicKey`, from which the session token is derived.
    ///
    /// Salted with both peer ids in sorted order so the two sides agree without exchanging one
    /// more thing, and so the same key pair paired with a different device yields a different
    /// token.
    func sharedSecret(with peerPublicKey: Data, peerId otherId: String) throws -> SymmetricKey {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let salt = [peerId, otherId].sorted().joined(separator: "|")
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(salt.utf8),
            sharedInfo: Data("vvdemus-session-v1".utf8),
            outputByteCount: 32
        )
    }
}

/// The smallest Keychain wrapper that does the job — one generic-password item per account.
enum KeychainStore {
    private static let service = "com.vvdemus.peer"

    static func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func write(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        // The key is only ever needed while the app is running and the device is in use, and
        // `ThisDeviceOnly` keeps it out of a backup — a restored backup pairing as the device
        // it was taken from is not a thing anyone wants.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

}
