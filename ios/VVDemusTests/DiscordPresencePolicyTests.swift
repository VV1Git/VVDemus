import XCTest
@testable import VVDemus

/// What the Discord card says, and when Discord is told.
///
/// Every case here is a timing question — a pause, a seek, the gap between tracks, the five-per-20s
/// rate limit — which a running Discord would only let you reach by waiting for it.
final class DiscordPresencePolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func track(
        _ id: String = "abc",
        title: String = "Song",
        duration: Int? = 200,
        thumbnail: String? = "https://i.ytimg.com/vi/abc/hq720.jpg"
    ) -> Track {
        Track(videoId: id, title: title, artist: "Artist", album: "Album", thumbnailUrl: thumbnail, durationSeconds: duration)
    }

    private func decide(
        track: Track? = nil,
        playing: Bool = true,
        loading: Bool = false,
        progress: Double = 30,
        duration: Double = 200,
        pausedFor: TimeInterval? = nil,
        at date: Date? = nil
    ) -> DiscordPresencePolicy.Decision {
        DiscordPresencePolicy.decide(.init(
            track: track,
            isPlaying: playing,
            isLoading: loading,
            progress: progress,
            duration: duration,
            pausedFor: pausedFor,
            now: date ?? now
        ))
    }

    private func activity(_ decision: DiscordPresencePolicy.Decision) -> DiscordActivity? {
        if case .show(let activity) = decision { return activity }
        return nil
    }

    // MARK: - What to show

    func testPlayingShowsTheTrackWithAProgressBar() throws {
        let shown = try XCTUnwrap(activity(decide(track: track(), progress: 30, duration: 200)))
        XCTAssertEqual(shown.title, "Song")
        XCTAssertEqual(shown.artist, "Artist")
        XCTAssertEqual(shown.start, now.addingTimeInterval(-30))
        XCTAssertEqual(shown.end, now.addingTimeInterval(170))
    }

    /// The player reports `0` until the item loads; the track's own length stands in so the card
    /// still gets a bar.
    func testFallsBackToTheTracksLengthBeforeThePlayerKnowsIt() throws {
        let shown = try XCTUnwrap(activity(decide(track: track(duration: 240), progress: 0, duration: 0)))
        XCTAssertEqual(shown.end, now.addingTimeInterval(240))
    }

    func testUnknownLengthShowsElapsedTimeOnly() throws {
        let shown = try XCTUnwrap(activity(decide(track: track(duration: nil), progress: 5, duration: 0)))
        XCTAssertNil(shown.end)
    }

    func testNothingPlayingClears() {
        XCTAssertEqual(decide(track: nil, playing: false), .clear)
    }

    // MARK: - Pauses and gaps

    /// A quick pause, or a stall that reports as one, must not blink the card off for everyone.
    func testAShortPauseLeavesTheCardAlone() {
        XCTAssertEqual(decide(track: track(), playing: false, pausedFor: 0), .hold)
        XCTAssertEqual(decide(track: track(), playing: false, pausedFor: DiscordPresencePolicy.pauseGrace - 1), .hold)
    }

    func testALongPauseClears() {
        XCTAssertEqual(decide(track: track(), playing: false, pausedFor: DiscordPresencePolicy.pauseGrace), .clear)
    }

    func testLoadingTheNextTrackHolds() {
        XCTAssertEqual(decide(track: track(), playing: false, loading: true), .hold)
        XCTAssertEqual(decide(track: nil, playing: false, loading: true), .hold)
    }

    // MARK: - When to send

    func testFirstCardIsSentImmediately() {
        let show = decide(track: track())
        XCTAssertTrue(DiscordPresencePolicy.shouldSend(show, lastSent: nil, lastSentAt: nil, now: now))
    }

    /// A new connection starts with nothing shown, so clearing it again would spend an update.
    func testClearingWhatWasNeverShownSendsNothing() {
        XCTAssertFalse(DiscordPresencePolicy.shouldSend(.clear, lastSent: nil, lastSentAt: nil, now: now))
        XCTAssertFalse(DiscordPresencePolicy.shouldSend(.clear, lastSent: .clear, lastSentAt: now, now: now.addingTimeInterval(60)))
    }

    func testHoldNeverSends() {
        XCTAssertFalse(DiscordPresencePolicy.shouldSend(.hold, lastSent: nil, lastSentAt: nil, now: now))
    }

    /// Ticks recompute the start time from a position that moves with the clock; the card is the
    /// same card and must not be resent every second.
    func testTheSameSongStillPlayingIsNotResent() {
        let first = decide(track: track(), progress: 30, at: now)
        let later = now.addingTimeInterval(20)
        let second = decide(track: track(), progress: 50.4, at: later)
        XCTAssertFalse(DiscordPresencePolicy.shouldSend(second, lastSent: first, lastSentAt: now, now: later))
    }

    func testASeekIsResent() {
        let first = decide(track: track(), progress: 30, at: now)
        let later = now.addingTimeInterval(20)
        let seeked = decide(track: track(), progress: 150, at: later)
        XCTAssertTrue(DiscordPresencePolicy.shouldSend(seeked, lastSent: first, lastSentAt: now, now: later))
    }

    func testANewSongIsResent() {
        let first = decide(track: track("a"))
        let later = now.addingTimeInterval(10)
        let next = decide(track: track("b"), progress: 0, at: later)
        XCTAssertTrue(DiscordPresencePolicy.shouldSend(next, lastSent: first, lastSentAt: now, now: later))
    }

    /// Discord drops anything past five updates in 20 seconds. A change inside the interval waits
    /// for the next tick after it, rather than being sent and silently lost.
    func testChangesInsideTheRateLimitWait() {
        let first = decide(track: track("a"))
        let soon = now.addingTimeInterval(DiscordPresencePolicy.minimumSendInterval - 1)
        let next = decide(track: track("b"), progress: 0, at: soon)
        XCTAssertFalse(DiscordPresencePolicy.shouldSend(next, lastSent: first, lastSentAt: now, now: soon))

        let allowed = now.addingTimeInterval(DiscordPresencePolicy.minimumSendInterval)
        XCTAssertTrue(DiscordPresencePolicy.shouldSend(next, lastSent: first, lastSentAt: now, now: allowed))
    }

    func testSkippingThroughSongsNeverExceedsDiscordsLimit() {
        var lastSent: DiscordPresencePolicy.Decision?
        var lastSentAt: Date?
        var sends: [Date] = []
        // A new song every second for a minute.
        for second in 0..<60 {
            let at = now.addingTimeInterval(TimeInterval(second))
            let desired = decide(track: track("t\(second)"), progress: 0, at: at)
            if DiscordPresencePolicy.shouldSend(desired, lastSent: lastSent, lastSentAt: lastSentAt, now: at) {
                sends.append(at)
                lastSent = desired
                lastSentAt = at
            }
        }
        for start in sends {
            let window = sends.filter { $0 >= start && $0 < start.addingTimeInterval(20) }
            XCTAssertLessThanOrEqual(window.count, 5)
        }
        XCTAssertGreaterThan(sends.count, 10, "the card should keep up, just not faster than allowed")
    }

    // MARK: - The payload

    func testActivityIsAListeningCard() throws {
        let shown = try XCTUnwrap(activity(decide(track: track())))
        let json = shown.json
        XCTAssertEqual(json["type"] as? Int, 2)
        XCTAssertEqual(json["details"] as? String, "Song")
        XCTAssertEqual(json["state"] as? String, "Artist")
        let assets = try XCTUnwrap(json["assets"] as? [String: Any])
        XCTAssertEqual(assets["large_image"] as? String, "https://i.ytimg.com/vi/abc/hq720.jpg")
        XCTAssertEqual(assets["large_text"] as? String, "Album")
        let timestamps = try XCTUnwrap(json["timestamps"] as? [String: Any])
        XCTAssertEqual(timestamps["start"] as? Int64, Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1000))
        let buttons = try XCTUnwrap(json["buttons"] as? [[String: String]])
        XCTAssertEqual(buttons.first?["url"], "https://music.youtube.com/watch?v=abc")
        XCTAssertLessThanOrEqual(buttons.first?["label"]?.count ?? 0, DiscordActivity.maxButtonLabelLength)
    }

    /// Discord rejects the whole activity for text outside 2…128 characters.
    func testTextIsFittedToDiscordsLimits() {
        XCTAssertEqual(DiscordActivity.fit("A", max: 128).count, 2)
        XCTAssertEqual(DiscordActivity.fit("", max: 128), "Unknown")
        XCTAssertEqual(DiscordActivity.fit(String(repeating: "x", count: 300), max: 128).count, 128)
    }

    func testArtworkThatIsNotPublicHttpsIsLeftOff() {
        XCTAssertNil(DiscordPresencePolicy.artworkUrl(for: track(thumbnail: nil)))
        XCTAssertNil(DiscordPresencePolicy.artworkUrl(for: track(thumbnail: "file:///tmp/cover.jpg")))
        XCTAssertNil(DiscordPresencePolicy.artworkUrl(for: track(thumbnail: "https://example.com/" + String(repeating: "a", count: 300))))
    }

    func testClearingSendsANullActivity() throws {
        var buffer = DiscordIPC.setActivity(nil, pid: 42, nonce: "n")
        let frame = try XCTUnwrap(DiscordIPC.nextFrame(from: &buffer))
        XCTAssertEqual(frame.opcode, DiscordIPC.Opcode.frame.rawValue)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: frame.payload) as? [String: Any])
        XCTAssertEqual(object["cmd"] as? String, "SET_ACTIVITY")
        let args = try XCTUnwrap(object["args"] as? [String: Any])
        XCTAssertEqual(args["pid"] as? Int, 42)
        XCTAssertTrue(args["activity"] is NSNull)
    }

    // MARK: - Framing

    func testFramesSurviveArrivingSplitAndTogether() throws {
        let one = DiscordIPC.encode(.frame, Data(#"{"a":1}"#.utf8))
        let two = DiscordIPC.encode(.ping, Data("xy".utf8))
        let stream = one + two

        var buffer = Data(stream.prefix(5))
        XCTAssertNil(DiscordIPC.nextFrame(from: &buffer), "a partial header is not a frame")
        buffer.append(stream.dropFirst(5))

        let first = try XCTUnwrap(DiscordIPC.nextFrame(from: &buffer))
        XCTAssertEqual(first, .init(opcode: 1, payload: Data(#"{"a":1}"#.utf8)))
        let second = try XCTUnwrap(DiscordIPC.nextFrame(from: &buffer))
        XCTAssertEqual(second, .init(opcode: 3, payload: Data("xy".utf8)))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testHeaderIsLittleEndian() {
        let frame = DiscordIPC.encode(.handshake, Data(repeating: 0, count: 258))
        XCTAssertEqual(Array(frame.prefix(8)), [0, 0, 0, 0, 2, 1, 0, 0])
    }

    func testSocketPathsFollowTheUsersTemporaryDirectory() {
        let paths = DiscordIPC.socketPaths(environment: ["TMPDIR": "/var/folders/xy/T/"])
        XCTAssertEqual(paths.first, "/var/folders/xy/T/discord-ipc-0")
        XCTAssertEqual(paths.count, 10)
        XCTAssertEqual(DiscordIPC.socketPaths(environment: [:]).first, "/tmp/discord-ipc-0")
    }
}
