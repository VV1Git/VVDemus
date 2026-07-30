import Foundation

/// Classification and pacing for requests YouTube refused because we asked too often, or
/// because something upstream was briefly broken.
///
/// The status code was already being preserved (`APIError.http`) but nothing ever acted on
/// it: a 429 failed exactly like a 500, immediately and permanently, and the app's answer to
/// a failed search was to let the next keystroke fire another one. That is the shape of a
/// retry storm, and it is what turns a momentary rate limit into a long one.
///
/// Everything here is a pure function of its inputs — no clock, no network, no globals —
/// because the interesting cases (a `Retry-After` in the past, an absurd one, a header in
/// HTTP-date form, backoff that must stay bounded) are unpleasant to provoke against live
/// YouTube and trivial to assert on directly.
enum RateLimit {
    /// Longest cool-down worth honouring. YouTube has been known to answer with `Retry-After:
    /// 86400`; obeying that literally would leave the app bricked for a day when the real
    /// limit lifts in seconds, so it is clamped and the user gets to try again.
    static let maximumCooldown: TimeInterval = 300

    /// Longest a single request will sit and wait before giving the error back to the caller.
    /// Past this the caller — and the person holding the phone — is better served by a
    /// message than by a spinner.
    static let maximumWait: TimeInterval = 10

    /// Used when a 429 arrives with no `Retry-After` at all, which is the common case.
    static let defaultCooldown: TimeInterval = 5

    /// How many times one logical request is attempted, first try included.
    static let maximumAttempts = 3

    /// Statuses worth asking again.
    ///
    /// 429 is the rate limit proper and 5xx is YouTube having a moment. Deliberately not
    /// 403: here that means an expired stream URL or an anti-bot refusal, which are fixed by
    /// re-resolving or by a fresh visitor token (see `InnerTubeClient.resolveWithTokenRetry`),
    /// never by repeating the identical request.
    static func isRetryable(status: Int) -> Bool {
        status == 429 || (500...504).contains(status)
    }

    /// Transient transport failures, as opposed to a request that cannot work.
    ///
    /// `.notConnectedToInternet` is excluded on purpose: there is no connection to retry over,
    /// `NetworkMonitor` already drives an offline state, and three spaced-out attempts would
    /// only make the app take nine seconds to say so.
    static func isRetryable(urlError: URLError) -> Bool {
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .badServerResponse:
            return true
        default:
            return false
        }
    }

    /// `Retry-After` in either form the spec allows: seconds, or an HTTP date.
    ///
    /// Returns nil for anything unparseable rather than guessing, so the caller falls back to
    /// `defaultCooldown` instead of to a number invented from a malformed header. A date
    /// already in the past clamps to zero — not to a negative interval that would later be
    /// converted into a `UInt64` sleep and trap.
    static func retryAfter(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }

        if let seconds = Double(raw) {
            guard seconds.isFinite else { return nil }
            return min(max(seconds, 0), maximumCooldown)
        }

        guard let date = httpDateFormatter.date(from: raw) else { return nil }
        return min(max(date.timeIntervalSince(now), 0), maximumCooldown)
    }

    /// RFC 9110 preferred format, e.g. `Wed, 21 Oct 2015 07:28:00 GMT`.
    ///
    /// Pinned to `en_US_POSIX` and GMT. A formatter on `Locale.current` parses this
    /// successfully on an English phone and returns nil on a Japanese or Thai one — the same
    /// class of locale bug `InnerTubeClient.clientVersion` was already bitten by.
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter
    }()

    /// Exponential backoff with jitter: roughly 0.5s, 1s, 2s, each ±25%.
    ///
    /// The jitter is a parameter rather than an internal `Double.random` call so tests can
    /// pin both ends of the range. It matters for real reasons, not tidiness: `home()` fires
    /// three searches at once, and without jitter their retries stay in lockstep and arrive
    /// as one synchronised burst — precisely what got them limited.
    static func backoffDelay(attempt: Int, jitter: Double = Double.random(in: 0...1)) -> TimeInterval {
        let base = 0.5 * pow(2, Double(max(attempt, 1) - 1))
        let spread = 0.75 + 0.5 * min(max(jitter, 0), 1)
        return min(base * spread, maximumWait)
    }
}

/// One cool-down shared by every request in the process.
///
/// Without this each request discovers the rate limit for itself. `home()` alone fans out
/// into three concurrent searches, so a single 429 became three failures and, with retries,
/// nine requests aimed at a server that had just asked for fewer — the opposite of backing
/// off. The first refusal now closes the gate for all of them.
///
/// A plain lock rather than an actor, matching `APIClient`'s stream cache: this is reached
/// from the main actor and from `LocalControlServer`'s background Swifter threads, and it
/// must be readable without an await from either.
final class RateLimitGate {
    static let shared = RateLimitGate()

    private let lock = NSLock()
    private var openAt: Date?

    /// How much of the cool-down is left, or nil when requests may go out.
    func remainingCooldown(now: Date = Date()) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let openAt else { return nil }
        let remaining = openAt.timeIntervalSince(now)
        guard remaining > 0 else {
            // Expired: cleared here so a gate that has served its purpose doesn't keep
            // being re-examined on every request for the rest of the session.
            self.openAt = nil
            return nil
        }
        return remaining
    }

    /// Closes the gate for `retryAfter` (or `RateLimit.defaultCooldown` when the response
    /// didn't say). Never shortens a cool-down another response already asked for.
    func recordRateLimit(retryAfter: TimeInterval?, now: Date = Date()) {
        let interval = min(retryAfter ?? RateLimit.defaultCooldown, RateLimit.maximumCooldown)
        let candidate = now.addingTimeInterval(max(interval, 0))
        lock.lock()
        defer { lock.unlock() }
        // `max`, so a straggler 429 carrying a shorter window can't reopen the gate early on
        // behalf of a longer one already recorded.
        openAt = openAt.map { Swift.max($0, candidate) } ?? candidate
    }

    /// A request got through, so whatever the limit was, it has lifted.
    func clear() {
        lock.lock()
        openAt = nil
        lock.unlock()
    }
}
