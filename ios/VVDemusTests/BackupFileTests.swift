import XCTest
@testable import VVDemus

/// The backup file format, exercised as bytes — a payload in, JSON out, a payload back.
///
/// No stores, no singletons, no `UserDefaults`, no file picker and no disk, because `BackupCodec`
/// was factored to have none of those: the promise the feature makes is that a library survives a
/// round trip, and that promise is only worth anything if it is provable without a wiped device
/// to restore onto.
///
/// Every fixture date is a whole second. The codec is `.iso8601` on both sides, which is
/// second-resolution and silently drops sub-second fractions — a fixture built from `Date()`
/// would fail every equality assertion here for a reason that has nothing to do with the format.
/// `HandoffHandshakeTests.testTheWireCarriesTheCheckpointTimestampOnlyToTheSecond` pins that
/// property of the peer coder directly. The one deliberate exception is
/// `testAPlayLoggedLocallyComesBackFromAFileAsTheSamePlay`, which exists precisely because a
/// locally logged `PlayEvent` does carry a fraction and the log is deduped on it.
final class BackupFileTests: XCTestCase {
    private let phone = "phone-peer"
    private let mac = "mac-peer"

    /// A fixed instant rather than "now", per the note on the class.
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func date(_ offset: TimeInterval) -> Date {
        epoch.addingTimeInterval(offset)
    }

    private func track(_ id: String) -> Track {
        Track(videoId: id, title: "Track \(id)", artist: "Artist", album: nil, thumbnailUrl: nil, durationSeconds: 100)
    }

    private func stamp(_ peer: String, _ offset: TimeInterval) -> EditStamp {
        EditStamp(editedAt: date(offset), editedBy: peer)
    }

    private func entry(_ id: String, order: String, peer: String, at offset: TimeInterval, removed: Bool = false) -> PlaylistEntry {
        PlaylistEntry(
            track: track(id),
            addedAt: date(offset),
            removedAt: removed ? date(offset + 1) : nil,
            order: order,
            stamp: stamp(peer, offset)
        )
    }

    private func playlist(_ entries: [PlaylistEntry], name: String = "Chill", nameAt: TimeInterval = -100, by peer: String = "phone-peer") -> PlaylistRecord {
        PlaylistRecord(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: name,
            nameStamp: stamp(peer, nameAt),
            createdAt: date(-1000),
            removedAt: nil,
            entries: entries
        )
    }

    /// One of each thing that syncs, so the round trip covers the whole payload rather than the
    /// two stores that happen to be easiest to build. The playlist deliberately carries both a
    /// present entry and a tombstone, with order keys that are adjacent in the fractional space —
    /// `"g"` and `"gn"` is exactly the shape a reorder produces, and a coder that normalised
    /// either one would still round-trip a list of songs while merging it into the wrong order.
    private func samplePayload() -> SyncPayload {
        SyncPayload(
            peerId: phone,
            likes: [
                LikeRecord(track: track("liked"), likedAt: date(-800), removedAt: nil, stamp: stamp(phone, -800)),
                LikeRecord(track: track("unliked"), likedAt: date(-900), removedAt: date(-700), stamp: stamp(mac, -700))
            ],
            playlists: [
                playlist([
                    entry("present", order: "g", peer: phone, at: -500),
                    entry("removed", order: "gn", peer: mac, at: -400, removed: true)
                ])
            ],
            radios: [
                RadioRecord(seedTrack: track("seed"), lastPlayedAt: date(-300), removedAt: nil, stamp: stamp(phone, -300))
            ],
            generated: [
                GeneratedRecord(
                    id: "daylist_v4",
                    payload: Data(#"{"title":"Monday afternoon","tracks":[]}"#.utf8),
                    generatedAt: date(-200),
                    stamp: stamp(phone, -200)
                )
            ],
            recentSearches: ["radiohead", "boards of canada"],
            events: [
                PlayEvent(track: track("played"), playedAt: date(-100), secondsPlayed: 42),
                PlayEvent(track: track("skipped"), playedAt: date(-50), secondsPlayed: 3)
            ],
            // Set on purpose: `snapshot` fills this in unconditionally, and the file must clear
            // it. Asserted below.
            eventsSince: date(-10)
        )
    }

    private func sampleFile(payload: SyncPayload? = nil, dataSaver: Bool = true) -> BackupFile {
        BackupFile(
            exportedAt: date(0),
            exportedBy: .init(peerId: phone, deviceName: "Nishant's iPhone"),
            appVersion: "Version 1.1 (42)",
            payload: payload ?? samplePayload(),
            preferences: .init(dataSaverEnabled: dataSaver)
        )
    }

    private func roundTrip(_ file: BackupFile) throws -> BackupFile {
        try BackupCodec.decode(try BackupCodec.encode(file))
    }

    // MARK: - Round trip

    /// The headline guarantee: everything that went in comes back out, record for record.
    ///
    /// Asserted store by store rather than on the payload as a whole because `SyncPayload` is
    /// `Codable` and not `Equatable` — every record type inside it is, though, so nothing is
    /// actually being skipped.
    func testEveryStoreSurvivesTheRoundTripUnchanged() throws {
        let original = sampleFile()
        let decoded = try roundTrip(original)

        XCTAssertEqual(decoded.format, BackupFile.formatIdentifier)
        XCTAssertEqual(decoded.version, BackupFile.currentVersion)
        XCTAssertEqual(decoded.exportedAt, original.exportedAt)
        XCTAssertEqual(decoded.exportedBy, original.exportedBy)
        XCTAssertEqual(decoded.appVersion, original.appVersion)

        XCTAssertEqual(decoded.payload.peerId, original.payload.peerId)
        XCTAssertEqual(decoded.payload.likes, original.payload.likes)
        XCTAssertEqual(decoded.payload.playlists, original.payload.playlists)
        XCTAssertEqual(decoded.payload.radios, original.payload.radios)
        XCTAssertEqual(decoded.payload.generated, original.payload.generated)
        XCTAssertEqual(decoded.payload.recentSearches, original.payload.recentSearches)

        // `PlayEvent` is `Codable` only, so the log is compared field by field.
        XCTAssertEqual(decoded.payload.events.count, original.payload.events.count)
        for (decodedEvent, originalEvent) in zip(decoded.payload.events, original.payload.events) {
            XCTAssertEqual(decodedEvent.track, originalEvent.track)
            XCTAssertEqual(decodedEvent.playedAt, originalEvent.playedAt)
            XCTAssertEqual(decodedEvent.secondsPlayed, originalEvent.secondsPlayed)
        }
    }

    /// The order keys and the tombstone specifically, because they are the two things a lossy
    /// format loses without ever failing: a backup missing them still restores a playlist with
    /// the right songs in it, and then merges that playlist into the wrong order, or resurrects a
    /// track the user deleted. Every other assertion in this file fails loudly; these two would
    /// not.
    func testOrderKeysAndTombstonesSurviveVerbatim() throws {
        let decoded = try roundTrip(sampleFile())
        let restored = try XCTUnwrap(decoded.payload.playlists.first)

        XCTAssertEqual(
            restored.entries.map(\.order),
            ["g", "gn"],
            "fractional order keys are strings the merge rules compare directly — no normalising, no renumbering"
        )
        let removed = try XCTUnwrap(restored.entries.first { $0.track.videoId == "removed" })
        XCTAssertEqual(removed.removedAt, date(-399), "a tombstone that comes back nil resurrects a deleted track")
        XCTAssertFalse(removed.isPresent)
        XCTAssertEqual(restored.orderedTracks.map(\.videoId), ["present"])

        let liked = try XCTUnwrap(decoded.payload.likes.first { $0.track.videoId == "unliked" })
        XCTAssertEqual(liked.removedAt, date(-700), "an unlike is a tombstone too, and travels the same way")
    }

    /// `eventsSince` is a live peer asking what to send back. In a file it means nothing, and a
    /// value left in it would silently narrow what some later importer accepted — so the wrapper
    /// clears it whatever the caller passed, and it is gone from the bytes.
    func testTheFileNeverCarriesAnEventsSinceCursor() throws {
        XCTAssertNotNil(samplePayload().eventsSince, "the fixture must actually set it, or this proves nothing")

        let decoded = try roundTrip(sampleFile())
        XCTAssertNil(decoded.payload.eventsSince)

        let payloadJSON = try topLevelObject(of: sampleFile())["payload"] as? [String: Any]
        XCTAssertNil(payloadJSON?["eventsSince"], "cleared, not written as null")
    }

    /// The daylist, Home feed and station caches are opaque bytes written by a
    /// default-configured coder inside their own stores, and `applySynced` decodes them with a
    /// default-configured one. They have to come back byte for byte, so this fixture is
    /// deliberately not valid UTF-8: base64 carries it, any text-shaped handling would not.
    func testGeneratedCachePayloadsSurviveByteForByte() throws {
        let bytes = Data([0x00, 0x01, 0xFF, 0xFE, 0x7B, 0x7D])
        var payload = samplePayload()
        payload.generated = [
            GeneratedRecord(id: "home_feed_v3", payload: bytes, generatedAt: date(-200), stamp: stamp(mac, -200))
        ]

        let decoded = try roundTrip(sampleFile(payload: payload))
        XCTAssertEqual(decoded.payload.generated.first?.payload, bytes)
    }

    // MARK: - Rejections

    /// A perfectly good JSON document that is simply not ours. The user picked the wrong file;
    /// nothing is damaged and saying so would send them looking for a problem that isn't there.
    func testArbitraryJSONIsNotABackup() {
        for bytes in [#"{"hello":1}"#, "[]", #"{"format":"something.else","version":1}"#] {
            XCTAssertThrowsError(try BackupCodec.decode(Data(bytes.utf8))) { error in
                XCTAssertEqual(error as? BackupError, .notABackup, "for \(bytes)")
            }
        }
    }

    /// A file from a future build. Rejected outright — a best-effort decode of a shape this
    /// version does not know would merge a half-understood library into a real one.
    func testAVersionAboveThisBuildsIsRejectedByNumber() throws {
        var file = sampleFile()
        file.version = BackupFile.currentVersion + 1
        let data = try BackupCodec.encode(file)

        XCTAssertThrowsError(try BackupCodec.decode(data)) { error in
            XCTAssertEqual(error as? BackupError, .unsupportedVersion(2))
            XCTAssertEqual(
                (error as? BackupError)?.errorDescription,
                "This backup was made by a newer version of VVDemus.",
                "the version number is the one thing the user can act on, so the sentence has to name the direction"
            )
        }
    }

    /// Bytes that do not parse at all, and bytes that parse into our envelope but stop there.
    /// Both are damage rather than a mistaken pick, and the truncation is taken from a real
    /// encoded file so the case is the one a half-written export actually produces.
    func testTruncatedAndUnparseableBytesAreCorrupt() throws {
        let full = try BackupCodec.encode(sampleFile())
        // Pretty-printed JSON chopped in the middle breaks the grammar, which is what makes this
        // damage. A truncation that happened to leave valid JSON would be `.notABackup` instead,
        // and would be telling the truth.
        let truncated = full.prefix(full.count / 2)

        XCTAssertThrowsError(try BackupCodec.decode(Data(truncated))) { error in
            XCTAssertEqual(error as? BackupError, .corrupt)
        }
        XCTAssertThrowsError(try BackupCodec.decode(Data("not json at all".utf8))) { error in
            XCTAssertEqual(error as? BackupError, .corrupt)
        }
        // Our envelope, our version, and nothing underneath it.
        let hollow = Data(#"{"format":"vvdem.backup","version":1}"#.utf8)
        XCTAssertThrowsError(try BackupCodec.decode(hollow)) { error in
            XCTAssertEqual(error as? BackupError, .corrupt, "past the envelope, anything still wrong is damage")
        }
    }

    // MARK: - Merge equivalence

    /// The point of the whole format, stated as an equality: a playlist that went through a file
    /// merges exactly as the same playlist arriving over the wire does.
    ///
    /// Divergent copies on both sides — a rename on one, a concurrent add and a delete on the
    /// other — so the comparison runs through every branch of `PlaylistRecord.merging` rather
    /// than through a record that happened to be a no-op.
    func testAPlaylistFromAFileMergesIdenticallyToOneThatNeverWasInAFile() throws {
        let shared = entry("shared", order: "g", peer: phone, at: -500)
        let local = playlist([shared, entry("local-only", order: "n", peer: phone, at: -20)])
        let incoming = playlist(
            [shared, entry("remote-only", order: "n", peer: mac, at: -10), entry("shared", order: "g", peer: mac, at: -5, removed: true)],
            name: "Renamed",
            nameAt: -5,
            by: mac
        )

        var payload = samplePayload()
        payload.playlists = [incoming]
        let restored = try XCTUnwrap(try roundTrip(sampleFile(payload: payload)).payload.playlists.first)

        let overTheWire = PlaylistRecord.merging(local, incoming)
        let throughAFile = PlaylistRecord.merging(local, restored)

        XCTAssertEqual(throughAFile.record, overTheWire.record)
        XCTAssertEqual(throughAFile.changed, overTheWire.changed)
        XCTAssertEqual(throughAFile.record.name, "Renamed")
        XCTAssertEqual(throughAFile.record.orderedTracks.map(\.videoId), ["local-only", "remote-only"])
    }

    /// Merging is idempotent for equal stamps, and the file preserves stamps exactly — so
    /// importing the same backup twice is a no-op, which is what the footer in Settings promises.
    func testImportingTheSameFileTwiceChangesNothingTheSecondTime() throws {
        let incoming = try XCTUnwrap(try roundTrip(sampleFile()).payload.playlists.first)
        let first = PlaylistRecord.merging(playlist([]), incoming)
        let second = PlaylistRecord.merging(first.record, incoming)

        XCTAssertTrue(first.changed)
        XCTAssertFalse(second.changed, "equal stamps are not newer — re-importing has to be a no-op")
        XCTAssertEqual(second.record, first.record)
    }

    /// The listening log is the one store keyed on an exact instant, and the file is the one
    /// path that hands a device its own events back unfiltered.
    ///
    /// `ListeningStatsStore.record` stamps a play with `Date()` and the local log keeps that
    /// fraction; `.iso8601` does not carry it. Peer sync never noticed, because a requester asks
    /// for events after `newestEventAt` and its own truncated echoes sort below that cursor — but
    /// `DataTransferSection` exports with `snapshot(eventsSince: nil)`, so an import replays the
    /// whole log with nothing in front of it. While the dedupe key was the exact `Date`, every
    /// event in a backup imported onto the device that wrote it — or onto a phone whose paired
    /// Mac holds its plays already truncated — missed the set and was appended a second time,
    /// permanently doubling the Stats screen's counts. `prune()` is age-based and would never
    /// have taken them back out.
    ///
    /// So the assertion is not "the file preserves the instant" — it deliberately does not, the
    /// way the wire does not — but "both spellings of the instant name the same play".
    func testAPlayLoggedLocallyComesBackFromAFileAsTheSamePlay() throws {
        let logged = PlayEvent(track: track("played"), playedAt: date(0.523), secondsPlayed: 42)
        var payload = samplePayload()
        payload.events = [logged]

        let restored = try XCTUnwrap(try roundTrip(sampleFile(payload: payload)).payload.events.first)

        XCTAssertNotEqual(restored.playedAt, logged.playedAt, "the codec is .iso8601 — this is the truncation, not a regression")
        XCTAssertEqual(
            ListeningStatsStore.dedupeKey(videoId: restored.track.videoId, playedAt: restored.playedAt),
            ListeningStatsStore.dedupeKey(videoId: logged.track.videoId, playedAt: logged.playedAt),
            "an event that came back out of a backup must not merge as a second play of itself"
        )
    }

    // MARK: - Preferences and the wrapper's surface

    func testDataSaverSurvivesInBothStates() throws {
        XCTAssertEqual(try roundTrip(sampleFile(dataSaver: true)).preferences, .init(dataSaverEnabled: true))
        XCTAssertEqual(try roundTrip(sampleFile(dataSaver: false)).preferences, .init(dataSaverEnabled: false))
    }

    /// The `CodingKey` raw value has to be a literal, so it cannot reference
    /// `InnerTubeClient.dataSaverDefaultsKey` and the compiler cannot hold the two together. If
    /// the defaults key is ever renamed, this is the thing that notices — otherwise an import
    /// would quietly write a preference nothing reads.
    func testThePreferenceKeyInTheFileIsTheDefaultsKeyItRestores() {
        XCTAssertEqual(
            BackupFile.Preferences.CodingKeys.dataSaverEnabled.rawValue,
            InnerTubeClient.dataSaverDefaultsKey
        )
    }

    /// What the file contains, asserted against the bytes rather than against the type, because
    /// the guarantee is about the format and not about today's struct. Pairing and peer identity
    /// are absent by design — two devices sharing a peer id would break `EditStamp`'s
    /// deterministic tiebreak, which is the thing that makes two copies of a playlist converge —
    /// and an exact key set is the only assertion that catches a field being *added*.
    ///
    /// The lone `@MainActor` in this file, and it buys nothing but the right to read
    /// `LocalControlServer.defaultsKey` — a static on a main-actor type. Naming that key here
    /// rather than only asserting the key set is what makes the omission read as a decision.
    @MainActor
    func testTheFileCarriesExactlyTheDocumentedKeysAndNoPairingState() throws {
        let object = try topLevelObject(of: sampleFile())

        XCTAssertEqual(
            Set(object.keys),
            ["format", "version", "exportedAt", "exportedBy", "appVersion", "payload", "preferences"]
        )
        // `exportedBy` records which device wrote the file so a user with two backups can tell
        // them apart. It is never adopted on the way in, and it carries nothing else.
        XCTAssertEqual(Set((object["exportedBy"] as? [String: Any] ?? [:]).keys), ["peerId", "deviceName"])

        // VVDemus Connect's key in particular: it opens an unauthenticated listener, so it stays
        // per-device and must not ride along in a backup.
        let preferences = try XCTUnwrap(object["preferences"] as? [String: Any])
        XCTAssertEqual(Set(preferences.keys), [InnerTubeClient.dataSaverDefaultsKey])
        XCTAssertNil(preferences[LocalControlServer.defaultsKey])
    }

    /// Inspectability is one of the reasons the format is JSON at all: a backup is a file the
    /// user keeps, and they should be able to open it in a text editor and see their playlists.
    /// Pretty-printing is what makes that true, and it is a coder setting one refactor away from
    /// being lost.
    func testTheFileIsReadableTextRatherThanOneLongLine() throws {
        let data = try BackupCodec.encode(sampleFile())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains("\n"), "pretty-printed, so the file can be read and diffed")
        XCTAssertTrue(text.contains("boards of canada"), "and the contents are legible, not encoded")
        XCTAssertTrue(text.contains("\"exportedAt\" : \"2023-11-14T"), "ISO-8601, not seconds since 2001")
    }

    // MARK: - Plumbing

    /// The encoded file as plain JSON, for the assertions that are about the format itself rather
    /// than about what decodes back out of it.
    private func topLevelObject(of file: BackupFile) throws -> [String: Any] {
        let data = try BackupCodec.encode(file)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
