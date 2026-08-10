import XCTest
@testable import VVDemus

/// Which of a peer's advertised addresses to actually dial.
///
/// Found by pairing two devices for real and watching it fail: the phone discovered the peer,
/// resolved it, and then could not connect — "discovered … at 169.254.231.149" followed by
/// "Could not connect to the server", on a loop, with a perfectly good address sitting unused in
/// the same Bonjour record. A device advertises every interface it has, and the first A record is
/// routinely a self-assigned one from an interface that is up but connected to nothing: an
/// unplugged Ethernet port, a USB-tethered phone, a Thunderbolt bridge.
///
/// The symptom is indistinguishable from "the peer isn't there", which is why it survived: the
/// log said discovery worked and the connection didn't, and the obvious suspects are the server,
/// the port and the firewall — not the address having been chosen badly out of a list.
final class PeerAddressTests: XCTestCase {
    func testPrefersARoutableAddressOverASelfAssignedOne() {
        XCTAssertEqual(
            PeerDiscovery.preferredIPv4(from: ["169.254.231.149", "192.168.1.79"]),
            "192.168.1.79",
            "a 169.254 address is what an interface gives itself when nothing answered — it routes nowhere"
        )
    }

    /// Order must not decide it. The bug was taking the first entry, and Bonjour puts them in
    /// whatever order it likes.
    func testTheAnswerDoesNotDependOnTheOrderTheyArrivedIn() {
        let routable = "10.0.0.5"
        XCTAssertEqual(PeerDiscovery.preferredIPv4(from: [routable, "169.254.1.1"]), routable)
        XCTAssertEqual(PeerDiscovery.preferredIPv4(from: ["169.254.1.1", routable]), routable)
    }

    /// Two copies of the app on one machine — a simulator beside the Mac app — really are
    /// reachable on loopback, so it beats link-local even though it beats nothing else.
    func testLoopbackBeatsLinkLocalButLosesToARealAddress() {
        XCTAssertEqual(PeerDiscovery.preferredIPv4(from: ["169.254.9.9", "127.0.0.1"]), "127.0.0.1")
        XCTAssertEqual(PeerDiscovery.preferredIPv4(from: ["127.0.0.1", "192.168.1.20"]), "192.168.1.20")
    }

    /// A link-local address is still better than giving up: `netServiceDidResolveAddress` falls
    /// back to the Bonjour hostname when this returns nil, and that resolves IPv6-first to a
    /// server that binds IPv4 only.
    func testATerribleAddressIsStillBetterThanNone() {
        XCTAssertEqual(PeerDiscovery.preferredIPv4(from: ["169.254.231.149"]), "169.254.231.149")
        XCTAssertNil(PeerDiscovery.preferredIPv4(from: []))
    }
}
