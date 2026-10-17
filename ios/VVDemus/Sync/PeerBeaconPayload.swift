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
    /// Deliberately *not* the session key. `PairedPeerStore.sessionToken(for:)` base64-encodes that
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

    /// How many sealed copies one characteristic value carries.
    ///
    /// Each member of the group holds a different key, so the value is one copy per member. A
    /// copy is about 150 bytes, an attribute value can be at most 512, and three copies with
    /// their framing come to about 450 — so a device in a group of four reaches every other
    /// member, and in a larger one reaches its three newest. Beyond one copy the value is longer
    /// than one ATT packet, which CoreBluetooth reads in pieces on its own (Read Blob) for a
    /// characteristic with a static value.
    static let maximumCopies = 3

    /// Marks a value holding several copies. A single copy is sent bare, exactly as before groups,
    /// so a member on an older build — which can only open one — still can.
    private static let framedMarker: UInt8 = 0xB2

    /// One characteristic value carrying `copies`: bare when there is one, otherwise the marker
    /// followed by each copy behind a two-byte big-endian length.
    static func combine(_ copies: [Data]) -> Data {
        guard copies.count > 1 else { return copies.first ?? Data() }
        var value = Data([framedMarker])
        for copy in copies {
            let length = UInt16(clamping: copy.count)
            value.append(UInt8(length >> 8))
            value.append(UInt8(length & 0xFF))
            value.append(copy.prefix(Int(length)))
        }
        return value
    }

    /// The copies in a characteristic value — the value itself when it is not framed. A frame
    /// that runs past the end ends the list rather than being read short.
    static func copies(in value: Data) -> [Data] {
        let bytes = [UInt8](value)
        guard bytes.first == framedMarker else { return [value] }
        var copies: [Data] = []
        var index = 1
        while index + 2 <= bytes.count {
            let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            index += 2
            guard length > 0, index + length <= bytes.count else { break }
            copies.append(Data(bytes[index..<index + length]))
            index += length
        }
        return copies
    }

    /// Opens whichever copy in a characteristic value is sealed for `key`, or `nil`.
    ///
    /// The whole value is tried as one copy first: a bare copy happens to begin with the marker
    /// byte one time in 256, since its first byte is the random nonce's.
    static func open(anyOf value: Data, using key: SymmetricKey, expecting peerId: String) -> PeerBeaconPayload? {
        if let single = open(value, using: key, expecting: peerId) { return single }
        for copy in copies(in: value) {
            if let payload = open(copy, using: key, expecting: peerId) { return payload }
        }
        return nil
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
