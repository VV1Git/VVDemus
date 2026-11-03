import XCTest
@testable import VVDemus

/// Named mix radios crossing between linked devices, through the pure `MixRadio.merging` so no
/// singleton or `UserDefaults` is touched.
final class MixRadioSyncTests: XCTestCase {

    private func stamp(_ seconds: TimeInterval, _ by: String = "mac") -> EditStamp {
        EditStamp(editedAt: Date(timeIntervalSince1970: seconds), editedBy: by)
    }

    private func mix(_ id: UUID, _ name: String, seeds: [String] = ["a"], at seconds: TimeInterval,
                     by: String = "mac", deleted: Bool = false) -> MixRadio {
        MixRadio(id: id, name: name, seeds: Fixtures.tracks(seeds), removed: [],
                 createdAt: Date(timeIntervalSince1970: 0),
                 deletedAt: deleted ? Date(timeIntervalSince1970: seconds) : nil,
                 stamp: stamp(seconds, by))
    }

    func testAMixFromAnotherDeviceArrives() {
        let incoming = mix(UUID(), "Gym", at: 100, by: "phone")
        let merged = MixRadio.merging([], [incoming])
        XCTAssertEqual(merged.changed, 1)
        XCTAssertEqual(merged.mixes, [incoming])
    }

    /// Each mix merges on its own: an edit to one never costs another device's edit to another.
    func testDifferentMixesEditedOnDifferentDevicesBothSurvive() {
        let gym = UUID(), chill = UUID()
        let local = [mix(gym, "Gym", seeds: ["a", "b"], at: 200), mix(chill, "Chill", at: 100)]
        let incoming = [mix(gym, "Gym", at: 100, by: "phone"),
                        mix(chill, "Chill", seeds: ["c"], at: 300, by: "phone")]
        let merged = MixRadio.merging(local, incoming)
        XCTAssertEqual(merged.mixes.first { $0.id == gym }?.seeds.map(\.videoId), ["a", "b"])
        XCTAssertEqual(merged.mixes.first { $0.id == chill }?.seeds.map(\.videoId), ["c"])
    }

    func testTheNewerEditToOneMixWins() {
        let id = UUID()
        let merged = MixRadio.merging([mix(id, "Old", at: 100)], [mix(id, "New", at: 200, by: "phone")])
        XCTAssertEqual(merged.mixes.first?.name, "New")
    }

    func testAnOlderEditDoesNotOverwriteANewerOne() {
        let id = UUID()
        let merged = MixRadio.merging([mix(id, "New", at: 200)], [mix(id, "Old", at: 100, by: "phone")])
        XCTAssertEqual(merged.changed, 0)
        XCTAssertEqual(merged.mixes.first?.name, "New")
    }

    /// A delete has to reach the other device, not be handed straight back by it.
    func testADeleteIsAnEditThatWins() {
        let id = UUID()
        let merged = MixRadio.merging([mix(id, "Gym", at: 100)], [mix(id, "Gym", at: 200, by: "phone", deleted: true)])
        XCTAssertFalse(merged.mixes[0].isPresent)
    }

    func testReceivingTheSameMixTwiceIsANoOp() {
        let m = mix(UUID(), "Gym", at: 100)
        XCTAssertEqual(MixRadio.merging([m], [m]).changed, 0)
    }

    /// The device that made an edit builds its station; the others wait for it to arrive.
    func testOnlyTheEditingDeviceBuildsStraightAway() async {
        let now = Date()
        let mine = MixRadio(id: UUID(), name: "M", seeds: [], removed: [], createdAt: now, deletedAt: nil,
                            stamp: EditStamp(editedAt: now, editedBy: PeerIdentityBox.currentPeerId))
        var theirs = mine
        theirs.stamp.editedBy = PeerIdentityBox.currentPeerId + "-other"
        await MainActor.run {
            let builder = MixStationBuilder.shared
            XCTAssertTrue(builder.shouldBuildHere(mine, now: now))
            XCTAssertFalse(builder.shouldBuildHere(theirs, now: now))
            XCTAssertTrue(builder.shouldBuildHere(theirs, now: now.addingTimeInterval(MixStationBuilder.peerGrace + 1)),
                          "after a while it builds anyway, in case the other device never does")
        }
    }

    /// A peer on a build from before mix radio synced sends no mix key at all.
    func testPayloadFromAnOlderBuildStillDecodes() throws {
        let json = """
        {"peerId":"p","likes":[],"playlists":[],"radios":[],"generated":[],"recentSearches":[],"events":[]}
        """
        let payload = try JSONDecoder().decode(SyncPayload.self, from: Data(json.utf8))
        XCTAssertNil(payload.mixes)
    }

    /// A peer on the build with a single unnamed tray still sends it; that has to decode too.
    func testPayloadWithTheOldSingleTrayStillDecodes() throws {
        let json = """
        {"peerId":"p","likes":[],"playlists":[],"radios":[],"generated":[],"recentSearches":[],"events":[],
         "mixRadio":{"seeds":[],"stamp":{"editedAt":0,"editedBy":"x"}}}
        """
        let payload = try JSONDecoder().decode(SyncPayload.self, from: Data(json.utf8))
        XCTAssertNotNil(payload.mixRadio)
        XCTAssertNil(payload.mixes)
    }
}
