import XCTest
@testable import VVDemus

/// The mix radio picks crossing to the paired device, through the pure `MixRadioRecord.merging`
/// so no singleton or `UserDefaults` is touched.
final class MixRadioSyncTests: XCTestCase {

    private func track(_ id: String) -> Track {
        Track(videoId: id, title: id, artist: "A", album: nil, thumbnailUrl: nil, durationSeconds: nil)
    }

    private func stamp(_ seconds: TimeInterval, _ by: String = "mac") -> EditStamp {
        EditStamp(editedAt: Date(timeIntervalSince1970: seconds), editedBy: by)
    }

    func testNewerPicksReplaceOlderOnes() {
        let local = MixRadioRecord(seeds: [track("a")], stamp: stamp(100))
        let incoming = MixRadioRecord(seeds: [track("b"), track("c")], stamp: stamp(200, "phone"))
        let merged = MixRadioRecord.merging(local, incoming)
        XCTAssertTrue(merged.changed)
        XCTAssertEqual(merged.record.seeds.map(\.videoId), ["b", "c"])
    }

    func testOlderPicksDoNotOverwriteNewerOnes() {
        let local = MixRadioRecord(seeds: [track("a")], stamp: stamp(200))
        let incoming = MixRadioRecord(seeds: [track("b")], stamp: stamp(100, "phone"))
        let merged = MixRadioRecord.merging(local, incoming)
        XCTAssertFalse(merged.changed)
        XCTAssertEqual(merged.record.seeds.map(\.videoId), ["a"])
    }

    /// Clearing on one device has to reach the other, not be handed straight back by it.
    func testAClearIsAnEditThatWins() {
        let local = MixRadioRecord(seeds: [track("a"), track("b")], stamp: stamp(100))
        let cleared = MixRadioRecord(seeds: [], stamp: stamp(200, "phone"))
        XCTAssertEqual(MixRadioRecord.merging(local, cleared).record.seeds, [])
    }

    /// A device that never touched its tray must take the peer's picks.
    func testAnUntouchedTrayTakesThePeersPicks() {
        let untouched = MixRadioRecord(seeds: [], stamp: EditStamp(editedAt: .distantPast, editedBy: "mac"))
        let incoming = MixRadioRecord(seeds: [track("a")], stamp: stamp(100, "phone"))
        XCTAssertEqual(MixRadioRecord.merging(untouched, incoming).record.seeds.map(\.videoId), ["a"])
    }

    func testReceivingTheSameRecordTwiceIsANoOp() {
        let record = MixRadioRecord(seeds: [track("a")], stamp: stamp(100))
        XCTAssertFalse(MixRadioRecord.merging(record, record).changed)
    }

    /// A peer on a build from before mix radio synced sends no `mixRadio` key at all.
    func testPayloadFromAnOlderBuildStillDecodes() throws {
        let json = """
        {"peerId":"p","likes":[],"playlists":[],"radios":[],"generated":[],"recentSearches":[],"events":[]}
        """
        let payload = try JSONDecoder().decode(SyncPayload.self, from: Data(json.utf8))
        XCTAssertNil(payload.mixRadio)
    }
}
