import XCTest
@testable import VVDemus

/// The visitor token, without which YouTube refuses stream resolution as bot traffic and
/// every track silently falls back to muxed video at ~3.9x the data.
///
/// The failure mode this guards is specifically a *quiet* one: nothing crashes, playback
/// still works, and the only symptom is the data bill.
final class VisitorDataTests: XCTestCase {

    private func makeDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "vvdemus.tests.\(UUID().uuidString)"))
    }

    // MARK: - Parsing

    /// The homepage spells the token out under a named key, JSON-escaped inside the page's
    /// own JSON — using it literally would send `=` to YouTube.
    func testAuthoritativeTokenIsUnescaped() {
        let html = #"ytcfg.set({"INNERTUBE_CONTEXT":{"client":{"visitorData":"CgtBQkNERUZ==","hl":"en"}}});"#
        XCTAssertEqual(
            VisitorDataProvider.parseToken(from: html, source: .authoritative),
            "CgtBQkNERUZ==",
            "Escaped sequences must be decoded — sending a literal backslash-u to YouTube is not the token"
        )
    }

    /// The cheap endpoint has no key to match on — the token sits at an unnamed position
    /// in an undocumented array, so it's matched by shape.
    func testCheapTokenIsFoundByShape() {
        let body = #")]}'  [["yt.sw.adr",null,[[["en","US",null,"",null,"","CgtfRi1TbXhiVFhPbyio36nTBjIKCgJVUxIEGgAg%3D%3D",null]]]]"#
        XCTAssertEqual(
            VisitorDataProvider.parseToken(from: body, source: .cheap),
            "CgtfRi1TbXhiVFhPbyio36nTBjIKCgJVUxIEGgAg%3D%3D"
        )
    }

    /// Regression: a strict `[A-Za-z0-9_-]` class stopped short of the closing quote on
    /// tokens carrying `=` padding and matched nothing at all, which reads at runtime as
    /// "YouTube changed their page" rather than "our regex is wrong".
    func testCheapTokenWithPaddingIsNotRejected() {
        for padded in ["Cg\(String(repeating: "a", count: 30))==",
                       "Cg\(String(repeating: "b", count: 30))%3D%3D"] {
            let body = "[\"junk\",\"\(padded)\",null]"
            XCTAssertEqual(VisitorDataProvider.parseToken(from: body, source: .cheap), padded,
                           "Padding characters must not truncate the match")
        }
    }

    func testMissingTokenReturnsNilRatherThanGarbage() {
        XCTAssertNil(VisitorDataProvider.parseToken(from: "<html>no token here</html>", source: .cheap))
        XCTAssertNil(VisitorDataProvider.parseToken(from: "<html>no token here</html>", source: .authoritative))
        XCTAssertNil(VisitorDataProvider.parseToken(from: #"{"visitorData":""}"#, source: .authoritative),
                     "An empty token is not a token")
    }

    // MARK: - Caching

    func testTokenIsFetchedOnceAndReused() async throws {
        let counter = FetchCounter()
        let provider = VisitorDataProvider(
            defaults: try makeDefaults(),
            fetch: { _ in await counter.next() }
        )

        let first = try await provider.current()
        let second = try await provider.current()

        XCTAssertEqual(first, "token-1")
        XCTAssertEqual(second, "token-1", "A cached token must be reused")
        let count = await counter.count
        XCTAssertEqual(count, 1, "Refetching per track would cost bytes on every song")
    }

    /// Starting a queue resolves several tracks at once. Each fetching its own token would
    /// multiply both the requests and the bytes — the opposite of the point.
    func testConcurrentCallersShareOneFetch() async throws {
        let counter = FetchCounter(delay: 50_000_000)
        let provider = VisitorDataProvider(
            defaults: try makeDefaults(),
            fetch: { _ in await counter.next() }
        )

        async let a = provider.current()
        async let b = provider.current()
        async let c = provider.current()
        let tokens = try await [a, b, c]

        XCTAssertEqual(Set(tokens).count, 1, "All callers should get the same token")
        let count = await counter.count
        XCTAssertEqual(count, 1, "Concurrent resolves must coalesce into a single fetch")
    }

    func testStaleTokenIsRefetched() async throws {
        let counter = FetchCounter()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000))
        let provider = VisitorDataProvider(
            defaults: try makeDefaults(),
            now: { clock.value },
            fetch: { _ in await counter.next() }
        )

        _ = try await provider.current()
        clock.value = clock.value.addingTimeInterval(VisitorDataProvider.maxAge + 1)
        let refreshed = try await provider.current()

        XCTAssertEqual(refreshed, "token-2", "A token past its age must be refetched")
        let count = await counter.count
        XCTAssertEqual(count, 2)
    }

    func testTokenSurvivesRelaunch() async throws {
        let defaults = try makeDefaults()
        let first = VisitorDataProvider(defaults: defaults, fetch: { _ in "persisted-token" })
        _ = try await first.current()

        let counter = FetchCounter()
        let relaunched = VisitorDataProvider(defaults: defaults, fetch: { _ in await counter.next() })
        let token = try await relaunched.current()

        XCTAssertEqual(token, "persisted-token", "Every cold start refetching is a pointless cost")
        let count = await counter.count
        XCTAssertEqual(count, 0)
    }

    func testInvalidateForcesAFreshFetch() async throws {
        let defaults = try makeDefaults()
        let counter = FetchCounter()
        let provider = VisitorDataProvider(defaults: defaults, fetch: { _ in await counter.next() })

        _ = try await provider.current()
        await provider.invalidate()

        XCTAssertNil(defaults.string(forKey: VisitorDataProvider.defaultsKey),
                     "A refused token must not be left on disk to be reloaded next launch")
        let token = try await provider.current()
        XCTAssertEqual(token, "token-2")
    }

    /// A refusal escalates from the cheap shape-matched endpoint to the authoritative
    /// named-key one, so a shape-match that grabbed the wrong string self-corrects.
    func testRefreshRequestsTheSourceItWasAskedFor() async throws {
        let recorder = SourceRecorder()
        let provider = VisitorDataProvider(
            defaults: try makeDefaults(),
            fetch: { source in await recorder.record(source) }
        )

        _ = try await provider.current()
        await provider.invalidate()
        _ = try await provider.refresh(from: .authoritative)

        let sources = await recorder.sources
        XCTAssertEqual(sources, ["cheap", "authoritative"],
                       "Normal fetches take the 2.7 KB endpoint; only a refusal pays for the 822 KB one")
    }

    func testFetchFailureDoesNotWedgeTheProvider() async throws {
        let shouldFail = Flag(value: true)
        let provider = VisitorDataProvider(
            defaults: try makeDefaults(),
            fetch: { _ in
                if shouldFail.value { throw APIError.server("offline") }
                return "recovered"
            }
        )

        do {
            _ = try await provider.current()
            XCTFail("Expected the fetch to fail")
        } catch {
            // expected
        }

        shouldFail.value = false
        let token = try await provider.current()
        XCTAssertEqual(token, "recovered", "A failed fetch must not leave the in-flight task stuck")
    }

    func testCurrentIfAvailableSwallowsFailure() async throws {
        let provider = VisitorDataProvider(
            defaults: try makeDefaults(),
            fetch: { _ in throw APIError.server("offline") }
        )
        let token = await provider.currentIfAvailable()
        XCTAssertNil(token, "Resolution should still be attempted bare rather than throwing here")
    }

    // MARK: - The token actually reaching YouTube

    /// The provider can be flawless and the app still pay 3.9x, if the token never makes
    /// it onto the request. Asserted against the **real** production client rather than a
    /// fixture, so deleting either line of the wiring fails this.
    func testPlayerRequestCarriesTheTokenInHeaderAndContext() throws {
        let client = try XCTUnwrap(InnerTubeClient.audioOnlyClients.first)
        let request = try InnerTubeClient.playerRequest(
            videoId: "abc123", client: client, visitorData: "TOKEN-XYZ"
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Visitor-Id"), "TOKEN-XYZ")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let context = try XCTUnwrap(json["context"] as? [String: Any])
        let clientContext = try XCTUnwrap(context["client"] as? [String: Any])
        XCTAssertEqual(clientContext["visitorData"] as? String, "TOKEN-XYZ",
                       "YouTube reads the token from the client context; omitting it is the whole bug")
        XCTAssertEqual(json["videoId"] as? String, "abc123")
        XCTAssertEqual(clientContext["clientName"] as? String, "ANDROID_VR")
    }

    /// Without a token the request must go out clean rather than carrying an empty or
    /// literal-"nil" value, which YouTube would treat as a malformed credential.
    func testPlayerRequestOmitsTheTokenEntirelyWhenThereIsNone() throws {
        let client = try XCTUnwrap(InnerTubeClient.audioOnlyClients.first)
        let request = try InnerTubeClient.playerRequest(
            videoId: "abc123", client: client, visitorData: nil
        )

        XCTAssertNil(request.value(forHTTPHeaderField: "X-Goog-Visitor-Id"))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let context = try XCTUnwrap(json["context"] as? [String: Any])
        let clientContext = try XCTUnwrap(context["client"] as? [String: Any])
        XCTAssertNil(clientContext["visitorData"])
    }

    /// The IOS client resolves perfectly and then 403s every byte range past ~1 MB, so a
    /// track plays for a minute and dies. It looked like an upgrade twice; it is not one.
    func testThrottledClientIsNotUsedForPlayback() {
        let names = InnerTubeClient.audioOnlyClients.map(\.name)
        XCTAssertFalse(names.contains("IOS"),
                       "IOS passes gate 1 (resolves) but fails gate 2 (can serve a whole track)")
        XCTAssertTrue(names.contains("ANDROID_VR"))
    }

    // MARK: - Escalation on refusal

    private func sampleStream(_ token: String?) -> StreamInfo {
        StreamInfo(videoId: "v", url: "https://example.com/\(token ?? "none")",
                   expiresAt: 0, mimeType: "audio/mp4")
    }

    func testSuccessfulResolveNeverPaysForTheExpensiveEndpoint() async throws {
        var asked: [String] = []
        let stream = try await InnerTubeClient.resolveWithTokenRetry(
            token: { source in
                if case .cheap = source { asked.append("cheap") } else { asked.append("authoritative") }
                return "cheap-token"
            },
            attempt: { self.sampleStream($0) }
        )

        XCTAssertEqual(asked, ["cheap"], "The 822 KB endpoint must not be touched on the happy path")
        XCTAssertEqual(stream.url, "https://example.com/cheap-token")
    }

    /// The mutation that survived the first pass: escalating to the *cheap* source on a
    /// refusal would hand back the same shape-matched string and fix nothing.
    func testRefusalEscalatesToTheAuthoritativeSource() async throws {
        var asked: [String] = []
        var tokensTried: [String?] = []
        let stream = try await InnerTubeClient.resolveWithTokenRetry(
            token: { source in
                if case .cheap = source { asked.append("cheap"); return "stale" }
                asked.append("authoritative")
                return "fresh"
            },
            attempt: { token in
                tokensTried.append(token)
                if token == "stale" { throw InnerTubeClient.TokenRefusal(reason: "Sign in to confirm") }
                return self.sampleStream(token)
            }
        )

        XCTAssertEqual(asked, ["cheap", "authoritative"],
                       "A refusal must escalate to the named-key source, not refetch the same way")
        XCTAssertEqual(tokensTried, ["stale", "fresh"], "The retry has to actually use the new token")
        XCTAssertEqual(stream.url, "https://example.com/fresh")
    }

    /// A video that is genuinely unavailable must not send the app round again.
    func testNonCredentialFailureIsNotRetried() async {
        var attempts = 0
        var asked = 0
        do {
            _ = try await InnerTubeClient.resolveWithTokenRetry(
                token: { _ in asked += 1; return "token" },
                attempt: { _ in
                    attempts += 1
                    throw APIError.server("This video is unavailable")
                }
            )
            XCTFail("Expected the error to propagate")
        } catch {
            XCTAssertEqual(attempts, 1, "Retrying an unavailable video just hammers YouTube")
            XCTAssertEqual(asked, 1, "No point buying a fresh token for a video that doesn't exist")
        }
    }

    func testRefusalOfAFreshTokenStopsRatherThanLooping() async {
        var attempts = 0
        do {
            _ = try await InnerTubeClient.resolveWithTokenRetry(
                token: { source in
                    if case .cheap = source { return "one" } else { return "two" }
                },
                attempt: { _ in
                    attempts += 1
                    throw InnerTubeClient.TokenRefusal(reason: "Sign in to confirm you\u{2019}re not a bot")
                }
            )
            XCTFail("Expected the refusal to surface")
        } catch {
            XCTAssertEqual(attempts, 2, "Exactly one retry — a loop here would be an infinite one")
            XCTAssertEqual(error.localizedDescription, "Sign in to confirm you\u{2019}re not a bot",
                           "The real reason must survive, not be replaced by a generic message")
        }
    }

    /// If the escalation can't produce a *different* token there is nothing to retry with.
    func testNoRetryWhenTheEscalatedTokenIsUnchanged() async {
        var attempts = 0
        do {
            _ = try await InnerTubeClient.resolveWithTokenRetry(
                token: { _ in "same-token" },
                attempt: { _ in
                    attempts += 1
                    throw InnerTubeClient.TokenRefusal(reason: "Sign in")
                }
            )
            XCTFail("Expected the refusal to surface")
        } catch {
            XCTAssertEqual(attempts, 1, "Retrying with an identical token is a wasted request")
        }
    }

    /// Asking the provider for the authoritative token means the last one was refused, so
    /// it must discard the cached value rather than hand the same bad token back.
    func testAuthoritativeRequestDiscardsTheCachedToken() async throws {
        let counter = FetchCounter()
        let provider = VisitorDataProvider(defaults: try makeDefaults(), fetch: { _ in await counter.next() })

        let cheap = await provider.token(for: .cheap)
        let escalated = await provider.token(for: .authoritative)

        XCTAssertEqual(cheap, "token-1")
        XCTAssertEqual(escalated, "token-2",
                       "Handing back the cached token would make the whole retry pointless")
    }

    // MARK: - Refusal classification

    /// The retry must fire for a missing-credential refusal and must *not* fire for a
    /// video that is genuinely unavailable.
    func testTokenRefusalIsDistinguishedFromRealUnavailability() {
        XCTAssertTrue(InnerTubeClient.isTokenRefusal(
            status: "LOGIN_REQUIRED", reason: "Sign in to confirm you\u{2019}re not a bot"))
        XCTAssertTrue(InnerTubeClient.isTokenRefusal(
            status: "UNPLAYABLE", reason: "Sign in to confirm you\u{2019}re not a bot"),
            "The curly apostrophe YouTube actually sends must not defeat the match")
        XCTAssertTrue(InnerTubeClient.isTokenRefusal(status: "LOGIN_REQUIRED", reason: "Please sign in"))

        XCTAssertFalse(InnerTubeClient.isTokenRefusal(
            status: "UNPLAYABLE", reason: "This video is unavailable"))
        XCTAssertFalse(InnerTubeClient.isTokenRefusal(
            status: "ERROR", reason: "Video unavailable in your country"))
        XCTAssertFalse(InnerTubeClient.isTokenRefusal(
            status: "UNPLAYABLE", reason: "The page needs to be reloaded."))
    }
}

// MARK: - Helpers

private actor FetchCounter {
    private(set) var count = 0
    private let delay: UInt64

    init(delay: UInt64 = 0) { self.delay = delay }

    func next() async -> String {
        count += 1
        let issued = count
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return "token-\(issued)"
    }
}

private actor SourceRecorder {
    private(set) var sources: [String] = []
    func record(_ source: VisitorDataProvider.Source) -> String {
        if case .cheap = source { sources.append("cheap") } else { sources.append("authoritative") }
        return "token-\(sources.count)"
    }
}

/// Deliberately unsynchronised — used only from a single test's serial flow.
private final class MutableClock: @unchecked Sendable {
    var value: Date
    init(now: Date) { value = now }
}

private final class Flag: @unchecked Sendable {
    var value: Bool
    init(value: Bool) { self.value = value }
}
