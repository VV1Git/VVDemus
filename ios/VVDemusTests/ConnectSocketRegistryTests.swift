import Swifter
import XCTest
@testable import VVDemus

/// The bookkeeping behind every connected browser tab.
///
/// Swifter's `Socket` hashes and compares on `socketFileDescriptor` alone and
/// `WebSocketSession` forwards both to it, so two unrelated sessions are `==` as soon as
/// the kernel reissues a descriptor number — which it does at the first opportunity,
/// because `accept` always returns the lowest free one. These tests build that collision
/// deliberately (two sessions over the same descriptor number) rather than hoping to
/// provoke it through real sockets.
@MainActor
final class ConnectSocketRegistryTests: XCTestCase {
    /// Descriptor numbers well past anything the process has open, so the `close()` in
    /// `Socket.deinit` is a harmless `EBADF` rather than closing a file something is using.
    private func session(fd: Int32) -> WebSocketSession {
        WebSocketSession(Socket(socketFileDescriptor: fd))
    }

    /// The premise the rest of this file rests on. If Swifter ever starts comparing by
    /// identity, the collisions below stop being reachable and these tests should be
    /// revisited rather than quietly passing for the wrong reason.
    func testTwoSessionsOverTheSameDescriptorCompareEqual() {
        let first = session(fd: 900_001)
        let second = session(fd: 900_001)
        XCTAssertFalse(first === second)
        XCTAssertEqual(first, second, "Swifter compares WebSocketSessions by file descriptor")
        XCTAssertEqual(first.hashValue, second.hashValue)
    }

    /// The bug: a `disconnected` callback for a socket that was closed moments ago arriving
    /// after a new browser has picked up its descriptor. Keyed by descriptor, that removal
    /// deregistered the *live* tab, which then stayed open, never got another broadcast,
    /// and could not re-register itself (the text handler only refreshes sessions that are
    /// still registered).
    func testALateDisconnectForARecycledDescriptorLeavesTheLiveTabRegistered() {
        let registry = WebSocketRegistry()
        let closed = session(fd: 900_002)
        let reconnected = session(fd: 900_002)

        registry.insert(closed, at: Date())
        registry.remove(closed)
        registry.insert(reconnected, at: Date())
        registry.setClientId("tab-live", for: reconnected)

        // The stale callback for the socket closed above.
        registry.remove(closed)

        XCTAssertTrue(registry.contains(reconnected), "The live tab was orphaned by a stale disconnect")
        XCTAssertEqual(registry.count, 1)
        XCTAssertEqual(registry.clientId(for: reconnected), "tab-live")
        XCTAssertTrue(registry.hasSession(clientId: "tab-live"))
        XCTAssertEqual(registry.broadcastTargets().count, 1, "An orphaned tab is never broadcast to again")
    }

    /// Two tabs alive at once over recycled descriptors have to stay two tabs. Keyed by
    /// descriptor the second insert silently replaced the first, so the older tab vanished
    /// from every broadcast the moment a new one connected.
    func testTwoLiveSessionsSharingADescriptorAreBothKept() {
        let registry = WebSocketRegistry()
        let first = session(fd: 900_003)
        let second = session(fd: 900_003)

        registry.insert(first, at: Date())
        registry.setClientId("tab-a", for: first)
        registry.insert(second, at: Date())
        registry.setClientId("tab-b", for: second)

        XCTAssertEqual(registry.count, 2)
        XCTAssertEqual(registry.clientId(for: first), "tab-a")
        XCTAssertEqual(registry.clientId(for: second), "tab-b")
        XCTAssertEqual(registry.broadcastTargets().count, 2)
    }

    /// Liveness is per connection too. A heartbeat on the new socket must not be credited
    /// to the old one, and — more importantly — must not be *lost* because the old one
    /// happens to own the descriptor.
    func testHeartbeatsAreAttributedPerConnectionNotPerDescriptor() {
        let registry = WebSocketRegistry()
        let now = Date()
        let old = session(fd: 900_004)
        let new = session(fd: 900_004)

        registry.insert(old, at: now.addingTimeInterval(-120))
        registry.setClientId("tab-x", for: old)
        registry.insert(new, at: now)
        registry.setClientId("tab-x", for: new)

        // The freshest connection for the tab is what its liveness is judged on.
        XCTAssertEqual(registry.heartbeatAge(clientId: "tab-x", now: now), 0, accuracy: 0.5)
        XCTAssertEqual(registry.lastSeen(for: old)?.timeIntervalSince(now) ?? 0, -120, accuracy: 0.5)
    }

    /// Everything about a connection goes away together. It used to be four separate
    /// collections and the pruner only cleaned two of them, so the client id, the write
    /// queue and the `WebSocketSession` they retained leaked on every dropped tab.
    func testRemovingASessionDropsAllOfItsBookkeeping() {
        let registry = WebSocketRegistry()
        let only = session(fd: 900_005)
        registry.insert(only, at: Date())
        registry.setClientId("tab-y", for: only)

        registry.remove(only)

        XCTAssertNil(registry.clientId(for: only))
        XCTAssertNil(registry.lastSeen(for: only))
        XCTAssertFalse(registry.hasSession(clientId: "tab-y"))
        XCTAssertTrue(registry.broadcastTargets().isEmpty)
        XCTAssertTrue(registry.isEmpty)
    }

    /// A frame that lost the race with `remove` must not resurrect a half-entry: the
    /// pruner would never see it again, so it would sit there being broadcast to forever.
    func testTouchingAnUnregisteredSessionDoesNothing() {
        let registry = WebSocketRegistry()
        let gone = session(fd: 900_006)

        registry.touch(gone, at: Date())
        registry.setClientId("ghost", for: gone)

        XCTAssertTrue(registry.isEmpty)
        XCTAssertFalse(registry.hasSession(clientId: "ghost"))
    }

    func testStalenessIsMeasuredPerConnection() {
        let registry = WebSocketRegistry()
        let now = Date()
        let quiet = session(fd: 900_007)
        let chatty = session(fd: 900_008)
        registry.insert(quiet, at: now.addingTimeInterval(-60))
        registry.insert(chatty, at: now)

        let stale = registry.staleSessions(before: now.addingTimeInterval(-45))
        XCTAssertEqual(stale.count, 1)
        XCTAssertTrue(stale.first === quiet)
    }

    func testAnUnknownClientHasNoHeartbeat() {
        let registry = WebSocketRegistry()
        XCTAssertEqual(registry.heartbeatAge(clientId: "nobody", now: Date()), .infinity)
    }
}
