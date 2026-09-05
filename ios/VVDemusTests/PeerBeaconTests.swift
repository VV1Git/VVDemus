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
}
