import XCTest
@testable import VVDemus

/// The parts of rate-limit handling that are miserable to provoke against live YouTube and
/// trivial to assert on directly: header parsing, what counts as retryable, backoff bounds,
/// and the shared cool-down gate.
final class RateLimitTests: XCTestCase {

    // MARK: - Retry-After

    func testRetryAfterReadsPlainSeconds() {
        XCTAssertEqual(RateLimit.retryAfter("5"), 5)
        XCTAssertEqual(RateLimit.retryAfter("  12  "), 12)
        XCTAssertEqual(RateLimit.retryAfter("0"), 0)
    }

    /// YouTube has been observed answering with a day. Obeying that literally would leave the
    /// app refusing to make a request long after the real limit lifted.
    func testRetryAfterIsClampedToSomethingSurvivable() {
        XCTAssertEqual(RateLimit.retryAfter("86400"), RateLimit.maximumCooldown)
    }

    /// Nil rather than a guess, so the caller falls back to its own default instead of to a
    /// number invented from a malformed header.
    func testRetryAfterRejectsNonsense() {
        XCTAssertNil(RateLimit.retryAfter(nil))
        XCTAssertNil(RateLimit.retryAfter(""))
        XCTAssertNil(RateLimit.retryAfter("   "))
        XCTAssertNil(RateLimit.retryAfter("soon"))
        XCTAssertNil(RateLimit.retryAfter("Wed, 21 Oct 2015"))
    }

    /// A negative interval would be converted to `UInt64` for `Task.sleep` and trap.
    func testRetryAfterNeverReturnsANegativeInterval() {
        XCTAssertEqual(RateLimit.retryAfter("-5"), 0)
    }

    func testRetryAfterReadsAnHTTPDate() throws {
        let deadline = try XCTUnwrap(Self.gmtDate(2015, 10, 21, 7, 28, 0))
        let now = deadline.addingTimeInterval(-60)
        let parsed = try XCTUnwrap(RateLimit.retryAfter("Wed, 21 Oct 2015 07:28:00 GMT", now: now))
        XCTAssertEqual(parsed, 60, accuracy: 0.001)
    }

    /// A date already past means "go now", not a negative sleep.
    func testRetryAfterClampsAPastHTTPDateToZero() throws {
        let deadline = try XCTUnwrap(Self.gmtDate(2015, 10, 21, 7, 28, 0))
        let now = deadline.addingTimeInterval(600)
        XCTAssertEqual(RateLimit.retryAfter("Wed, 21 Oct 2015 07:28:00 GMT", now: now), 0)
    }

    // MARK: - What is worth retrying

    func testRateLimitAndServerErrorsAreRetryable() {
        for status in [429, 500, 502, 503, 504] {
            XCTAssertTrue(RateLimit.isRetryable(status: status), "\(status) should be retried")
        }
    }

    /// 403 in this app means an expired stream URL or an anti-bot refusal. Both are answered
    /// by re-resolving or by a fresh visitor token, never by repeating the same request — and
    /// retrying it burns the user's data for a guaranteed second failure.
    func testPermanentFailuresAreNotRetryable() {
        for status in [200, 400, 401, 403, 404, 410, 451] {
            XCTAssertFalse(RateLimit.isRetryable(status: status), "\(status) should not be retried")
        }
    }

    func testTransientTransportFailuresAreRetryable() {
        XCTAssertTrue(RateLimit.isRetryable(urlError: URLError(.timedOut)))
        XCTAssertTrue(RateLimit.isRetryable(urlError: URLError(.networkConnectionLost)))
        XCTAssertTrue(RateLimit.isRetryable(urlError: URLError(.cannotConnectToHost)))
    }

    /// Retrying without a connection can only fail three times more slowly. `NetworkMonitor`
    /// already drives the offline state; a cancellation is the next keystroke arriving.
    func testOfflineAndCancelledAreNotRetryable() {
        XCTAssertFalse(RateLimit.isRetryable(urlError: URLError(.notConnectedToInternet)))
        XCTAssertFalse(RateLimit.isRetryable(urlError: URLError(.cancelled)))
    }

    // MARK: - Backoff

    func testBackoffGrowsAndStaysWithinItsJitterBand() {
        // Both ends pinned rather than sampled, which is why jitter is a parameter.
        XCTAssertEqual(RateLimit.backoffDelay(attempt: 1, jitter: 0), 0.375, accuracy: 0.0001)
        XCTAssertEqual(RateLimit.backoffDelay(attempt: 1, jitter: 1), 0.625, accuracy: 0.0001)
        XCTAssertEqual(RateLimit.backoffDelay(attempt: 2, jitter: 0), 0.75, accuracy: 0.0001)
        XCTAssertEqual(RateLimit.backoffDelay(attempt: 3, jitter: 0), 1.5, accuracy: 0.0001)
    }

    func testBackoffNeverExceedsTheMaximumWait() {
        for attempt in 1...20 {
            XCTAssertLessThanOrEqual(RateLimit.backoffDelay(attempt: attempt, jitter: 1), RateLimit.maximumWait)
        }
    }

    /// Guards the `max(attempt, 1)`: `pow(2, -1)` would otherwise produce a delay shorter
    /// than the first attempt's, and a zero or negative attempt is exactly the sort of thing
    /// an off-by-one in a retry loop hands over.
    func testBackoffToleratesADegenerateAttemptNumber() {
        XCTAssertEqual(
            RateLimit.backoffDelay(attempt: 0, jitter: 0),
            RateLimit.backoffDelay(attempt: 1, jitter: 0),
            accuracy: 0.0001
        )
    }

    // MARK: - The shared gate

    func testGateIsOpenUntilARateLimitIsRecorded() {
        let gate = RateLimitGate()
        XCTAssertNil(gate.remainingCooldown())
    }

    func testGateHoldsTheRequestedCooldownAndThenReopens() {
        let gate = RateLimitGate()
        let now = Date()
        gate.recordRateLimit(retryAfter: 30, now: now)

        XCTAssertEqual(try XCTUnwrap(gate.remainingCooldown(now: now)), 30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(gate.remainingCooldown(now: now.addingTimeInterval(20))), 10, accuracy: 0.001)
        XCTAssertNil(gate.remainingCooldown(now: now.addingTimeInterval(30)))
        XCTAssertNil(gate.remainingCooldown(now: now.addingTimeInterval(31)))
    }

    func testGateFallsBackToADefaultWhenTheResponseDidNotSayHowLong() throws {
        let gate = RateLimitGate()
        let now = Date()
        gate.recordRateLimit(retryAfter: nil, now: now)
        XCTAssertEqual(
            try XCTUnwrap(gate.remainingCooldown(now: now)),
            RateLimit.defaultCooldown,
            accuracy: 0.001
        )
    }

    /// Home fans out into three concurrent searches, so several 429s land at once. A straggler
    /// carrying a shorter window must not reopen the gate on behalf of a longer one already
    /// recorded — that would send the next request out mid-cool-down.
    func testGateKeepsTheLongestCooldownItHasBeenTold() throws {
        let gate = RateLimitGate()
        let now = Date()
        gate.recordRateLimit(retryAfter: 60, now: now)
        gate.recordRateLimit(retryAfter: 5, now: now)
        XCTAssertEqual(try XCTUnwrap(gate.remainingCooldown(now: now)), 60, accuracy: 0.001)
    }

    /// A request getting through means the limit lifted, whatever the clock said.
    func testGateClearsOnSuccess() {
        let gate = RateLimitGate()
        gate.recordRateLimit(retryAfter: 120)
        XCTAssertNotNil(gate.remainingCooldown())
        gate.clear()
        XCTAssertNil(gate.remainingCooldown())
    }

    func testGateClampsAnAbsurdCooldown() throws {
        let gate = RateLimitGate()
        let now = Date()
        gate.recordRateLimit(retryAfter: 86_400, now: now)
        XCTAssertEqual(
            try XCTUnwrap(gate.remainingCooldown(now: now)),
            RateLimit.maximumCooldown,
            accuracy: 0.001
        )
    }

    // MARK: - What the user is told

    /// The distinction the whole feature exists for: a rate limit must not read as a broken
    /// connection, because the two call for opposite responses.
    func testRateLimitErrorSaysWhenToTryAgain() {
        XCTAssertEqual(
            APIError.rateLimited(retryAfter: 12).errorDescription,
            "YouTube Music is limiting requests. Try again in 12s."
        )
        XCTAssertEqual(
            APIError.rateLimited(retryAfter: nil).errorDescription,
            "YouTube Music is limiting requests. Try again in a moment."
        )
        // Sub-second: "try again in 0s" is worse than not saying.
        XCTAssertEqual(
            APIError.rateLimited(retryAfter: 0.4).errorDescription,
            "YouTube Music is limiting requests. Try again in a moment."
        )
    }

    func testIsRateLimitCoversBothShapesOfTheSameFailure() {
        XCTAssertTrue(APIError.rateLimited(retryAfter: nil).isRateLimit)
        XCTAssertTrue(APIError.http(status: 429).isRateLimit)
        XCTAssertFalse(APIError.http(status: 503).isRateLimit)
        XCTAssertFalse(APIError.server("nope").isRateLimit)
        XCTAssertFalse(APIError.invalidURL.isRateLimit)
    }

    /// A download that failed because we were asked to slow down used to read exactly like a
    /// track that will never download.
    func testDownloadFailureNamesARateLimit() {
        let track = Track(
            videoId: "abc",
            title: "Pumped Up Kicks",
            artist: "Foster The People",
            album: nil,
            thumbnailUrl: nil,
            durationSeconds: 240
        )
        XCTAssertEqual(
            DownloadManager.failureMessage(for: track, error: APIError.rateLimited(retryAfter: 8)),
            "YouTube Music is limiting requests. Try again in 8s. \"Pumped Up Kicks\" wasn't downloaded."
        )
        XCTAssertEqual(
            DownloadManager.failureMessage(for: track, error: APIError.server("gone")),
            "Couldn't download \"Pumped Up Kicks\"."
        )
    }

    // MARK: - Helpers

    private static func gmtDate(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT") ?? .gmt
        return calendar.date(
            from: DateComponents(
                year: year, month: month, day: day, hour: hour, minute: minute, second: second
            )
        )
    }
}
