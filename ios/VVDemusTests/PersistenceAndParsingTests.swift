import XCTest
@testable import VVDemus

/// The storage and parsing layers, where the failures are quiet: data silently discarded,
/// a cache that never hits, a crash on a value nobody expected.
final class PersistenceAndParsingTests: XCTestCase {

    // MARK: - Unreadable stored data

    /// A decode failure used to leave the store empty, and the *next* mutation saved that
    /// empty array over the still-intact blob — liked songs, playlists, a year of stats,
    /// gone with no error and no way back.
    func testUnreadableDataIsPreservedRatherThanOverwritten() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "vvdemus.tests.\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().isEmpty ? "" : "") }
        let key = "liked_songs_v1"
        let original = Data("this is not the JSON you are looking for".utf8)
        defaults.set(original, forKey: key)

        let outcome = DefaultsSnapshot.read([Track].self, forKey: key, from: defaults)

        XCTAssertTrue(outcome.isCorrupt, "Corrupt must be distinguishable from missing — a store that "
                      + "can't tell them apart starts empty and saves that over the good data")
        XCTAssertNil(outcome.value)
        let backups = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(key + DefaultsSnapshot.corruptSuffix) }
        XCTAssertEqual(backups.count, 1, "The original bytes have to survive so they can be recovered")
        XCTAssertEqual(defaults.data(forKey: backups.first ?? ""), original)
    }

    func testReadableDataRoundTrips() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "vvdemus.tests.\(UUID().uuidString)"))
        let tracks = [
            Track(videoId: "a", title: "A", artist: "Artist", album: nil, thumbnailUrl: nil, durationSeconds: 100),
        ]
        DefaultsSnapshot.save(tracks, forKey: "k", to: defaults)

        XCTAssertEqual(DefaultsSnapshot.load([Track].self, forKey: "k", from: defaults), tracks)
        XCTAssertNil(defaults.data(forKey: "k" + DefaultsSnapshot.corruptSuffix))
    }

    func testMissingKeyIsNotTreatedAsCorruption() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "vvdemus.tests.\(UUID().uuidString)"))
        let outcome = DefaultsSnapshot.read([Track].self, forKey: "never-written", from: defaults)
        XCTAssertFalse(outcome.isCorrupt, "Nothing written is not the same as something broken")
        XCTAssertNil(outcome.value)
    }

    /// A second schema change must not overwrite the backup taken during the first — that
    /// would destroy the last good copy.
    func testASecondCorruptionKeepsTheFirstBackup() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "vvdemus.tests.\(UUID().uuidString)"))
        let key = "k"
        defaults.set(Data("first good blob".utf8), forKey: key)
        _ = DefaultsSnapshot.read([Track].self, forKey: key, from: defaults)
        defaults.set(Data("degraded".utf8), forKey: key)
        _ = DefaultsSnapshot.read([Track].self, forKey: key, from: defaults)

        let backups = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(key + DefaultsSnapshot.corruptSuffix) }
        XCTAssertEqual(backups.count, 2, "Each corruption gets its own backup")
        XCTAssertTrue(backups.contains { defaults.data(forKey: $0) == Data("first good blob".utf8) })
    }

    // MARK: - Disk image cache

    /// Filenames were derived from `String.hashValue`, which is salted per process — so
    /// the same URL mapped to a different file on every launch. Nothing ever hit, every
    /// thumbnail was re-downloaded, and each launch left behind another full copy.
    func testCacheKeysAreStableAcrossProcesses() async {
        let key = "https://example.com/artwork.jpg?size=300"
        let payload = Data("pretend this is a jpeg".utf8)

        await DiskImageCache.shared.store(payload, for: key)
        let readBack = await DiskImageCache.shared.data(for: key)

        XCTAssertEqual(readBack, payload)
        // A second, independently computed lookup of the same key must find the same file —
        // which is exactly what a relaunch does.
        let relookup = await DiskImageCache.shared.data(for: "https://example.com/artwork.jpg?size=300")
        XCTAssertEqual(relookup, payload)
    }

    func testDifferentKeysDoNotCollide() async {
        await DiskImageCache.shared.store(Data("small".utf8), for: "https://example.com/a.jpg?size=64")
        await DiskImageCache.shared.store(Data("large".utf8), for: "https://example.com/a.jpg?size=600")

        let small = await DiskImageCache.shared.data(for: "https://example.com/a.jpg?size=64")
        let large = await DiskImageCache.shared.data(for: "https://example.com/a.jpg?size=600")
        XCTAssertEqual(small, Data("small".utf8))
        XCTAssertEqual(large, Data("large".utf8))
    }

    func testEmptyDataIsNotCached() async {
        await DiskImageCache.shared.store(Data(), for: "empty-key")
        let stored = await DiskImageCache.shared.data(for: "empty-key")
        XCTAssertNil(stored)
    }

    // MARK: - Downloads

    /// `URLSessionDownloadTask` reports success for *any* completed response, including a
    /// 403 whose body is a few hundred bytes of XML. That used to be saved as the track's
    /// audio: marked downloaded, played from disk, failed every time, forever.
    func testErrorResponsesAreNotAcceptedAsAudio() {
        let url = URL(string: "https://example.com/audio.m4a")!
        func response(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        }

        XCTAssertFalse(DownloadManager.isAcceptableDownload(response: response(403), fileSize: 400))
        XCTAssertFalse(DownloadManager.isAcceptableDownload(response: response(404), fileSize: 5_000_000))
        XCTAssertFalse(DownloadManager.isAcceptableDownload(response: response(500), fileSize: 5_000_000))
        XCTAssertFalse(DownloadManager.isAcceptableDownload(response: nil, fileSize: 5_000_000))
    }

    func testATruncatedFileIsNotAcceptedAsAudio() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/audio.m4a")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        XCTAssertFalse(DownloadManager.isAcceptableDownload(response: response, fileSize: 300))
        XCTAssertTrue(DownloadManager.isAcceptableDownload(response: response, fileSize: 4_000_000))
    }

    func testFileExtensionFollowsTheContentType() {
        func response(_ mime: String) -> HTTPURLResponse {
            HTTPURLResponse(
                url: URL(string: "https://example.com/a")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": mime]
            )!
        }
        XCTAssertEqual(DownloadManager.fileExtension(for: response("audio/mp4")), "m4a")
        XCTAssertEqual(DownloadManager.fileExtension(for: response("video/mp4")), "mp4")
        XCTAssertEqual(DownloadManager.fileExtension(for: nil), "mp4")
    }

    // MARK: - Stream URL expiry

    /// The expiry used to be invented (`now + 5 hours`) rather than read from the URL, so
    /// `APIClient` kept serving URLs that had been dead for hours.
    func testExpiryIsReadFromTheUrl() {
        let expiry: Double = 1_800_000_000
        let url = "https://rr1.googlevideo.com/videoplayback?expire=\(Int(expiry))&itag=140"

        XCTAssertEqual(InnerTubeClient.expiry(for: url), expiry, accuracy: 0.001)
    }

    func testAUrlWithNoExpiryFallsBackToAConservativeGuess() {
        let expiry = InnerTubeClient.expiry(for: "https://example.com/audio.m4a")
        XCTAssertGreaterThan(expiry, Date().timeIntervalSince1970)
    }

    func testAMalformedExpiryDoesNotProduceANonsenseDate() {
        let expiry = InnerTubeClient.expiry(for: "https://example.com/a?expire=not-a-number")
        XCTAssertGreaterThan(expiry, Date().timeIntervalSince1970)
    }

    // MARK: - Client version

    /// `DateFormatter` defaults to the device's locale, so on a Buddhist or Imperial
    /// calendar every request went out claiming client version "1.25690729.01.00".
    func testClientVersionIsGregorianRegardlessOfDeviceLocale() {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 29
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC")!
        let date = gregorian.date(from: components)!

        XCTAssertEqual(InnerTubeClient.clientVersion(for: date), "1.20260729.01.00")
    }

    func testClientVersionIsAlwaysWellFormed() {
        let version = InnerTubeClient.clientVersion(for: Date())
        XCTAssertEqual(version.split(separator: ".").count, 4)
        let datePart = version.split(separator: ".")[1]
        XCTAssertEqual(datePart.count, 8)
        XCTAssertTrue(datePart.allSatisfy(\.isNumber))
    }

    // MARK: - Error classification

    /// A 403 on a stream URL means "expired"; a 500 means the service is unwell. They used
    /// to collapse into the same opaque message, which made the two indistinguishable in
    /// logs.
    func testHttpErrorsCarryTheirStatusCode() {
        XCTAssertTrue(APIError.http(status: 403).localizedDescription.contains("403"))
        XCTAssertTrue(APIError.http(status: 503).localizedDescription.contains("503"))
    }

    // MARK: - Track model

    func testLongFormCompilationsAreRecognised() {
        XCTAssertTrue(Fixtures.track("x", durationSeconds: 3 * 3600).isLongFormMix)
        XCTAssertTrue(Fixtures.track("x", durationSeconds: 21 * 60).isLongFormMix)
        XCTAssertFalse(Fixtures.track("x", durationSeconds: 17 * 60).isLongFormMix, "Echoes is 17 minutes and is a real song")
        XCTAssertFalse(Fixtures.track("x", durationSeconds: nil).isLongFormMix, "Unknown length gets the benefit of the doubt")
    }

    func testFilteringKeepsOrderAndDropsOnlyCompilations() {
        let tracks = [
            Fixtures.track("a", durationSeconds: 200),
            Fixtures.track("mix", durationSeconds: 5000),
            Fixtures.track("b", durationSeconds: 240),
        ]
        XCTAssertEqual(tracks.excludingLongFormMixes().map(\.videoId), ["a", "b"])
    }

    // MARK: - JSON helper

    func testJsonSubscriptsAreBoundsSafe() throws {
        let json = try JSON.parse(Data(#"{"a": {"b": [1, 2, 3]}}"#.utf8))

        XCTAssertEqual(json["a"]["b"][0].int, 1)
        XCTAssertNil(json["a"]["b"][99].int, "An out-of-range index must not trap")
        XCTAssertNil(json["nope"]["deeper"].string)
        XCTAssertFalse(json["nope"].exists)
        XCTAssertTrue(json["a"].exists)
    }

    func testJsonParsingRejectsGarbage() {
        XCTAssertThrowsError(try JSON.parse(Data("not json".utf8)))
    }
}
