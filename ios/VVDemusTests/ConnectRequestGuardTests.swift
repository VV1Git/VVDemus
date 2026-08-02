import XCTest
@testable import VVDemus

/// The checks that decide whether a request reaching VVDemus Connect is one the user's own
/// page made, or one some other web page made on their behalf without them knowing.
final class ConnectRequestGuardTests: XCTestCase {
    private let port: UInt16 = 51825

    // MARK: - Origin

    func testOwnPageIsAllowed() {
        for origin in ["http://localhost:51825", "http://127.0.0.1:51825", "http://192.168.1.42:51825"] {
            XCTAssertTrue(LocalControlServer.isAllowedOrigin(origin, port: port), origin)
        }
    }

    /// The whole point: an ordinary page the user visits must not be able to drive the
    /// phone in the background. A form-style POST needs no preflight, so nothing else stops
    /// it.
    func testForeignPageIsRejected() {
        for origin in [
            "http://evil.example",
            "https://evil.example",
            "http://evil.example:51825",
            "http://localhost.evil.example:51825",
            "http://127.0.0.1.evil.example:51825",
        ] {
            XCTAssertFalse(LocalControlServer.isAllowedOrigin(origin, port: port), origin)
        }
    }

    /// A page served from the phone on a *different* port is still a different origin.
    func testRightHostWrongPortIsRejected() {
        XCTAssertFalse(LocalControlServer.isAllowedOrigin("http://localhost:8080", port: port))
        XCTAssertFalse(LocalControlServer.isAllowedOrigin("http://192.168.1.42", port: port))
    }

    /// curl, the phone itself and other non-browser clients send no Origin at all, and were
    /// never the risk — blocking them would break the tooling without helping.
    func testAbsentOriginIsAllowed() {
        XCTAssertTrue(LocalControlServer.isAllowedOrigin(nil, port: port))
        XCTAssertTrue(LocalControlServer.isAllowedOrigin("", port: port))
    }

    /// A sandboxed iframe or a redirected request sends the literal string "null". Treated
    /// as absent rather than as a host, because `URL(string:)` would otherwise parse it as a
    /// relative path with no host and it would be rejected — which is the safe direction,
    /// but only by accident.
    func testNullOriginIsTreatedAsAbsent() {
        XCTAssertTrue(LocalControlServer.isAllowedOrigin("null", port: port))
    }

    // MARK: - Host (DNS rebinding)

    func testHostMustBeAnAddressRatherThanAName() {
        XCTAssertTrue(LocalControlServer.isAllowedHost("localhost:51825", port: port))
        XCTAssertTrue(LocalControlServer.isAllowedHost("192.168.1.42:51825", port: port))
        XCTAssertTrue(LocalControlServer.isAllowedHost("192.168.1.42", port: port))

        // A name the attacker owns can be re-pointed at the phone's LAN address after the
        // page has loaded, which leaves their origin reading every response.
        XCTAssertFalse(LocalControlServer.isAllowedHost("evil.example", port: port))
        XCTAssertFalse(LocalControlServer.isAllowedHost("evil.example:51825", port: port))
        XCTAssertFalse(LocalControlServer.isAllowedHost("phone.local:51825", port: port))
    }

    // MARK: - Address parsing

    func testOnlyRealIPv4LiteralsCount() {
        for good in ["0.0.0.0", "10.0.0.1", "192.168.1.42", "255.255.255.255"] {
            XCTAssertTrue(LocalControlServer.isIPv4Literal(good), good)
        }
        for bad in ["256.1.1.1", "1.2.3", "1.2.3.4.5", "1.2.3.", "a.b.c.d", "", "1.2.3.4a", "1.2.3.-1"] {
            XCTAssertFalse(LocalControlServer.isIPv4Literal(bad), bad)
        }
    }

    // MARK: - Identifying the tab that sent a request

    /// app.js sends its tab id both ways so the server can read whichever it prefers. It
    /// used to read neither, which cost a paused cast its only HTTP liveness signal.
    func testTheTabIdIsReadFromEitherTheQueryOrTheHeader() {
        XCTAssertEqual(LocalControlServer.clientId(queryValue: "tab-a", header: nil), "tab-a")
        XCTAssertEqual(LocalControlServer.clientId(queryValue: nil, header: "tab-b"), "tab-b")
        XCTAssertEqual(LocalControlServer.clientId(queryValue: "", header: "tab-b"), "tab-b")
    }

    /// Swifter hands back an empty string for a parameter that isn't there, and an empty id
    /// must never match `castClientId` — which is itself nil when nothing is casting.
    func testAnAbsentOrBlankTabIdIsNil() {
        XCTAssertNil(LocalControlServer.clientId(queryValue: nil, header: nil))
        XCTAssertNil(LocalControlServer.clientId(queryValue: "", header: ""))
        XCTAssertNil(LocalControlServer.clientId(queryValue: "   ", header: nil))
    }

    // MARK: - Pre-resolving upcoming streams

    /// Each one is a YouTube round trip, so `/api/stream` serves a window at the front of
    /// the queue rather than anything the caller names.
    func testOnlyTracksNearTheFrontOfTheQueueMayBePreResolved() {
        let upcoming = ["b", "c", "d", "e", "f", "g"]
        let depth = LocalControlServer.maximumPrefetchDepth

        XCTAssertTrue(LocalControlServer.isPrefetchable("b", upcoming: upcoming, depth: depth))
        XCTAssertTrue(LocalControlServer.isPrefetchable("e", upcoming: upcoming, depth: depth))
        XCTAssertFalse(LocalControlServer.isPrefetchable("f", upcoming: upcoming, depth: depth))
        XCTAssertFalse(LocalControlServer.isPrefetchable("nowhere", upcoming: upcoming, depth: depth))
        XCTAssertFalse(LocalControlServer.isPrefetchable("b", upcoming: [], depth: depth))
    }

    /// Deep enough to be worth having — a phone that sleeps is away for minutes, and one
    /// track of cover was the problem — and shallow enough that skipping past the window
    /// wastes only a handful of calls.
    func testThePrefetchWindowIsAFewTracksNotTheWholeQueue() {
        XCTAssertGreaterThanOrEqual(LocalControlServer.maximumPrefetchDepth, 2)
        XCTAssertLessThanOrEqual(LocalControlServer.maximumPrefetchDepth, 8)
    }

    // MARK: - Body size

    /// Swifter allocates `Content-Length` bytes up front, before reading any of the body, so
    /// an absurd value is a one-line remote crash rather than a slow upload.
    func testBodyCeilingLeavesRoomForARealRequest() {
        // The largest legitimate body is a /api/play carrying the maximum context.
        XCTAssertGreaterThan(LocalControlServer.maximumRequestBodyBytes, 1_000_000)
        XCTAssertLessThan(LocalControlServer.maximumRequestBodyBytes, 64 * 1024 * 1024)
    }
}
