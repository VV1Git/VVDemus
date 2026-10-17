import CryptoKit
import XCTest
@testable import VVDemus

/// Who is in the group, and how that spreads from one member to the rest.
///
/// Every case here is a disagreement between devices about membership — a removal one of them
/// has not heard of, an introduction older than a removal, a member describing a device another
/// already knows under a different key. Arranging those for real takes three devices and the
/// patience to sync them in the right order; here it takes two stores and a list.
@MainActor
final class GroupMembershipTests: XCTestCase {
    private let local = "device-local"
    private let mac = "device-mac"
    private let ipad = "device-ipad"
    private let phone = "device-phone"

    private func store(suite: String = UUID().uuidString) -> PairedPeerStore {
        PairedPeerStore(defaults: UserDefaults(suiteName: suite) ?? .standard, localPeerId: local)
    }

    private func key() -> Data {
        Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    }

    private func member(_ id: String, pairedAt: Date = Date(timeIntervalSince1970: 1_000), key: Data? = nil) -> PairedPeer {
        PairedPeer(
            peerId: id,
            name: "Name of \(id)",
            publicKey: key ?? self.key(),
            isDesktop: id == mac,
            lastKnownHost: "192.168.1.20",
            lastKnownPort: 51825,
            pairedAt: pairedAt
        )
    }

    private func record(of peer: PairedPeer) -> DeviceRecord {
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

    // MARK: - Joining

    /// An install paired before groups existed holds one peer under the old key. It has to come
    /// back as a group of one rather than as nobody — otherwise updating the app unpairs it.
    func testAnExistingPairingBecomesAGroupOfOne() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let old = member(mac)
        defaults.set(try JSONEncoder().encode(old), forKey: "paired_peer_v1")

        let migrated = store(suite: suite)

        XCTAssertEqual(migrated.peers, [old])
        XCTAssertNil(defaults.data(forKey: "paired_peer_v1"), "the old key is moved, not copied")
        XCTAssertEqual(store(suite: suite).peers, [old], "and the new one is what loads next time")
    }

    /// The whole feature in one line: pairing a third device used to *replace* the second.
    func testPairingAnotherDeviceKeepsTheFirst() {
        let group = store()
        group.save(member(mac))
        group.save(member(phone))
        XCTAssertEqual(Set(group.peers.map(\.peerId)), [mac, phone])
    }

    /// Paired with the Mac only, this device still meets the phone the Mac is paired with — and
    /// remembers who introduced it, and where the Mac last reached it.
    func testAMemberIntroducesTheDevicesItKnows() {
        let group = store()
        group.save(member(mac))
        let phoneOnTheMac = member(phone)

        let changed = group.merge([record(of: phoneOnTheMac)], from: mac)

        XCTAssertEqual(changed, 1)
        let introduced = group.peer(id: phone)
        XCTAssertEqual(introduced?.publicKey, phoneOnTheMac.publicKey)
        XCTAssertEqual(introduced?.introducedBy, mac)
        XCTAssertEqual(introduced?.lastKnownHost, "192.168.1.20")
    }

    /// A member's list includes the device it is talking to, and the sender's own record may
    /// turn up in a list relayed through someone else. Neither is an introduction: one is this
    /// device, the other is already known by the key it was paired with.
    func testNeitherThisDeviceNorTheSenderIsIntroduced() {
        let group = store()
        group.save(member(mac))
        let changed = group.merge([record(of: member(local)), record(of: member(mac))], from: mac)
        XCTAssertEqual(changed, 0)
        XCTAssertEqual(group.peers.map(\.peerId), [mac])
    }

    /// A record no newer than the one held changes nothing — a member describing a device from
    /// an older pairing cannot swap it for anything else.
    func testAnOlderRecordNeverReplacesAKnownDevice() {
        let group = store()
        let original = member(phone, pairedAt: Date(timeIntervalSince1970: 5_000))
        group.save(original)

        var older = record(of: member(phone, pairedAt: Date(timeIntervalSince1970: 4_000)))
        older.name = "Not really the phone"
        group.merge([older], from: mac)
        group.merge([record(of: member(phone, pairedAt: Date(timeIntervalSince1970: 5_000)))], from: mac)

        XCTAssertEqual(group.peer(id: phone), original)
    }

    /// Restoring an app's data onto a reinstall keeps its id but not its key, and every member
    /// then refuses it. Paired again by code with one member, the newer pairing has to reach the
    /// rest with the new key — or only that one link ever works again.
    func testANewerPairingCarriesANewKeyToTheRestOfTheGroup() {
        let group = store()
        group.save(member(phone, pairedAt: Date(timeIntervalSince1970: 1_000)))

        let pairedAgain = member(phone, pairedAt: Date(timeIntervalSince1970: 9_000))
        let changed = group.merge([record(of: pairedAgain)], from: mac)

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(group.peer(id: phone)?.publicKey, pairedAgain.publicKey)
        XCTAssertEqual(group.peer(id: phone)?.pairedAt, pairedAgain.pairedAt)
    }

    /// A record that is not a valid device is skipped rather than half-added.
    func testARecordWithoutAKeyIsIgnored() {
        let group = store()
        group.merge([DeviceRecord(peerId: phone, name: "Phone", publicKey: "not base64 at all!", pairedAt: Date())], from: mac)
        group.merge([DeviceRecord(peerId: ipad, name: "iPad", publicKey: nil, pairedAt: Date())], from: mac)
        XCTAssertTrue(group.peers.isEmpty)
    }

    // MARK: - Leaving

    /// Removed on one device, gone from every other at its next round.
    func testARemovalReachesTheRestOfTheGroup() {
        let removedOnTheMac = store()
        removedOnTheMac.save(member(phone, pairedAt: Date(timeIntervalSince1970: 1_000)))
        removedOnTheMac.remove(peerId: phone, at: Date(timeIntervalSince1970: 2_000))

        let here = store()
        here.save(member(mac))
        here.save(member(phone, pairedAt: Date(timeIntervalSince1970: 1_000)))

        let changed = here.merge(removedOnTheMac.deviceRecords(), from: mac)

        XCTAssertEqual(changed, 1)
        XCTAssertNil(here.peer(id: phone))
        XCTAssertNotNil(here.peer(id: mac))
    }

    /// The reason removals are remembered at all. A member that has not heard yet still lists
    /// the phone; without the removal on file, the next round with it puts the phone straight
    /// back.
    func testARemovedDeviceIsNotReintroducedByAMemberThatHasNotHeard() {
        let here = store()
        here.save(member(phone, pairedAt: Date(timeIntervalSince1970: 1_000)))
        here.remove(peerId: phone, at: Date(timeIntervalSince1970: 2_000))

        let stale = record(of: member(phone, pairedAt: Date(timeIntervalSince1970: 1_000)))
        here.merge([stale], from: ipad)

        XCTAssertNil(here.peer(id: phone))
    }

    /// And the converse: removed once, paired again with a fresh code later, it is back — and
    /// its newer pairing outranks the old removal on every device it reaches.
    func testPairingAgainAfterARemovalWins() {
        let removedEarlier = store()
        removedEarlier.save(member(phone, pairedAt: Date(timeIntervalSince1970: 1_000)))
        removedEarlier.remove(peerId: phone, at: Date(timeIntervalSince1970: 2_000))

        let pairedAgainOnTheMac = member(phone, pairedAt: Date(timeIntervalSince1970: 3_000))
        removedEarlier.merge([record(of: pairedAgainOnTheMac)], from: mac)

        XCTAssertEqual(removedEarlier.peer(id: phone)?.publicKey, pairedAgainOnTheMac.publicKey)
        XCTAssertFalse(
            removedEarlier.deviceRecords().contains { $0.peerId == phone && $0.removedAt != nil },
            "the old removal is spent, not passed on beside the device it removed"
        )
    }

    /// A removal older than the pairing it meets is about an earlier membership, not this one.
    func testAnOldRemovalDoesNotUndoANewerPairing() {
        let here = store()
        here.save(member(phone, pairedAt: Date(timeIntervalSince1970: 5_000)))
        here.merge([DeviceRecord(peerId: phone, removedAt: Date(timeIntervalSince1970: 4_000))], from: mac)
        XCTAssertNotNil(here.peer(id: phone))
    }

    /// Leaving drops every member, and records no removals: they would describe the others as
    /// having left, and would have to be outranked one by one to join again.
    func testLeavingForgetsEveryoneWithoutRemovingThem() {
        let here = store()
        here.save(member(mac))
        here.save(member(phone))
        here.forgetAll()
        XCTAssertTrue(here.peers.isEmpty)
        XCTAssertTrue(here.deviceRecords().isEmpty)
    }

    /// Everything that holds state about one member is told when it goes — and only about it.
    func testRemovingAMemberForgetsOnlyThatMember() {
        var forgotten: [String] = []
        let here = PairedPeerStore(
            defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard,
            localPeerId: local,
            onForget: { forgotten.append($0) }
        )
        here.save(member(mac))
        here.save(member(phone))
        here.remove(peerId: phone)
        XCTAssertEqual(forgotten, [phone])
        XCTAssertEqual(here.peers.map(\.peerId), [mac])
    }

    // MARK: - Telling members apart

    /// The server has to know *which* member is knocking, not only that one is: a sync is filed
    /// under it, and "play it here" sends the session to it.
    func testATokenIdentifiesWhichMemberPresentedIt() throws {
        let group = store()
        let theMac = member(mac)
        let thePhone = member(phone)
        group.save(theMac)
        group.save(thePhone)

        let macToken = try XCTUnwrap(group.sessionToken(for: theMac))
        let phoneToken = try XCTUnwrap(group.sessionToken(for: thePhone))

        XCTAssertNotEqual(macToken, phoneToken, "each pair of devices derives its own token")
        XCTAssertEqual(group.peer(presenting: macToken)?.peerId, mac)
        XCTAssertEqual(group.peer(presenting: phoneToken)?.peerId, phone)
        XCTAssertNil(group.peer(presenting: String(repeating: "A", count: macToken.count)))
        XCTAssertNil(group.peer(presenting: ""))
    }

    /// A removed member's token stops working the moment it is removed.
    func testARemovedMembersTokenIsRefused() throws {
        let group = store()
        let thePhone = member(phone)
        group.save(thePhone)
        let token = try XCTUnwrap(group.sessionToken(for: thePhone))
        group.remove(peerId: phone)
        XCTAssertNil(group.peer(presenting: token))
    }

    // MARK: - Signed lists

    /// The list survives the wire — re-encoded on arrival, which is what the receiver signs —
    /// and verifies for the member it was signed for.
    func testASignedListVerifiesAfterTheWire() throws {
        let group = store()
        let theMac = member(mac)
        group.save(theMac)
        group.save(member(phone, pairedAt: Date(timeIntervalSince1970: 1_234.567)))
        group.remove(peerId: ipad, at: Date(timeIntervalSince1970: 2_000.9))

        let records = group.deviceRecords()
        let signature = group.signature(of: records, for: theMac)
        let wire = try LocalControlServer.peerEncoder.encode(records)
        let arrived = try LocalControlServer.peerDecoder.decode([DeviceRecord].self, from: wire)

        XCTAssertTrue(group.verify(signature, of: arrived, from: theMac))
    }

    /// Anything changed in transit — a key swapped, a device added — and the list is ignored.
    func testATamperedListDoesNotVerify() {
        let group = store()
        let theMac = member(mac)
        group.save(theMac)
        group.save(member(phone))
        var records = group.deviceRecords()
        let signature = group.signature(of: records, for: theMac)

        records[1].publicKey = key().base64EncodedString()
        XCTAssertFalse(group.verify(signature, of: records, from: theMac))
        XCTAssertFalse(group.verify(signature, of: group.deviceRecords() + [record(of: member(ipad))], from: theMac))
        XCTAssertFalse(group.verify(nil, of: group.deviceRecords(), from: theMac))
    }

    /// Signed for one member, it does not pass as another's.
    func testAListSignedForOneMemberDoesNotVerifyFromAnother() {
        let group = store()
        let theMac = member(mac)
        let thePhone = member(phone)
        group.save(theMac)
        group.save(thePhone)
        let records = group.deviceRecords()
        XCTAssertFalse(group.verify(group.signature(of: records, for: theMac), of: records, from: thePhone))
    }
}
