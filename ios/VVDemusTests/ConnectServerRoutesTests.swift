import UIKit
import XCTest
@testable import VVDemus

/// Route-level behaviour of the embedded control server: the bounds it enforces, the
/// surface it no longer has, and the endpoint the casting browser uses to recover from a
/// dead stream URL. Driven over a real socket, the way a browser drives it.
@MainActor
final class ConnectServerRoutesTests: XCTestCase {
    private var server: LocalControlServer { LocalControlServer.shared }
    private var baseURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        if !server.isRunning {
            // High and unlikely to clash, so a copy of the app running in this simulator
            // doesn't fail the suite for the wrong reason.
            server.port = 52841
            server.start()
        }
        try XCTSkipUnless(server.isRunning, "control server could not bind port \(server.port): \(server.startupError ?? "unknown")")
        baseURL = URL(string: "http://127.0.0.1:\(server.port)")!
    }

    override func tearDown() async throws {
        server.radioMix.restoreDefault()
        server.freshStreamUrl.restoreDefault()
        server.backgroundTasks = UIApplication.shared
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

    private func request(_ method: String, _ path: String, body: Data? = nil) async throws -> Response {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw XCTSkip("could not build URL for \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
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

    private func uniqueId(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(6))"
    }

    // MARK: - Radio refresh

    /// `RadioCacheStore.store` deliberately refuses an empty mix — YouTube's radio endpoint
    /// returns one often enough, and caching it left the station permanently blank. The
    /// reply was not gated the same way, so a refresh that changed nothing anywhere still
    /// told the browser to render "Nothing here yet." over a station the phone still had.
    func testRefreshingARadioThatComesBackEmptyKeepsTheMixAlreadyCached() async throws {
        let seed = uniqueId("seed")
        let firstId = uniqueId("mix")
        server.radioMix.replace { _ in [Fixtures.track(firstId), Fixtures.track(firstId + "-b")] }
        let populated = try await post("/api/radio/refresh", ["videoId": seed])
        XCTAssertEqual(populated.status, 200)
        XCTAssertEqual(try populated.json([Track].self).count, 2)

        server.radioMix.replace { _ in [] }
        let empty = try await post("/api/radio/refresh", ["videoId": seed])

        XCTAssertEqual(empty.status, 200)
        XCTAssertEqual(
            try empty.json([Track].self).map(\.videoId),
            [firstId, firstId + "-b"],
            "An empty upstream fetch must not blank a station the phone still holds"
        )
    }

    func testRefreshingARadioWithARealMixReplacesTheCachedOne() async throws {
        let seed = uniqueId("seed")
        server.radioMix.replace { _ in [Fixtures.track("old")] }
        _ = try await post("/api/radio/refresh", ["videoId": seed])
        server.radioMix.replace { _ in [Fixtures.track("new-a"), Fixtures.track("new-b")] }

        let refreshed = try await post("/api/radio/refresh", ["videoId": seed])
        XCTAssertEqual(try refreshed.json([Track].self).map(\.videoId), ["new-a", "new-b"])
    }

    // MARK: - Bounds

    /// `maximumPlaylistNameLength` was declared and then never enforced: only "is it blank
    /// after trimming?" was checked, so a name of any size at all was persisted and
    /// re-rendered in every connected browser's sidebar.
    func testAnOverlongPlaylistNameIsRejected() async throws {
        // Unique per run: playlists persist in the simulator's defaults, so a fixed name
        // that some earlier run *did* manage to store would make this pass or fail on
        // leftover state rather than on the bound.
        let tooLong = uniqueId("x") + String(repeating: "a", count: LocalControlServer.maximumPlaylistNameLength)
        let response = try await post("/api/library/playlists/create", ["name": tooLong])
        XCTAssertEqual(response.status, 400)

        let playlists = try await request("GET", "/api/library/playlists").json([Playlist].self)
        XCTAssertFalse(playlists.contains { $0.name == tooLong }, "A rejected name must not have been stored")
    }

    func testAPlaylistNameAtTheLimitIsAccepted() async throws {
        let unique = uniqueId("b")
        let name = unique + String(repeating: "b", count: LocalControlServer.maximumPlaylistNameLength - unique.count)
        XCTAssertEqual(name.count, LocalControlServer.maximumPlaylistNameLength)
        let response = try await post("/api/library/playlists/create", ["name": name])
        XCTAssertEqual(response.status, 200)

        let playlists = try await request("GET", "/api/library/playlists").json([Playlist].self)
        XCTAssertTrue(playlists.contains { $0.name == name })
        if let created = playlists.first(where: { $0.name == name }) {
            PlaylistStore.shared.delete(created)
        }
    }

    /// The manual queue is re-encoded into the 1 Hz broadcast, so an unbounded one is a
    /// forever-growing per-second cost to every connected socket. Nothing capped it.
    func testTheManualQueueIsBoundedAcrossRepeatedAdds() async throws {
        let filler = fillManualQueueToCapacity()
        defer { drain(filler) }

        let rejected = try await post("/api/queue/add", ["track": trackJSON(uniqueId("overflow"))])
        XCTAssertEqual(rejected.status, 400)
        XCTAssertEqual(
            PlayerService.shared.manualQueue.count,
            LocalControlServer.maximumManualQueueTracks,
            "The rejected add must not have grown the queue"
        )
    }

    /// Bounding `add` alone would be decoration: `play-next` inserts into the very same
    /// list, so it is the obvious way round a cap that only guards the other door.
    func testPlayNextIsBoundedByTheSameCeiling() async throws {
        let filler = fillManualQueueToCapacity()
        defer { drain(filler) }

        let rejected = try await post("/api/queue/play-next", ["track": trackJSON(uniqueId("overflow"))])
        XCTAssertEqual(rejected.status, 400)
        XCTAssertEqual(PlayerService.shared.manualQueue.count, LocalControlServer.maximumManualQueueTracks)
    }

    func testQueuingIsStillAllowedBelowTheCeiling() async throws {
        let id = uniqueId("room")
        let accepted = try await post("/api/queue/add", ["track": trackJSON(id)])
        XCTAssertEqual(accepted.status, 200)
        XCTAssertTrue(PlayerService.shared.manualQueue.contains { $0.videoId == id })
        PlayerService.shared.removeFromQueue(Fixtures.track(id))
    }

    /// Filled directly rather than over HTTP: five hundred round trips would dominate the
    /// runtime of the suite, and the cap being tested is on the queue, not on the transport.
    private func fillManualQueueToCapacity() -> [Track] {
        var added: [Track] = []
        while PlayerService.shared.manualQueue.count < LocalControlServer.maximumManualQueueTracks {
            let track = Fixtures.track(uniqueId("filler"))
            PlayerService.shared.addToQueue(track)
            added.append(track)
        }
        return added
    }

    private func drain(_ tracks: [Track]) {
        for track in tracks { PlayerService.shared.removeFromQueue(track) }
    }

    // MARK: - Removed surface

    /// `POST /api/radio/play` had no caller anywhere — not app.js, not the iOS app, not the
    /// tests — and its 37 lines duplicated logic that `/api/play` already does properly.
    func testTheUncalledRadioPlayRouteIsGone() async throws {
        let response = try await post("/api/radio/play", ["seedTrack": trackJSON("whatever")])
        XCTAssertEqual(response.status, 404)
    }

    /// `hasPrevious` was encoded into every broadcast and read by nothing.
    func testTheStateSnapshotNoLongerCarriesHasPrevious() async throws {
        let body = try await request("GET", "/api/state").body
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(object["hasPrevious"], "Dead field still being pushed once a second")
        // Still a usable snapshot, not an empty one.
        XCTAssertNotNil(object["playbackEpoch"])
        XCTAssertNotNil(object["activeDevice"])
    }

    /// Removing the unreachable `?? request.params["id"]` fallback must not have changed
    /// how the route actually resolves its id — Swifter keys a variable node by the literal
    /// `":id"`, which is the only lookup that ever matched.
    func testAddingToAPlaylistByIdStillWorks() async throws {
        let name = uniqueId("playlist")
        _ = try await post("/api/library/playlists/create", ["name": name])
        let playlist = try XCTUnwrap(PlaylistStore.shared.playlists.first { $0.name == name })
        defer { PlaylistStore.shared.delete(playlist) }

        let trackId = uniqueId("track")
        let response = try await post("/api/library/playlists/\(playlist.id)/add", ["track": trackJSON(trackId)])
        XCTAssertEqual(response.status, 200)

        let updated = try XCTUnwrap(PlaylistStore.shared.playlists.first { $0.id == playlist.id })
        XCTAssertTrue(updated.tracks.contains { $0.videoId == trackId })
    }

    func testAddingToAPlaylistWithAnUnparseableIdIsRejected() async throws {
        let response = try await post("/api/library/playlists/not-a-uuid/add", ["track": trackJSON("x")])
        XCTAssertEqual(response.status, 400)
    }

    // MARK: - Stream failure recovery

    /// Before this endpoint existed the phone was never told that the URL it had handed the
    /// browser was dead, so it kept serving the identical URL in every snapshot and the
    /// browser retried it every five seconds forever. A 404 here is the bug.
    func testTheStreamFailedRouteExists() async throws {
        let response = try await post("/api/playback/stream-failed", ["videoId": "nothing-playing"])
        XCTAssertNotEqual(response.status, 404, "The route the browser needs to recover is missing")
        XCTAssertEqual(response.status, 409, "Nothing is casting, so there is nothing to re-resolve")
    }

    func testStreamFailedRejectsAMalformedBody() async throws {
        let response = try await request("POST", "/api/playback/stream-failed", body: Data("{ nope".utf8))
        XCTAssertEqual(response.status, 400)
    }

    /// A report about a track the phone has already moved past must not cost a re-resolve.
    func testStreamFailedForATrackThatIsNotPlayingIsRefused() async throws {
        var resolves = 0
        server.freshStreamUrl.replace { _ in resolves += 1; return "https://fresh.test/x.m4a" }
        try await beginCasting(clientId: "tab-cast", videoId: uniqueId("current"))

        let response = try await post("/api/playback/stream-failed", [
            "videoId": "some-other-track",
            "clientId": "tab-cast",
        ])

        XCTAssertEqual(response.status, 409)
        XCTAssertEqual(resolves, 0)
    }

    func testStreamFailedFromATabThatIsNotCastingIsRefused() async throws {
        var resolves = 0
        server.freshStreamUrl.replace { _ in resolves += 1; return "https://fresh.test/x.m4a" }
        let videoId = uniqueId("current")
        try await beginCasting(clientId: "tab-cast", videoId: videoId)

        let response = try await post("/api/playback/stream-failed", [
            "videoId": videoId,
            "clientId": "some-other-tab",
        ])

        XCTAssertEqual(response.status, 409)
        XCTAssertEqual(resolves, 0)
    }

    /// The whole point: a fresh URL reaches the browser, both in the reply and in the next
    /// snapshot. PlayerService's own `externalStream` still holds the dead URL — it offers
    /// no way to re-resolve the current track in place — so the server has to carry the
    /// replacement itself.
    func testStreamFailedPutsAFreshUrlIntoTheNextSnapshot() async throws {
        let videoId = uniqueId("current")
        let fresh = "https://fresh.test/\(videoId).m4a"
        var asked: [String] = []
        server.freshStreamUrl.replace { id in asked.append(id); return fresh }
        try await beginCasting(clientId: "tab-cast", videoId: videoId)

        let response = try await post("/api/playback/stream-failed", [
            "videoId": videoId,
            "clientId": "tab-cast",
        ])

        XCTAssertEqual(response.status, 200)
        let payload = try response.json(StreamFailedReply.self)
        XCTAssertEqual(payload.streamUrl, fresh)
        XCTAssertEqual(asked, [videoId], "The dead URL has to be re-resolved exactly once")

        let snapshot = try await request("GET", "/api/state").json(StateSnapshot.self)
        XCTAssertEqual(snapshot.streamUrl, fresh, "The browser would have been handed the dead URL again")
        XCTAssertEqual(snapshot.streamVideoId, videoId)
    }

    /// The re-resolved URL belongs to one track on one device. Once the phone takes
    /// playback back it must go, or a snapshot would keep offering a browser something to
    /// play at the exact moment it should be silent.
    func testTheReResolvedUrlIsDroppedWhenPlaybackReturnsToThePhone() async throws {
        let videoId = uniqueId("current")
        server.freshStreamUrl.replace { _ in "https://fresh.test/\(videoId).m4a" }
        try await beginCasting(clientId: "tab-cast", videoId: videoId)
        _ = try await post("/api/playback/stream-failed", ["videoId": videoId, "clientId": "tab-cast"])

        _ = try await post("/api/device", ["device": "iphone"])

        let snapshot = try await request("GET", "/api/state").json(StateSnapshot.self)
        XCTAssertEqual(snapshot.activeDevice, .iphone)
        XCTAssertNil(snapshot.streamUrl, "Nothing should be left for a browser to play")
    }

    /// The browser retries every five seconds; that must not become a YouTube round trip
    /// every five seconds.
    func testRepeatedStreamFailureReportsAreDebounced() async throws {
        let videoId = uniqueId("current")
        var resolves = 0
        server.freshStreamUrl.replace { _ in resolves += 1; return "https://fresh.test/\(resolves).m4a" }
        try await beginCasting(clientId: "tab-cast", videoId: videoId)

        let body: [String: Any] = ["videoId": videoId, "clientId": "tab-cast"]
        let first = try await post("/api/playback/stream-failed", body)
        let second = try await post("/api/playback/stream-failed", body)

        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(second.status, 409)
        XCTAssertEqual(resolves, 1)
    }

    private struct StreamFailedReply: Decodable {
        let videoId: String
        let streamUrl: String
    }

    // MARK: - Banking stream URLs for an outage

    /// The whole point of `/api/stream`: a casting browser can hold a usable URL for a track
    /// that hasn't started, so the phone going away mid-song doesn't end the music at the
    /// end of that song.
    ///
    /// The snapshot's `nextStreamUrl` covers exactly one transition, which survives a blip
    /// and not a phone that sleeps, drops off Wi-Fi, or gets suspended by iOS.
    func testTheCastingTabCanPreResolveAnUpcomingTrack() async throws {
        let current = uniqueId("current")
        let upcoming = uniqueId("upcoming")
        let banked = "https://banked.test/\(upcoming).m4a"
        var asked: [String] = []
        server.upcomingStreamUrl.replace { id in asked.append(id); return banked }
        try await beginCasting(clientId: "tab-cast", videoId: current)
        _ = try await post("/api/queue/add", ["track": trackJSON(upcoming)])

        let response = try await request("GET", "/api/stream?videoId=\(upcoming)&clientId=tab-cast")

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try response.json(StreamFailedReply.self).streamUrl, banked)
        XCTAssertEqual(asked, [upcoming])
    }

    /// Resolving costs an InnerTube round trip, so this is not a resolver anything on the
    /// network can point at any video id — the same reasoning that gates
    /// `/api/playback/stream-failed`.
    func testPreResolvingIsRefusedForATrackThatIsNotComingUp() async throws {
        var resolves = 0
        server.upcomingStreamUrl.replace { _ in resolves += 1; return "https://banked.test/x.m4a" }
        try await beginCasting(clientId: "tab-cast", videoId: uniqueId("current"))

        let response = try await request("GET", "/api/stream?videoId=not-in-the-queue&clientId=tab-cast")

        XCTAssertEqual(response.status, 409)
        XCTAssertEqual(resolves, 0)
    }

    func testPreResolvingIsRefusedForATabThatIsNotCasting() async throws {
        var resolves = 0
        server.upcomingStreamUrl.replace { _ in resolves += 1; return "https://banked.test/x.m4a" }
        let upcoming = uniqueId("upcoming")
        try await beginCasting(clientId: "tab-cast", videoId: uniqueId("current"))
        _ = try await post("/api/queue/add", ["track": trackJSON(upcoming)])

        let response = try await request("GET", "/api/stream?videoId=\(upcoming)&clientId=some-other-tab")

        XCTAssertEqual(response.status, 409)
        XCTAssertEqual(resolves, 0)
    }

    /// Nothing is casting, so there is no browser with any use for a banked URL.
    func testPreResolvingIsRefusedWhileThePhoneIsTheActiveDevice() async throws {
        var resolves = 0
        server.upcomingStreamUrl.replace { _ in resolves += 1; return "https://banked.test/x.m4a" }
        let upcoming = uniqueId("upcoming")
        _ = try await post("/api/queue/add", ["track": trackJSON(upcoming)])
        _ = try await post("/api/device", ["device": "iphone"])

        let response = try await request("GET", "/api/stream?videoId=\(upcoming)")

        XCTAssertEqual(response.status, 409)
        XCTAssertEqual(resolves, 0)
    }

    func testPreResolvingWithoutAVideoIdIsRejected() async throws {
        let response = try await request("GET", "/api/stream")
        XCTAssertEqual(response.status, 400)
    }

    // MARK: - Liveness of a paused cast

    /// app.js tags its 5s poll with the tab id — as a query parameter *and* a header —
    /// precisely so a paused cast can prove it is still there. The route read neither.
    ///
    /// It matters because the browser only reports progress from the audio element's
    /// `timeupdate`, which does not fire while paused: within seconds of a pause the HTTP
    /// signal was dead and stayed dead, leaving `castLiveness` to decide on the socket
    /// alone. A background tab whose heartbeat timer the browser had throttled then lost the
    /// cast, and the next play came out of the phone.
    func testAPollFromTheCastingTabCountsAsProofItIsStillThere() async throws {
        let videoId = uniqueId("current")
        try await beginCasting(clientId: "tab-cast", videoId: videoId)
        // Pretend the tab has been quiet for longer than a playing cast is given.
        server.forgetComputerReportsForTesting()
        XCTAssertNil(server.lastComputerReportAtForTesting, "Precondition: nothing has been heard")

        _ = try await request("GET", "/api/state?clientId=tab-cast")

        XCTAssertNotNil(
            server.lastComputerReportAtForTesting,
            "A poll from the casting tab is the only liveness signal a paused cast produces"
        )
    }

    /// Sent as a header instead, which app.js also does. Reading only one of the two would
    /// have been a silent half-fix.
    func testTheTabIdIsAlsoAcceptedAsAHeader() async throws {
        let videoId = uniqueId("current")
        try await beginCasting(clientId: "tab-cast", videoId: videoId)
        server.forgetComputerReportsForTesting()

        guard let url = URL(string: baseURL.absoluteString + "/api/state") else {
            throw XCTSkip("could not build URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("tab-cast", forHTTPHeaderField: "X-VVDemus-Client-Id")
        _ = try await URLSession.shared.data(for: request)

        XCTAssertNotNil(server.lastComputerReportAtForTesting)
    }

    /// The same reason `/api/playback/report` checks the id: otherwise a stale tab, or
    /// anything else on the network, could pin playback on a computer producing no sound and
    /// the fallback to the phone could never fire.
    func testAPollFromSomeOtherTabIsNotProofTheCastingTabIsThere() async throws {
        let videoId = uniqueId("current")
        try await beginCasting(clientId: "tab-cast", videoId: videoId)
        server.forgetComputerReportsForTesting()

        _ = try await request("GET", "/api/state?clientId=a-different-tab")
        _ = try await request("GET", "/api/state")

        XCTAssertNil(server.lastComputerReportAtForTesting)
    }

    /// Hands the named track to the phone as "the browser is playing this", which is the
    /// only route to a non-nil `currentTrack` that doesn't restart playback.
    ///
    /// It does leave one fire-and-forget stream resolve running in `PlayerService` (nothing
    /// here waits on it, and its failure is swallowed) — unavoidable without a seam inside
    /// `PlayerService`, which is not this test's business.
    private func beginCasting(clientId: String, videoId: String) async throws {
        _ = try await post("/api/queue/add", ["track": trackJSON(videoId)])
        _ = try await post("/api/device", ["device": "computer", "clientId": clientId])
        _ = try await post("/api/playback/adopt", [
            "videoId": videoId,
            "progress": 0,
            "clientId": clientId,
        ])
        XCTAssertEqual(PlayerService.shared.currentTrack?.videoId, videoId, "Precondition for this test")
    }

    // MARK: - Background task identifiers

    /// The expiration handler used to read `self.backgroundTask` rather than the identifier
    /// it belonged to. `renewBackgroundTask` replaces that property between beginning a task
    /// and the old one expiring, so an old task expiring after a renewal ended the brand-new
    /// identifier — the one actually holding the app alive — and left the expired one
    /// un-ended for the watchdog to kill the process over.
    func testAnExpiringOldBackgroundTaskDoesNotEndTheOneThatReplacedIt() throws {
        let tasks = FakeBackgroundTasks()
        server.backgroundTasks = tasks
        defer { server.applicationWillEnterForeground() }

        server.applicationDidEnterBackground()
        server.renewBackgroundTask()
        let identifiers = tasks.began
        try XCTSkipUnless(identifiers.count == 2, "expected one task per call, got \(identifiers.count)")
        let old = identifiers[0]
        let replacement = identifiers[1]
        XCTAssertTrue(tasks.ended.contains(old), "Renewing must release the task it replaced")

        tasks.expire(old)

        XCTAssertFalse(
            tasks.ended.contains(replacement),
            "The old task's expiration handler ended the live replacement instead of itself"
        )
        XCTAssertEqual(tasks.ended.filter { $0 == old }.count, 2, "Its own identifier is the one it should end")
    }

    func testEnteringTheForegroundEndsTheOutstandingTask() throws {
        let tasks = FakeBackgroundTasks()
        server.backgroundTasks = tasks

        server.applicationDidEnterBackground()
        let started = try XCTUnwrap(tasks.began.first)
        server.applicationWillEnterForeground()

        XCTAssertTrue(tasks.ended.contains(started))
    }

    // MARK: - Route registration

    /// `HttpRouter.register` mutates its node tree with no synchronization while
    /// `HttpRouter.route` reads it under a queue, so re-registering every route on each
    /// `start()` was a Dictionary mutated during a read whenever a tab was still issuing
    /// requests. Registration happens once, in `init`.
    func testRoutesAreRegisteredOnceAcrossRestarts() async throws {
        let registrations = server.routeRegistrations
        XCTAssertEqual(registrations, 1, "Routes should have been registered exactly once, at init")

        server.stop()
        // A different port on the way back up: the one just released can sit in TIME_WAIT,
        // and rebinding is not what this test is about.
        server.port = 52842
        server.start()
        try XCTSkipUnless(server.isRunning, "could not restart: \(server.startupError ?? "unknown")")
        baseURL = URL(string: "http://127.0.0.1:\(server.port)")!

        XCTAssertEqual(server.routeRegistrations, registrations, "Restarting re-registered every route")
        let state = try await request("GET", "/api/state")
        XCTAssertEqual(state.status, 200, "The routes registered at init must still serve after a restart")
    }
}

/// Stands in for `UIApplication`'s background-task API. The simulator hands out real
/// identifiers but will not expire one on demand, and expiry is the only moment the
/// wrong-identifier bug can show itself.
@MainActor
final class FakeBackgroundTasks: BackgroundTaskVending {
    private(set) var began: [UIBackgroundTaskIdentifier] = []
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private var handlers: [Int: @MainActor @Sendable () -> Void] = [:]
    private var next = 1

    func beginBackgroundTask(
        withName name: String?,
        expirationHandler handler: (@MainActor @Sendable () -> Void)?
    ) -> UIBackgroundTaskIdentifier {
        let identifier = UIBackgroundTaskIdentifier(rawValue: next)
        next += 1
        began.append(identifier)
        handlers[identifier.rawValue] = handler
        return identifier
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        ended.append(identifier)
    }

    /// iOS telling a task its time is up.
    func expire(_ identifier: UIBackgroundTaskIdentifier) {
        handlers[identifier.rawValue]?()
    }
}
