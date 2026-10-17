import CryptoKit
import XCTest
@testable import VVDemus

/// What the Bluetooth beacon says, and who is able to read it.
///
/// The radio itself is a shell; everything worth being sure about is here — that a payload
/// survives the trip, that only the paired peer can open it, and that anything else at all comes
/// back as the same flat "not my peer" rather than as a half-trusted address.
final class PeerBeaconTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)
    private let mac = "peer-mac"

    private func payload(
        peerId: String = "peer-mac",
        host: String = "10.29.190.75",
        port: Int = 51825
    ) -> PeerBeaconPayload {
        PeerBeaconPayload(peerId: peerId, host: host, port: port, sentAt: Date(timeIntervalSince1970: 1_757_000_000))
    }

    func testAnAddressSurvivesBeingSealedAndOpened() throws {
        let original = payload()
        let opened = PeerBeaconPayload.open(try original.sealed(using: key), using: key, expecting: mac)
        XCTAssertEqual(opened, original, "the peer read the beacon but did not get back what was put in it")
    }

    /// The reason the beacon does not simply reuse the session key: that key is base64'd into an
    /// `Authorization` header and sent over plain HTTP, so anyone who has watched one request
    /// holds it. A different key must not open this.
    func testAnotherKeyCannotOpenIt() throws {
        let sealed = try payload().sealed(using: key)
        XCTAssertNil(
            PeerBeaconPayload.open(sealed, using: SymmetricKey(size: .bits256), expecting: mac),
            "a device holding the wrong key read the address anyway — the beacon is effectively public"
        )
    }

    /// Two devices paired to this one, or one that re-paired and got a new id: the payload opens,
    /// and must still be refused, or `resolveBase` would dial the wrong machine and cache it.
    func testAPayloadFromADifferentPeerIsRefusedEvenThoughItDecrypts() throws {
        let sealed = try payload(peerId: "peer-somebody-else").sealed(using: key)
        XCTAssertNil(
            PeerBeaconPayload.open(sealed, using: key, expecting: mac),
            "an address sealed by another device was accepted as the peer's"
        )
    }

    func testNoiseIsNotAnAddress() {
        for junk in [Data(), Data(repeating: 0, count: 12), Data("not sealed at all".utf8)] {
            XCTAssertNil(
                PeerBeaconPayload.open(junk, using: key, expecting: mac),
                "\(junk.count) bytes of non-payload came back as a usable address"
            )
        }
    }

    /// A truncated read is the ordinary Bluetooth failure, not an exotic one. It must not
    /// half-open into a payload with a plausible host and a garbage port.
    func testATruncatedReadIsRefused() throws {
        let sealed = try payload().sealed(using: key)
        XCTAssertNil(
            PeerBeaconPayload.open(sealed.dropLast(4), using: key, expecting: mac),
            "a payload missing its last four bytes still opened"
        )
    }

    /// The server binds IPv4 only, so a hostname here is an address that cannot be dialled —
    /// the same trap `PeerDiscovery` avoids by handing out the A record rather than the
    /// `.local` name.
    func testAHostThatIsNotAnIPv4LiteralIsRefused() throws {
        for host in ["nishants-macbook-pro.local", "fe80::1", "", "10.29.190"] {
            let sealed = try payload(host: host).sealed(using: key)
            XCTAssertNil(
                PeerBeaconPayload.open(sealed, using: key, expecting: mac),
                "\"\(host)\" was accepted as somewhere to send an HTTP request"
            )
        }
    }

    func testAPortOutsideTheUsableRangeIsRefused() throws {
        for port in [0, -1, 65536, 99999] {
            let sealed = try payload(port: port).sealed(using: key)
            XCTAssertNil(
                PeerBeaconPayload.open(sealed, using: key, expecting: mac),
                "port \(port) was accepted"
            )
        }
    }

    // MARK: - One value for the whole group

    /// One member: the value is the bare copy it always was, so a member on an older build — which
    /// can only open a single copy — still finds this device.
    func testASingleMemberGetsTheOldFormat() throws {
        let sealed = try payload().sealed(using: key)
        XCTAssertEqual(PeerBeaconPayload.combine([sealed]), sealed)
        XCTAssertNotNil(PeerBeaconPayload.open(PeerBeaconPayload.combine([sealed]), using: key, expecting: mac))
    }

    /// Several members: each opens the copy sealed with its own key, and only that one.
    func testEachMemberOpensItsOwnCopy() throws {
        let keys = [SymmetricKey(size: .bits256), SymmetricKey(size: .bits256), SymmetricKey(size: .bits256)]
        let value = PeerBeaconPayload.combine(try keys.map { try payload().sealed(using: $0) })
        for key in keys {
            XCTAssertEqual(PeerBeaconPayload.open(anyOf: value, using: key, expecting: mac), payload())
        }
        XCTAssertNil(PeerBeaconPayload.open(anyOf: value, using: SymmetricKey(size: .bits256), expecting: mac))
    }

    /// An attribute value tops out at 512 bytes. The most copies the beacon ever carries, with the
    /// longest address and a full-length id, have to fit.
    func testTheLargestValueFitsInOneAttribute() throws {
        let longest = PeerBeaconPayload(
            peerId: UUID().uuidString,
            host: "255.255.255.255",
            port: 65535,
            sentAt: Date(timeIntervalSince1970: 1_757_000_000)
        )
        let copies = try (0..<PeerBeaconPayload.maximumCopies).map { _ in try longest.sealed(using: SymmetricKey(size: .bits256)) }
        XCTAssertLessThanOrEqual(PeerBeaconPayload.combine(copies).count, 512)
    }

    /// A read cut short ends the list where it breaks rather than handing back a short copy.
    func testATruncatedFrameIsNotReadShort() throws {
        let first = SymmetricKey(size: .bits256)
        let second = SymmetricKey(size: .bits256)
        let value = PeerBeaconPayload.combine([try payload().sealed(using: first), try payload().sealed(using: second)])
        let cut = value.dropLast(10)
        XCTAssertNotNil(PeerBeaconPayload.open(anyOf: cut, using: first, expecting: mac))
        XCTAssertNil(PeerBeaconPayload.open(anyOf: cut, using: second, expecting: mac))
        XCTAssertEqual(PeerBeaconPayload.copies(in: Data(cut)).count, 1)
    }
}
