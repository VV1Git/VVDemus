import XCTest
@testable import VVDemus

/// Drives the real embedded HTTP server over a real socket, the way a browser does.
///
/// These run against `LocalControlServer.shared` and therefore `PlayerService.shared`, so
/// they deliberately stay on endpoints that don't need the network: state, queue
/// manipulation, device selection, and how malformed input is handled. That is where the
/// bugs that break the remote actually live.
@MainActor
final class LocalControlServerTests: XCTestCase {
    private var server: LocalControlServer { LocalControlServer.shared }
    private var baseURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        if !server.isRunning {
            // A high, unlikely-to-clash port so a copy of the app running in this
            // simulator doesn't make the suite fail for the wrong reason.
            server.port = 52831
            server.start()
        }
        try XCTSkipUnless(server.isRunning, "control server could not bind port \(server.port): \(server.startupError ?? "unknown")")
        baseURL = URL(string: "http://127.0.0.1:\(server.port)")!
    }

    override func tearDown() async throws {
        PlayerService.shared.setActiveDevice(.iphone)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private struct Response {
        let status: Int
        let body: Data

        var text: String { String(data: body, encoding: .utf8) ?? "" }

        func json<T: Decodable>(_ type: T.Type) throws -> T {
            try JSONDecoder().decode(type, from: body)
        }
    }

    private func request(
        _ method: String,
        _ path: String,
        body: Data? = nil,
        timeout: TimeInterval = 10
    ) async throws -> Response {
        // Built by string, not `appendingPathComponent` — that percent-encodes the "?" and
        // turns a query into part of the path.
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw XCTSkip("could not build URL for \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return Response(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data)
    }

    private func post(_ path: String, _ object: Any) async throws -> Response {
        try await request("POST", path, body: try JSONSerialization.data(withJSONObject: object))
    }

    private func postRaw(_ path: String, _ raw: String) async throws -> Response {
        try await request("POST", path, body: Data(raw.utf8))
    }

    private func trackJSON(_ id: String) -> [String: Any] {
        [
            "videoId": id,
            "title": "Track \(id)",
            "artist": "Test Artist",
            "album": NSNull(),
            "thumbnailUrl": NSNull(),
            "durationSeconds": 180,
        ]
    }

    // MARK: - State

    func testStateEndpointReturnsAFullSnapshot() async throws {
        let response = try await request("GET", "/api/state")
        XCTAssertEqual(response.status, 200)

        let snapshot = try response.json(StateSnapshot.self)
        // A `/api/state` response always carries the queues; only socket broadcasts trim
        // them, where "absent" means "unchanged".
        XCTAssertNotNil(snapshot.manualQueue)
        XCTAssertNotNil(snapshot.contextQueue)
        XCTAssertNotNil(snapshot.likedVideoIds)
    }

    func testStateIsValidJsonEvenWithNothingPlaying() async throws {
        let snapshot = try await request("GET", "/api/state").json(StateSnapshot.self)
        XCTAssertEqual(snapshot.activeDevice, .iphone)
        XCTAssertGreaterThanOrEqual(snapshot.playbackEpoch, 0)
    }

    // MARK: - Queue over HTTP

    func testQueuingATrackFromTheBrowserShowsUpInState() async throws {
        let id = "queued-\(UUID().uuidString.prefix(6))"
        let response = try await post("/api/queue/add", ["track": trackJSON(id)])
        XCTAssertEqual(response.status, 200)

        let snapshot = try await request("GET", "/api/state").json(StateSnapshot.self)
        XCTAssertTrue(snapshot.manualQueue?.contains { $0.videoId == id } == true)

        _ = try await post("/api/queue/remove", ["track": trackJSON(id)])
        let after = try await request("GET", "/api/state").json(StateSnapshot.self)
        XCTAssertFalse(after.manualQueue?.contains { $0.videoId == id } == true)
    }

    func testPlayNextPutsATrackAtTheFrontOfTheQueue() async throws {
        let first = "first-\(UUID().uuidString.prefix(6))"
        let jumped = "jumped-\(UUID().uuidString.prefix(6))"
        _ = try await post("/api/queue/add", ["track": trackJSON(first)])
        _ = try await post("/api/queue/play-next", ["track": trackJSON(jumped)])

        let snapshot = try await request("GET", "/api/state").json(StateSnapshot.self)
        XCTAssertEqual(snapshot.manualQueue?.first?.videoId, jumped)

        _ = try await post("/api/queue/remove", ["track": trackJSON(first)])
        _ = try await post("/api/queue/remove", ["track": trackJSON(jumped)])
    }

    // MARK: - Device selection

    /// Claiming "computer" with no tab id is a guaranteed dead end: no tab would ever
    /// match, so nothing plays and nothing reports, and the liveness check silently pulls
    /// playback back to the phone seconds later.
    func testCastingWithoutAClientIdIsRejected() async throws {
        let response = try await post("/api/device", ["device": "computer"])
        XCTAssertEqual(response.status, 400)

        let snapshot = try await request("GET", "/api/state").json(StateSnapshot.self)
        XCTAssertEqual(snapshot.activeDevice, .iphone, "A rejected request must not have changed anything")
    }

    func testCastingWithAClientIdIsAccepted() async throws {
        let response = try await post("/api/device", ["device": "computer", "clientId": "tab-1"])
        XCTAssertEqual(response.status, 200)

        let snapshot = try await request("GET", "/api/state").json(StateSnapshot.self)
        XCTAssertEqual(snapshot.activeDevice, .computer)
        XCTAssertEqual(snapshot.castClientId, "tab-1")

        _ = try await post("/api/device", ["device": "iphone"])
    }

    func testSwitchingBackToThePhoneClearsTheCastClient() async throws {
        _ = try await post("/api/device", ["device": "computer", "clientId": "tab-1"])
        _ = try await post("/api/device", ["device": "iphone"])

        let snapshot = try await request("GET", "/api/state").json(StateSnapshot.self)
        XCTAssertEqual(snapshot.activeDevice, .iphone)
        XCTAssertNil(snapshot.castClientId)
        XCTAssertNil(snapshot.streamUrl, "Nothing should be left for a browser to play")
    }

    func testAnUnknownDeviceNameIsRejected() async throws {
        let response = try await post("/api/device", ["device": "toaster", "clientId": "tab-1"])
        XCTAssertEqual(response.status, 400)
    }

    // MARK: - Malformed input

    func testMalformedJsonIsRejectedRatherThanCrashing() async throws {
        for path in ["/api/play", "/api/seek", "/api/queue/add", "/api/device", "/api/playback/report"] {
            let response = try await postRaw(path, "{ this is not json")
            XCTAssertEqual(response.status, 400, "\(path) should reject malformed JSON")
        }
        // Still alive afterwards.
        let state = try await request("GET", "/api/state")
        XCTAssertEqual(state.status, 200)
    }

    func testMissingFieldsAreRejected() async throws {
        let seek = try await post("/api/seek", [:])
        let add = try await post("/api/queue/add", [:])
        let play = try await post("/api/play", ["track": ["videoId": "x"]])
        XCTAssertEqual(seek.status, 400)
        XCTAssertEqual(add.status, 400)
        XCTAssertEqual(play.status, 400)
    }

    func testAnEmptyBodyIsRejected() async throws {
        let response = try await postRaw("/api/seek", "")
        XCTAssertEqual(response.status, 400)
    }

    func testUnknownPathsReturn404() async throws {
        let response = try await request("GET", "/api/definitely-not-a-route")
        XCTAssertEqual(response.status, 404)
    }

    func testAnEmptySearchReturnsAnEmptyListWithoutHittingTheNetwork() async throws {
        let response = try await request("GET", "/api/search?q=")
        XCTAssertEqual(response.status, 200)
        let tracks = try response.json([Track].self)
        XCTAssertEqual(tracks.count, 0)
    }

    func testRadioWithoutAVideoIdIsRejected() async throws {
        let response = try await request("GET", "/api/radio?videoId=")
        XCTAssertEqual(response.status, 400)
    }

    // MARK: - Library

    func testLikedSongsRoundTripThroughTheServer() async throws {
        let id = "liked-\(UUID().uuidString.prefix(6))"
        _ = try await post("/api/library/liked/toggle", ["track": trackJSON(id)])

        let liked = try await request("GET", "/api/library/liked").json([Track].self)
        XCTAssertTrue(liked.contains { $0.videoId == id })

        _ = try await post("/api/library/liked/toggle", ["track": trackJSON(id)])
        let after = try await request("GET", "/api/library/liked").json([Track].self)
        XCTAssertFalse(after.contains { $0.videoId == id })
    }

    func testCreatingAPlaylistWithABlankNameIsRejected() async throws {
        let response = try await post("/api/library/playlists/create", ["name": "   "])
        XCTAssertEqual(response.status, 400)
    }

    func testDownloadsListIsServable() async throws {
        let response = try await request("GET", "/api/library/downloads")
        XCTAssertEqual(response.status, 200)
        XCTAssertNoThrow(try JSONDecoder().decode([Track].self, from: response.body))
    }

    // MARK: - Static assets

    func testTheWebUiIsServed() async throws {
        for path in ["/", "/app.js", "/style.css"] {
            let response = try await request("GET", path)
            XCTAssertEqual(response.status, 200, "\(path) should be served")
            XCTAssertFalse(response.body.isEmpty, "\(path) should not be empty")
        }
    }

    // MARK: - Concurrency

    /// Every handler bridges onto the main actor. A burst of overlapping requests is the
    /// normal case (a browser fires several on every click) and must not deadlock.
    func testOverlappingRequestsAllComplete() async throws {
        let results = await withTaskGroup(of: Int.self) { group -> [Int] in
            for _ in 0..<20 {
                group.addTask { @MainActor in
                    (try? await self.request("GET", "/api/state").status) ?? -1
                }
            }
            var statuses: [Int] = []
            for await status in group { statuses.append(status) }
            return statuses
        }

        XCTAssertEqual(results.count, 20)
        XCTAssertTrue(results.allSatisfy { $0 == 200 }, "Some requests failed or timed out: \(results)")
    }

    /// Reports arriving for a device that isn't casting are dropped, not applied — and
    /// must not error.
    func testReportsForANonCastingDeviceAreAcceptedAndIgnored() async throws {
        let response = try await post("/api/playback/report", [
            "progress": 42.0,
            "duration": 180.0,
            "isPlaying": true,
            "videoId": "whatever",
            "epoch": 999,
        ])
        XCTAssertEqual(response.status, 200)

        let snapshot = try await request("GET", "/api/state").json(StateSnapshot.self)
        XCTAssertEqual(snapshot.progress, 0, accuracy: 0.001)
    }
}
