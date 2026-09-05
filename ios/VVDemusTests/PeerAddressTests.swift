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

/// Which addresses are worth *writing down*, which is a narrower question than which are worth
/// dialling — and conflating the two is what left one pairing pinned to a dead `169.254` address
/// for months, with only Bonjour able to correct it and Bonjour unable to cross a router.
final class RememberedAddressTests: XCTestCase {
    func testASelfAssignedAddressIsNeverRemembered() {
        XCTAssertFalse(
            PeerDiscovery.isWorthRemembering("169.254.38.38"),
            "a self-assigned address outlives the interface that invented it, and is then preferred over discovery on every reconnect"
        )
    }

    func testARoutableAddressIsRemembered() {
        for address in ["10.29.190.75", "192.168.1.79", "172.16.4.2"] {
            XCTAssertTrue(PeerDiscovery.isWorthRemembering(address), address)
        }
    }

    /// Loopback stays acceptable on purpose: a simulator running beside the Mac app genuinely
    /// does reach it that way, which is why `preferredIPv4` ranks it above link-local rather
    /// than discarding it.
    func testLoopbackIsStillWorthRemembering() {
        XCTAssertTrue(
            PeerDiscovery.isWorthRemembering("127.0.0.1"),
            "two copies of the app on one machine reach each other here and nowhere else"
        )
    }

    /// Swifter hands back an empty string rather than nil when it cannot name the peer, and a
    /// hostname cannot be dialled by an IPv4-only server.
    func testNonAddressesAreNotRemembered() {
        for junk in ["", "localhost", "nishants-macbook-pro.local", "fe80::1%en0", "10.29.190"] {
            XCTAssertFalse(PeerDiscovery.isWorthRemembering(junk), "\"\(junk)\" was written down as a peer address")
        }
    }
}

/// The bound on how far a remembered address can point.
///
/// `PeerRoutes.learnPeerAddress` writes this field from an inbound request, authorised by a
/// bearer token that travels in cleartext. Keeping the field inside the private ranges is what
/// stops one captured token from redirecting a device to an attacker's machine on the open
/// internet, permanently and on every future network.
final class PeerAddressReachTests: XCTestCase {
    func testAPublicAddressIsNeverRemembered() {
        for address in ["203.0.113.9", "8.8.8.8", "18.30.139.221", "1.1.1.1"] {
            XCTAssertFalse(
                PeerDiscovery.isWorthRemembering(address),
                "\(address) is off-LAN — this link is LAN-only, so that cannot be the peer"
            )
        }
    }

    func testTheEdgesOfThePrivateRangesAreRespected() {
        for inside in ["172.16.0.1", "172.31.255.254", "10.0.0.1", "192.168.0.1", "100.64.0.1"] {
            XCTAssertTrue(PeerDiscovery.isPrivateIPv4(inside), "\(inside) is inside a private range")
        }
        for outside in ["172.15.0.1", "172.32.0.1", "192.169.0.1", "100.128.0.1", "11.0.0.1"] {
            XCTAssertFalse(PeerDiscovery.isPrivateIPv4(outside), "\(outside) is outside every private range")
        }
    }
}
