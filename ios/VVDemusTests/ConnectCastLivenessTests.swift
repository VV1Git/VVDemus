import XCTest
@testable import VVDemus

/// When the phone decides the casting browser has gone away and takes playback back.
///
/// The decision is a pure function of a few ages, which is the only way to test it: the
/// windows involved run to a minute and a half, and driving them through the real 1 Hz
/// timer would mean sleeping through them.
final class ConnectCastLivenessTests: XCTestCase {
    private typealias Input = LocalControlServer.CastLivenessInput

    private func input(
        isPlaying: Bool,
        sinceReport: TimeInterval?,
        heartbeatAge: TimeInterval,
        socketConnected: Bool,
        missingFor: TimeInterval? = nil
    ) -> Input {
        Input(
            isPlaying: isPlaying,
            sinceReport: sinceReport,
            heartbeatAge: heartbeatAge,
            socketConnected: socketConnected,
            missingFor: missingFor
        )
    }

    // MARK: - A paused cast

    /// The bug this file exists for.
    ///
    /// The browser only POSTs `/api/playback/report` from the audio element's `timeupdate`,
    /// which does not fire while paused — so a few seconds after pausing, the HTTP signal
    /// is dead and stays dead. Judged on the 8s playing window, the "both signals must
    /// agree" protection reduced to "is the socket up?", and any drop that outlasted the 6s
    /// grace revoked the cast. The user came back to "Playing on iPhone" and the next play
    /// came out of the phone in their bag.
    func testAPausedCastSurvivesASocketDropLongerThanThePlayingGrace() {
        // Paused for half a minute — so no reports, by design — with the socket down long
        // enough that the old six-second grace would already have expired twice over.
        let decision = LocalControlServer.castLiveness(input(
            isPlaying: false,
            sinceReport: 30,
            heartbeatAge: 30,
            socketConnected: false,
            missingFor: 25
        ))
        XCTAssertEqual(decision, .present, "A paused cast was revoked on the socket alone")
    }

    /// The client backs its reconnect off to as much as 30s between attempts, so the window
    /// has to comfortably outlast that or a tab that is merely slow to come back loses the
    /// cast.
    func testThePausedWindowOutlastsTheClientsReconnectBackoff() {
        XCTAssertGreaterThan(
            LocalControlServer.pausedCastLivenessWindow,
            2 * 30,
            "app.js backs off to 30s between reconnect attempts"
        )
        XCTAssertGreaterThan(
            LocalControlServer.pausedCastLivenessWindow,
            LocalControlServer.computerReportTimeout,
            "A paused tab cannot be held to the window built for a reporting one"
        )
    }

    /// The case the fallback exists for, in its paused form: the tab really is closed.
    /// Nothing at all has been heard for longer than the paused window, so it does still
    /// release — just later than it would while playing, which costs nothing audible.
    func testAPausedCastIsStillReleasedOnceNothingHasBeenHeardForTheWholeWindow() {
        let silence = LocalControlServer.pausedCastLivenessWindow + 10
        let starting = LocalControlServer.castLiveness(input(
            isPlaying: false,
            sinceReport: silence,
            heartbeatAge: .infinity,
            socketConnected: false
        ))
        XCTAssertEqual(starting, .missing, "The grace clock has to start before it can expire")

        let expired = LocalControlServer.castLiveness(input(
            isPlaying: false,
            sinceReport: silence,
            heartbeatAge: .infinity,
            socketConnected: false,
            missingFor: LocalControlServer.computerFallbackGrace
        ))
        XCTAssertEqual(expired, .gone, "A browser that really is gone must release playback")
    }

    func testAPausedCastWithALiveSocketIsPresentHoweverOldTheLastReportIs() {
        let decision = LocalControlServer.castLiveness(input(
            isPlaying: false,
            sinceReport: 3_600,
            heartbeatAge: 2,
            socketConnected: true
        ))
        XCTAssertEqual(decision, .present)
    }

    // MARK: - A playing cast

    /// Unchanged, and deliberately so: silence while audio is supposed to be coming out is
    /// conclusive, because a browser that is genuinely playing reports about once a second.
    func testAPlayingCastThatHasGoneQuietOnBothChannelsIsReleasedAtOnce() {
        let decision = LocalControlServer.castLiveness(input(
            isPlaying: true,
            sinceReport: LocalControlServer.computerReportTimeout + 1,
            heartbeatAge: LocalControlServer.castHeartbeatTimeout + 1,
            socketConnected: false
        ))
        XCTAssertEqual(decision, .gone, "No grace period applies once reports stop mid-playback")
    }

    /// Locking the phone interrupts its own networking for a moment. A heartbeat still
    /// arriving proves the tab is there and still holding the audio.
    func testAPlayingCastWhoseHeartbeatStillArrivesIsNotReleased() {
        let decision = LocalControlServer.castLiveness(input(
            isPlaying: true,
            sinceReport: LocalControlServer.computerReportTimeout + 1,
            heartbeatAge: 1,
            socketConnected: true
        ))
        XCTAssertEqual(decision, .present)
    }

    /// HTTP can keep working while a WebSocket is down and reconnecting, so fresh reports
    /// alone are enough.
    func testAPlayingCastStillReportingSurvivesLosingItsSocket() {
        let decision = LocalControlServer.castLiveness(input(
            isPlaying: true,
            sinceReport: 1,
            heartbeatAge: .infinity,
            socketConnected: false,
            missingFor: 30
        ))
        XCTAssertEqual(decision, .present)
    }

    func testAPlayingCastGoneOnBothChannelsCountsDownTheGraceFirst() {
        // Not yet: reports stopped, but the heartbeat is still inside its own timeout, so
        // the "conclusive" branch doesn't apply and the socket-loss grace governs.
        let counting = LocalControlServer.castLiveness(input(
            isPlaying: true,
            sinceReport: LocalControlServer.computerReportTimeout + 1,
            heartbeatAge: LocalControlServer.castHeartbeatTimeout - 1,
            socketConnected: false,
            missingFor: LocalControlServer.computerFallbackGrace - 1
        ))
        XCTAssertEqual(counting, .missing)

        let expired = LocalControlServer.castLiveness(input(
            isPlaying: true,
            sinceReport: LocalControlServer.computerReportTimeout + 1,
            heartbeatAge: LocalControlServer.castHeartbeatTimeout - 1,
            socketConnected: false,
            missingFor: LocalControlServer.computerFallbackGrace
        ))
        XCTAssertEqual(expired, .gone)
    }

    // MARK: - Nothing has ever reported

    /// The state immediately after a device switch, which resets the clock. Never having
    /// reported is not evidence of absence while the socket is up.
    func testATabThatHasNeverReportedIsJudgedOnItsSocket() {
        XCTAssertEqual(
            LocalControlServer.castLiveness(input(
                isPlaying: true, sinceReport: nil, heartbeatAge: 1, socketConnected: true
            )),
            .present
        )
        XCTAssertEqual(
            LocalControlServer.castLiveness(input(
                isPlaying: true, sinceReport: nil, heartbeatAge: .infinity, socketConnected: false
            )),
            .missing,
            "No report and no socket starts the clock rather than revoking outright"
        )
    }
}
