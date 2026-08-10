import XCTest
@testable import VVDemus

/// The merge rules, exercised directly — two divergent copies in, one merged copy out. No
/// singletons, no UserDefaults, no network and no audio, which is what makes the awkward cases
/// (offline edits on both sides, a delete racing a re-add) cheap enough to cover exhaustively.
@MainActor
final class SyncMergeTests: XCTestCase {
    private let phone = "phone-peer"
    private let mac = "mac-peer"

    private func track(_ id: String) -> Track {
        Track(videoId: id, title: "Track \(id)", artist: "Artist", album: nil, thumbnailUrl: nil, durationSeconds: 100)
    }

    private func stamp(_ peer: String, _ secondsFromNow: TimeInterval) -> EditStamp {
        EditStamp(editedAt: Date().addingTimeInterval(secondsFromNow), editedBy: peer)
    }

    private func entry(_ id: String, order: String, peer: String, at offset: TimeInterval, removed: Bool = false) -> PlaylistEntry {
        PlaylistEntry(
            track: track(id),
            addedAt: Date().addingTimeInterval(offset),
            removedAt: removed ? Date().addingTimeInterval(offset) : nil,
            order: order,
            stamp: stamp(peer, offset)
        )
    }

    private func playlist(_ entries: [PlaylistEntry], name: String = "Chill", nameAt: TimeInterval = -100, by peer: String = "phone-peer") -> PlaylistRecord {
        PlaylistRecord(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: name,
            nameStamp: stamp(peer, nameAt),
            createdAt: Date().addingTimeInterval(-1000),
            removedAt: nil,
            entries: entries
        )
    }

    // MARK: - The headline case

    /// A playlist both devices already have. Offline, a different song is added on each. After
    /// syncing, the playlist must contain both — and in the same order on both devices.
    func testConcurrentAddsOnBothDevicesBothSurvive() {
        let shared = entry("shared", order: "g", peer: phone, at: -500)
        let onMac = entry("mac-only", order: "n", peer: mac, at: -10)
        let onPhone = entry("phone-only", order: "n", peer: phone, at: -20)

        let macCopy = playlist([shared, onMac])
        let phoneCopy = playlist([shared, onPhone])

        let macMerged = PlaylistRecord.merging(macCopy, phoneCopy).record
        let phoneMerged = PlaylistRecord.merging(phoneCopy, macCopy).record

        XCTAssertEqual(Set(macMerged.orderedTracks.map(\.videoId)), ["shared", "mac-only", "phone-only"])
        XCTAssertEqual(
            macMerged.orderedTracks.map(\.videoId),
            phoneMerged.orderedTracks.map(\.videoId),
            "both devices must land on the same order without talking to each other"
        )
    }

    func testMergeIsIdempotent() {
        let local = playlist([entry("a", order: "g", peer: phone, at: -100)])
        let remote = playlist([entry("b", order: "n", peer: mac, at: -50)])

        let once = PlaylistRecord.merging(local, remote)
        let twice = PlaylistRecord.merging(once.record, remote)

        XCTAssertTrue(once.changed)
        XCTAssertFalse(twice.changed, "re-receiving the same records must be a no-op")
        XCTAssertEqual(once.record.orderedTracks.map(\.videoId), twice.record.orderedTracks.map(\.videoId))
    }

    // MARK: - Deletes

    func testNewerRemovalWinsOverOlderAdd() {
        let local = playlist([entry("a", order: "g", peer: phone, at: -100)])
        let remote = playlist([entry("a", order: "g", peer: mac, at: -10, removed: true)])

        let merged = PlaylistRecord.merging(local, remote).record
        XCTAssertTrue(merged.orderedTracks.isEmpty, "a delete newer than the add must propagate")
    }

    func testReAddAfterRemovalWins() {
        let local = playlist([entry("a", order: "g", peer: phone, at: -100, removed: true)])
        let remote = playlist([entry("a", order: "g", peer: mac, at: -5)])

        let merged = PlaylistRecord.merging(local, remote).record
        XCTAssertEqual(merged.orderedTracks.map(\.videoId), ["a"], "the newest edit wins, and here it is the re-add")
    }

    func testRenameOnOneDeviceAndAddOnTheOtherKeepBoth() {
        let local = playlist([entry("a", order: "g", peer: phone, at: -100)], name: "Chill", nameAt: -100)
        var remote = playlist([entry("b", order: "n", peer: mac, at: -50)], name: "Late Night", nameAt: -20, by: mac)
        remote.entries.append(entry("a", order: "g", peer: phone, at: -100))

        let merged = PlaylistRecord.merging(local, remote).record
        XCTAssertEqual(merged.name, "Late Night")
        XCTAssertEqual(Set(merged.orderedTracks.map(\.videoId)), ["a", "b"])
    }

    // MARK: - Order keys

    func testOrderKeyAlwaysLandsStrictlyBetween() {
        // Repeated insertion at the same spot is the case that breaks a naive midpoint scheme:
        // it is where a fixed-width key runs out of room.
        var lower = "a"
        let upper = "b"
        for _ in 0..<50 {
            let key = OrderKey.between(lower, upper)
            XCTAssertTrue(key > lower, "\(key) must sort after \(lower)")
            XCTAssertTrue(key < upper, "\(key) must sort before \(upper)")
            lower = key
        }
    }

    func testOrderKeyHandlesOpenBounds() {
        let first = OrderKey.between(nil, nil)
        let before = OrderKey.between(nil, first)
        let after = OrderKey.between(first, nil)
        XCTAssertTrue(before < first)
        XCTAssertTrue(after > first)
    }

    func testOrderKeyTerminatesAtTheTopOfTheAlphabet() {
        // "zzz" with no upper bound has no single character above it, so the generator has to
        // grow the key rather than loop forever looking for one.
        let key = OrderKey.between("zzz", nil)
        XCTAssertTrue(key > "zzz")
    }

    func testInitialKeysAreAscending() {
        let keys = OrderKey.initialKeys(count: 25)
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    // MARK: - Stamps

    func testEqualStampsAreNotNewer() {
        let a = EditStamp(editedAt: Date(timeIntervalSince1970: 100), editedBy: phone)
        XCTAssertFalse(a.isNewerThan(a), "equal stamps must not win, or merging never converges")
    }

    func testIdenticalInstantsBreakTiesDeterministically() {
        let instant = Date(timeIntervalSince1970: 100)
        let a = EditStamp(editedAt: instant, editedBy: "aaa")
        let b = EditStamp(editedAt: instant, editedBy: "bbb")
        XCTAssertTrue(b.isNewerThan(a))
        XCTAssertFalse(a.isNewerThan(b), "exactly one side must win, on both devices")
    }

    // MARK: - Which device to resume from

    private func checkpoint(playing: Bool, desktop: Bool, updatedAt: TimeInterval) -> NowPlayingCheckpoint {
        NowPlayingCheckpoint(
            peerId: desktop ? mac : phone,
            isDesktop: desktop,
            updatedAt: Date().addingTimeInterval(updatedAt),
            currentTrack: track("x"),
            progress: 10,
            isPlaying: playing,
            manualQueue: [],
            contextQueue: [],
            orderedContextQueue: [],
            isShuffling: false,
            queueContextTitle: nil,
            contextSeed: nil
        )
    }

    func testTheDeviceActuallyPlayingWinsEvenIfItWroteEarlier() {
        let playingMac = checkpoint(playing: true, desktop: true, updatedAt: -60)
        let pausedPhone = checkpoint(playing: false, desktop: false, updatedAt: -1)
        XCTAssertEqual(NowPlayingCheckpoint.preferred(playingMac, pausedPhone), playingMac)
        XCTAssertEqual(NowPlayingCheckpoint.preferred(pausedPhone, playingMac), playingMac)
    }

    func testDesktopBreaksTheTieWhenBothArePlaying() {
        let mac = checkpoint(playing: true, desktop: true, updatedAt: -60)
        let phone = checkpoint(playing: true, desktop: false, updatedAt: -1)
        XCTAssertEqual(NowPlayingCheckpoint.preferred(phone, mac), mac)
    }

    func testNewestWinsWhenNeitherIsPlaying() {
        let older = checkpoint(playing: false, desktop: true, updatedAt: -60)
        let newer = checkpoint(playing: false, desktop: false, updatedAt: -1)
        XCTAssertEqual(NowPlayingCheckpoint.preferred(older, newer), newer)
    }

    // MARK: - Pairing proof

    func testProofVerifiesOnlyWithTheRightCode() {
        let key = Data("public-key-bytes".utf8)
        let proof = PairingProof.make(code: "123456", publicKey: key, peerId: phone, responding: false)

        XCTAssertTrue(PairingProof.verify(proof, code: "123456", publicKey: key, peerId: phone, responding: false))
        XCTAssertFalse(PairingProof.verify(proof, code: "123457", publicKey: key, peerId: phone, responding: false))
        // A request proof must not pass as a response proof, or a peer could replay one back.
        XCTAssertFalse(PairingProof.verify(proof, code: "123456", publicKey: key, peerId: phone, responding: true))
        // Swapping the key in is exactly the man-in-the-middle this is here to stop.
        XCTAssertFalse(PairingProof.verify(proof, code: "123456", publicKey: Data("other".utf8), peerId: phone, responding: false))
    }
}
