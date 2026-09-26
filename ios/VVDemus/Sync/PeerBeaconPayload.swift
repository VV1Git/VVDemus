import CryptoKit
import Foundation

/// What one device tells the other over Bluetooth: where to reach it over IP.
///
/// Bluetooth carries this and nothing else. Everything the two devices actually exchange —
/// libraries, playback, handoff — still goes over the LAN through `PeerClient`. The radio exists
/// to answer the one question Bonjour cannot answer across a router: *where is the other device
/// right now?* mDNS is multicast with a TTL of 1, so a peer one hop away is invisible to it, and
/// a campus or office network routinely puts two devices on one SSID into different subnets.
///
/// Sealed rather than sent in the clear. A GATT characteristic is readable by anything in radio
/// range and this names a device and its address on the local network; only the paired peer holds
/// the key, so to anything else it is noise.
struct PeerBeaconPayload: Equatable, Codable {
    /// The id of the device that sealed this — checked against the peer being looked for, so a
    /// device that has since re-paired, or a second one entirely, is not mistaken for it.
    let peerId: String
    /// Dotted-quad IPv4, the same form `PeerDiscovery` hands out and for the same reason: the
    /// embedded server binds IPv4 only, so an IPv6 address here would be refused on arrival.
    let host: String
    let port: Int
    /// When this was sealed. Carried for the log rather than enforced as an expiry.
    ///
    /// An expiry window sounds like the careful choice and is not. The device may have moved
    /// since it sealed this, and no window this side picks can tell — so `PeerClient.resolveBase`
    /// probes the address instead, which answers the real question directly. A stale address then
    /// costs one refused connection and an immediate fall-through, while an expiry would cost a
    /// re-seal timer running forever to defend against that same refused connection.
    let sentAt: Date

    /// The HKDF info string that separates the beacon key from the session key.
    ///
    /// Deliberately *not* the session key. `PairedPeerStore.sessionToken()` base64-encodes that
    /// key verbatim and `PeerClient` puts it in an `Authorization` header over plain HTTP, so
    /// anything that can watch one LAN request already holds it. Re-deriving here — same X25519
    /// secret, same sorted-id salt, different `sharedInfo` — keeps the key that protects the
    /// beacon off the wire entirely.
    static let keyInfo = "vvdemus-ble-beacon-v1"

    /// `.iso8601`, matching `LocalControlServer.peerEncoder`. Rebuilt per call rather than shared
    /// because this type is used from both the main actor and CoreBluetooth's callbacks, and a
    /// shared `JSONEncoder` is not safe across them.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Seals this for `key`: nonce ‖ ciphertext ‖ tag.
    ///
    /// 28 bytes over the JSON, which keeps the whole value inside one ATT exchange — so the
    /// reader needs no long-read or chunking scheme to get it.
    func sealed(using key: SymmetricKey) throws -> Data {
        try ChaChaPoly.seal(Self.encoder().encode(self), using: key).combined
    }

    /// Opens a characteristic value, or `nil` if it was not sealed by the expected peer.
    ///
    /// Every failure returns the same `nil` on purpose. A wrong key, a truncated read and a
    /// payload naming a different device all mean "keep looking", and distinguishing them in the
    /// log would tell anyone in radio range which of their guesses was closest.
    static func open(_ data: Data, using key: SymmetricKey, expecting peerId: String) -> PeerBeaconPayload? {
        guard let box = try? ChaChaPoly.SealedBox(combined: data),
              let plaintext = try? ChaChaPoly.open(box, using: key),
              let payload = try? decoder().decode(PeerBeaconPayload.self, from: plaintext),
              payload.peerId == peerId,
              LocalControlServer.isIPv4Literal(payload.host),
              (1...65535).contains(payload.port)
        else { return nil }
        return payload
    }
}
