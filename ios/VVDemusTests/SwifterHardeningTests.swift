import Darwin
import XCTest
import Swifter

/// Covers the defects fixed in the vendored fork of Swifter (`VVDemus/Vendor/Swifter`).
///
/// Each test here corresponds to one entry in that directory's README, and each one has
/// been checked against the unfixed code — reintroduce the defect and the named test
/// fails. They deliberately exercise the library's own primitives rather than going
/// through `LocalControlServer`, because that is the only level at which most of these are
/// reachable at all.
final class SwifterHardeningTests: XCTestCase {

    // MARK: - Defect 3: close() must close a descriptor exactly once

    /// Two threads closing the same `Socket` is not a misuse here, it is the design: the
    /// app closes sockets from the main actor to wake connection threads parked in a
    /// blocking read, and those threads close them again on the way out. With an
    /// unsynchronized flag both could observe "not yet closed" and both call `close(2)`,
    /// the second one destroying whatever descriptor number the kernel had recycled in the
    /// meantime.
    func testConcurrentClosesCloseTheDescriptorExactlyOnce() throws {
        let closers = 8
        for _ in 0..<100 {
            let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            try XCTSkipIf(descriptor == -1, "could not create a socket")
            let socket = Socket(socketFileDescriptor: descriptor)

            let gate = DispatchSemaphore(value: 0)
            let finished = DispatchGroup()
            let lock = NSLock()
            var wonTheRace = 0

            // Real threads, all parked on one gate: releasing them together is what makes
            // the closes genuinely overlap. A pool would be free to run them one at a time
            // and the race would never be attempted.
            for _ in 0..<closers {
                finished.enter()
                Thread {
                    gate.wait()
                    let didClose = socket.close()
                    lock.lock()
                    if didClose { wonTheRace += 1 }
                    lock.unlock()
                    finished.leave()
                }.start()
            }
            for _ in 0..<closers { gate.signal() }
            XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)

            XCTAssertEqual(wonTheRace, 1, "close(2) must be performed by exactly one caller")
            XCTAssertTrue(socket.isClosed)
            XCTAssertFalse(socket.close(), "a later close must still be a no-op")
        }
    }

    // MARK: - Defect 4: reads are bounded and do not leak

    /// `Content-Length` (and a WebSocket frame's declared length) picks this number, and
    /// the buffer is allocated in full before any of the body has arrived — so an
    /// unbounded `read(length:)` lets anything on the Wi-Fi choose how much memory the app
    /// tries to claim.
    func testReadRefusesAnAbsurdLength() {
        let socket = Socket(socketFileDescriptor: -1)
        defer { socket.close() }

        XCTAssertThrowsError(try socket.read(length: 4_000_000_000)) { error in
            guard case SocketError.readLengthExceedsLimit(let requested, let limit)? = error as? SocketError else {
                return XCTFail("expected readLengthExceedsLimit, got \(error)")
            }
            XCTAssertEqual(requested, 4_000_000_000)
            XCTAssertEqual(limit, Socket.maximumReadLength)
        }
    }

    func testReadRefusesANegativeLength() {
        let socket = Socket(socketFileDescriptor: -1)
        defer { socket.close() }
        XCTAssertThrowsError(try socket.read(length: -1))
    }

    /// The limit is a backstop, not a policy — a body the app itself considers legal must
    /// still get through.
    func testReadAcceptsALengthTheAppConsidersLegitimate() {
        XCTAssertGreaterThan(
            Socket.maximumReadLength,
            4 * 1024 * 1024,
            "must exceed LocalControlServer.maximumRequestBodyBytes or valid requests fail down here"
        )
    }

    /// The allocation used to be freed only on the success path, so every short read — a
    /// reset peer, a timeout, a client that promised a body and sent nothing, all routine —
    /// leaked the entire client-chosen buffer.
    ///
    /// Measured with `malloc_zone_statistics` rather than the process footprint, because a
    /// buffer that is allocated and never written to costs no resident pages: the leak is
    /// invisible to any physical-memory measure but plainly visible in bytes-in-use.
    func testAFailedReadDoesNotLeakItsBuffer() throws {
        let chunk = 4 * 1024 * 1024
        let iterations = 50

        // A closed socketpair end fails the read immediately, after the buffer for the
        // full `chunk` has already been allocated — exactly the abort path that leaked.
        func failedRead() {
            var pair: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return }
            Darwin.close(pair[1])
            let socket = Socket(socketFileDescriptor: pair[0])
            defer { socket.close() }
            XCTAssertThrowsError(try socket.read(length: chunk))
        }

        // Warm up, so first-touch allocations by the machinery itself don't count.
        failedRead()

        var before = malloc_statistics_t()
        malloc_zone_statistics(nil, &before)
        for _ in 0..<iterations { failedRead() }
        var after = malloc_statistics_t()
        malloc_zone_statistics(nil, &after)

        let growth = Int(after.size_in_use) - Int(before.size_in_use)
        let leaked = chunk * iterations
        XCTAssertLessThan(
            growth,
            leaked / 4,
            "\(iterations) aborted \(chunk)-byte reads grew the heap by \(growth) bytes; the buffers are not being freed"
        )
    }

    // MARK: - Defect 4: WebSocket frame lengths

    /// A socket that replays a scripted byte stream, so frame parsing can be tested
    /// without a peer. `Socket.read()` and `read(length:)` are `open` precisely so this
    /// works.
    private final class ScriptedSocket: Socket {
        private var bytes: [UInt8]
        private var offset = 0

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
            super.init(socketFileDescriptor: -1)
        }

        override func read() throws -> UInt8 {
            guard offset < bytes.count else { throw SocketError.recvFailed("end of script") }
            defer { offset += 1 }
            return bytes[offset]
        }

        override func read(length: Int) throws -> [UInt8] {
            guard length >= 0, length <= Socket.maximumReadLength else {
                throw SocketError.readLengthExceedsLimit(requested: length, limit: Socket.maximumReadLength)
            }
            guard offset + length <= bytes.count else { throw SocketError.recvFailed("end of script") }
            defer { offset += length }
            return Array(bytes[offset..<(offset + length)])
        }
    }

    /// fin + text, masked, with an explicit 8-byte ("64-bit") length.
    private func sixtyFourBitLengthFrame(_ length: UInt64) -> [UInt8] {
        var frame: [UInt8] = [0x81, 0xFF]
        for shift in stride(from: 56, through: 0, by: -8) {
            frame.append(UInt8((length >> UInt64(shift)) & 0xFF))
        }
        frame.append(contentsOf: [0, 0, 0, 0]) // mask
        return frame
    }

    /// The most significant byte of a 64-bit length was shifted by 54 instead of 56, so
    /// any length that actually needed 64 bits decoded to a quarter of its real value.
    ///
    /// Every such length is far too large to serve, so what is asserted is the number the
    /// parser arrived at: the rejection carries the decoded length, and only a correct
    /// decode reports the length the client actually sent.
    func testA64BitFrameLengthDecodesToItsRealValue() {
        let declared: UInt64 = 1 << 56 // needs the top byte, so it exposes the wrong shift
        let session = WebSocketSession(ScriptedSocket(sixtyFourBitLengthFrame(declared)))

        XCTAssertThrowsError(try session.readFrame()) { error in
            guard case WebSocketSession.WsError.payloadTooLarge(let length, _)? = error as? WebSocketSession.WsError else {
                return XCTFail("expected payloadTooLarge, got \(error)")
            }
            XCTAssertEqual(
                length,
                declared,
                "decoded \(length) from a frame declaring \(declared) — the 64-bit length shift is wrong"
            )
        }
    }

    /// Eight 0xFF bytes decode to a length above `Int.max`, and the payload read used to
    /// convert that straight to `Int` — a trap, so any client on the network could kill
    /// the app with ten bytes.
    func testAnEnormousFrameLengthIsRejectedRatherThanTrapping() {
        let session = WebSocketSession(ScriptedSocket(sixtyFourBitLengthFrame(UInt64.max)))

        XCTAssertThrowsError(try session.readFrame()) { error in
            guard case WebSocketSession.WsError.payloadTooLarge(let length, let limit)? = error as? WebSocketSession.WsError else {
                return XCTFail("expected payloadTooLarge, got \(error)")
            }
            XCTAssertEqual(length, UInt64.max)
            XCTAssertEqual(limit, WebSocketSession.maximumPayloadLength)
        }
    }

    /// The fix must not have broken ordinary frames, which is all the web remote sends.
    func testAnOrdinaryMaskedTextFrameStillParses() throws {
        let mask: [UInt8] = [0x11, 0x22, 0x33, 0x44]
        let payload = Array("hello:tab-1".utf8)
        var frame: [UInt8] = [0x81, 0x80 | UInt8(payload.count)]
        frame.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() { frame.append(byte ^ mask[index % 4]) }

        let session = WebSocketSession(ScriptedSocket(frame))
        let parsed = try session.readFrame()

        XCTAssertTrue(parsed.fin)
        XCTAssertEqual(parsed.opcode, .text)
        XCTAssertEqual(String(decoding: parsed.payload, as: UTF8.self), "hello:tab-1")
    }

    /// 126 selects the 2-byte length, which shares the code path that was edited.
    func testA16BitFrameLengthStillDecodes() throws {
        let payload = [UInt8](repeating: 0x5A, count: 300)
        var frame: [UInt8] = [0x82, 0xFE, UInt8(300 >> 8), UInt8(300 & 0xFF)]
        frame.append(contentsOf: [0, 0, 0, 0])
        frame.append(contentsOf: payload)

        let parsed = try WebSocketSession(ScriptedSocket(frame)).readFrame()
        XCTAssertEqual(parsed.payload.count, 300)
        XCTAssertEqual(parsed.opcode, .binary)
    }

    // MARK: - Defect 1: transient vs fatal accept() failures

    /// `accept()` failing is mostly routine. Treating every failure as terminal is what
    /// made one reset peer — a laptop closing its lid at the wrong moment — take the whole
    /// server down until the user toggled Connect off and on.
    func testRoutineAcceptFailuresAreRetriedNotFatal() {
        for code in [ECONNABORTED, EINTR, EPROTO, EAGAIN, ETIMEDOUT, ECONNRESET, ENETDOWN, EHOSTUNREACH] {
            XCTAssertEqual(
                HttpServerIO.disposition(forAcceptErrno: code),
                .retry,
                "errno \(code) (\(String(cString: strerror(code)))) is transient and must not stop the server"
            )
        }
    }

    /// Out of descriptors is also transient, but retrying flat out would just burn a core
    /// until something else releases one.
    func testDescriptorExhaustionBacksOff() {
        for code in [EMFILE, ENFILE, ENOBUFS, ENOMEM] {
            XCTAssertEqual(HttpServerIO.disposition(forAcceptErrno: code), .backOff, "errno \(code)")
        }
    }

    /// The other half of the fix: an unusable listening socket must still stop the loop,
    /// or `stop()` would leave a thread spinning on accept() forever.
    func testAnUnusableListeningSocketIsFatal() {
        for code in [EBADF, EINVAL, ENOTSOCK, EOPNOTSUPP] {
            XCTAssertEqual(HttpServerIO.disposition(forAcceptErrno: code), .fatal, "errno \(code)")
        }
    }

    /// The errno has to survive the trip out of `acceptClientSocket()` for any of the
    /// above to matter; it used to be flattened into a `strerror` string.
    func testAcceptFailureCarriesItsErrno() {
        // Not a socket at all, so accept() fails with a predictable ENOTSOCK.
        let descriptor = Darwin.open("/dev/null", O_RDONLY)
        defer { Darwin.close(descriptor) }
        let notASocket = Socket(socketFileDescriptor: descriptor)

        XCTAssertThrowsError(try notASocket.acceptClientSocket()) { error in
            guard case SocketError.acceptFailed(let code, _)? = error as? SocketError else {
                return XCTFail("expected acceptFailed, got \(error)")
            }
            XCTAssertEqual(code, ENOTSOCK)
            XCTAssertEqual(HttpServerIO.disposition(forAcceptErrno: code), .fatal)
        }
    }

    // MARK: - Defect 5: the connection cap

    /// Past the cap the server answers 503 and closes, instead of accepting a connection
    /// there is no thread left in the global pool to serve.
    func testConnectionsPastTheCapAreRefusedNotQueued() throws {
        let server = HttpServer()
        server.maximumConcurrentConnections = 2

        let release = DispatchSemaphore(value: 0)
        let occupied = DispatchSemaphore(value: 0)
        server["/hold"] = { _ in
            occupied.signal()
            release.wait()
            return .ok(.text("done"))
        }

        try server.start(0, forceIPv4: true, priority: .userInitiated)
        let port = UInt16(try server.port())
        defer {
            release.signal()
            release.signal()
            server.stop()
        }

        // Fill both slots, waiting for each handler to actually be running so the third
        // connection cannot slip in before the server is genuinely at capacity.
        var held: [Int32] = []
        defer { held.forEach { Darwin.close($0) } }
        for _ in 0..<2 {
            let descriptor = try connect(toPort: port)
            held.append(descriptor)
            send(descriptor, "GET /hold HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            XCTAssertEqual(occupied.wait(timeout: .now() + 5), .success, "handler never started")
        }
        XCTAssertEqual(server.connectionCount, 2)

        let overflow = try connect(toPort: port)
        defer { Darwin.close(overflow) }
        send(overflow, "GET /hold HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

        let reply = receive(overflow)
        XCTAssertTrue(
            reply.hasPrefix("HTTP/1.1 503"),
            "expected a 503 past the cap, got: \(reply.prefix(60))"
        )
    }

    /// And the cap must not be a leak of its own: a served connection has to give its slot
    /// back, or a server that has answered `maximumConcurrentConnections` requests over
    /// its whole life starts refusing everything.
    func testFinishedConnectionsReleaseTheirSlot() throws {
        let server = HttpServer()
        server.maximumConcurrentConnections = 2
        server["/ping"] = { _ in .ok(.text("pong")) }

        try server.start(0, forceIPv4: true, priority: .userInitiated)
        let port = UInt16(try server.port())
        defer { server.stop() }

        // Six requests through a two-slot server: only possible if each one hands its slot
        // back. Checked between requests as well as counted, so a leak is caught on the
        // iteration that causes it rather than three iterations later.
        for attempt in 1...6 {
            let descriptor = try connect(toPort: port)
            send(descriptor, "GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
            let reply = receive(descriptor)
            Darwin.close(descriptor)
            XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200"), "request \(attempt) got: \(reply.prefix(60))")
            XCTAssertTrue(
                waitUntil({ server.connectionCount == 0 }),
                "slot not released after request \(attempt)"
            )
        }
    }

    /// Every accepted connection gets a read deadline, which is what stops a peer that
    /// vanished without closing from owning a thread for the life of the process.
    func testAcceptedConnectionsGetAReadTimeout() throws {
        XCTAssertGreaterThan(Socket.receiveTimeout, 45, "must exceed LocalControlServer's own 45s socket pruning")

        let server = HttpServer()
        server["/ping"] = { _ in .ok(.text("pong")) }
        try server.start(0, forceIPv4: true, priority: .userInitiated)
        let port = UInt16(try server.port())
        defer { server.stop() }

        // Kept alive on purpose: the server's end has to still be open to be inspected.
        let descriptor = try connect(toPort: port)
        defer { Darwin.close(descriptor) }
        send(descriptor, "GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n")
        _ = receive(descriptor)

        XCTAssertTrue(hasReceiveTimeout(anyOf: port), "no accepted socket carried SO_RCVTIMEO")
    }

    // MARK: - Defect 2: stop() must actually close every live connection

    /// Eight connections parked in a blocking read — the ordinary state of a browser's
    /// keep-alive pool — and then `stop()`. Every one of them has to be closed, which is
    /// only true if `stop()` sees the whole set: it used to iterate `sockets` with no
    /// synchronization at all while the accept loop inserted into it on other threads, so
    /// a connection could be skipped (thread and descriptor held for the life of the
    /// process) or the iteration could fault outright.
    ///
    /// A held slot is the observable consequence, so that is what is asserted.
    func testStopClosesEveryLiveConnection() throws {
        let server = HttpServer()
        server["/ping"] = { _ in .ok(.text("pong")) }
        try server.start(0, forceIPv4: true, priority: .userInitiated)
        let port = UInt16(try server.port())

        var clients: [Int32] = []
        defer { clients.forEach { Darwin.close($0) } }
        for _ in 0..<8 {
            let descriptor = try connect(toPort: port)
            clients.append(descriptor)
            send(descriptor, "GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n")
            XCTAssertTrue(receive(descriptor).hasPrefix("HTTP/1.1 200"))
        }
        // All eight are now parked server-side waiting for another request line.
        XCTAssertTrue(waitUntil({ server.connectionCount == 8 }), "expected 8 live connections, got \(server.connectionCount)")

        server.stop()

        XCTAssertFalse(server.operating)
        XCTAssertTrue(
            waitUntil({ server.connectionCount == 0 }, timeout: 10),
            "\(server.connectionCount) connection(s) survived stop() — their sockets were never closed"
        )
        // And the peers must see it, not just the bookkeeping.
        for descriptor in clients {
            XCTAssertTrue(awaitEOF(descriptor), "a client was left with an open connection after stop()")
        }
    }

    /// Repeated start/stop with traffic in flight, which is the shape that turns "a Set
    /// mutated while being iterated" into a crash rather than a silently skipped element.
    /// Probabilistic by nature — it is here to catch the fault, not to prove its absence.
    func testStoppingUnderLoadIsRepeatable() throws {
        for _ in 0..<2 {
            let server = HttpServer()
            server["/ping"] = { _ in .ok(.text("pong")) }
            try server.start(0, forceIPv4: true, priority: .userInitiated)
            let port = UInt16(try server.port())

            // Real threads rather than a pool: these deliberately stay busy until the
            // server goes away, and a pool would just run out of width.
            let done = DispatchGroup()
            for _ in 0..<3 {
                done.enter()
                Thread {
                    defer { done.leave() }
                    guard let descriptor = try? self.connect(toPort: port) else { return }
                    defer { Darwin.close(descriptor) }
                    let deadline = Date().addingTimeInterval(20)
                    while Date() < deadline {
                        // Keep-alive on purpose: without it Swifter answers once and hangs
                        // up, and nothing is ever live at the moment stop() runs.
                        self.send(descriptor, "GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n")
                        if self.receive(descriptor).isEmpty { return }
                    }
                }.start()
            }

            // Stop while the connections are genuinely live and the accept loop is still
            // inserting into the very set stop() is about to walk.
            XCTAssertTrue(waitUntil({ server.connectionCount >= 2 }, timeout: 20), "clients never connected")
            server.stop()
            XCTAssertEqual(done.wait(timeout: .now() + 15), .success, "clients hung after stop()")
            XCTAssertTrue(waitUntil({ server.connectionCount == 0 }, timeout: 10))
        }
    }

    // MARK: - Defect 6: the WebSocket read loop must observe shutdown

    /// Serves valid frames forever, so the WebSocket read loop's *only* way out is to
    /// notice that the socket was closed underneath it.
    ///
    /// Rather than hanging when it does not, the socket starts failing once it has fed a
    /// large number of frames past the close, and records that it had to — a hung read
    /// loop then shows up as a clear assertion instead of a timeout and a spinning thread.
    private final class EndlessFrameSocket: Socket {
        let startedReading = DispatchSemaphore(value: 0)
        private(set) var keptReadingAfterClose = false

        /// fin + pong, masked, empty payload. Pong is the one opcode that neither writes
        /// back nor allocates.
        private let frame: [UInt8] = [0x8A, 0x80, 0x00, 0x00, 0x00, 0x00]
        private let lock = NSLock()
        private var offset = 0
        private var announced = false
        private var bytesAfterClose = 0

        init() { super.init(socketFileDescriptor: -1) }

        override func read() throws -> UInt8 {
            let closed = isClosed
            lock.lock()
            defer { lock.unlock() }
            if !announced {
                announced = true
                startedReading.signal()
            }
            if closed {
                bytesAfterClose += 1
                if bytesAfterClose > 6 * 100_000 {
                    keptReadingAfterClose = true
                    throw SocketError.recvFailed("the read loop never noticed the close")
                }
            }
            defer { offset = (offset + 1) % frame.count }
            return frame[offset]
        }

        override func read(length: Int) throws -> [UInt8] {
            return [UInt8](repeating: 0, count: max(0, length))
        }
    }

    /// The loop was `while true`. A connection accepted in the instant before `stop()` is
    /// never registered, so `stop()` never closes it — and with nothing else to end the
    /// loop it holds a thread and a descriptor for the life of the process.
    func testAWebSocketReadLoopStopsWhenItsSocketIsClosed() throws {
        let request = HttpRequest()
        request.headers = [
            "upgrade": "websocket",
            "connection": "upgrade",
            "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
        ]
        guard case .switchProtocols(_, let runSession) = websocket(pong: { _, _ in })(request) else {
            return XCTFail("the websocket handler refused to upgrade")
        }

        let socket = EndlessFrameSocket()
        let returned = expectation(description: "the read loop returned")
        DispatchQueue.global().async {
            runSession(socket)
            returned.fulfill()
        }

        XCTAssertEqual(socket.startedReading.wait(timeout: .now() + 10), .success, "the loop never started")
        // Exactly what LocalControlServer.pruneStaleSockets does to a tab it has given up
        // on, and what HttpServerIO.stop() does to every connection it knows about.
        socket.close()

        wait(for: [returned], timeout: 20)
        XCTAssertFalse(
            socket.keptReadingAfterClose,
            "the read loop kept parsing frames after its socket was closed"
        )
    }

    // MARK: - Raw socket helpers
    //
    // Deliberately not URLSession: these tests need to hold connections open, send
    // half-formed requests and count what the server does with them, none of which a
    // pooling, connection-reusing HTTP client will let you control.

    /// Polls rather than sleeping a fixed amount: these are handoffs between threads, and
    /// a fixed sleep is either flaky or slow.
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }

    private func connect(toPort port: UInt16) throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor != -1 else { throw XCTSkip("could not create a client socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw XCTSkip("could not connect to 127.0.0.1:\(port)")
        }
        // So a test can never hang the whole suite on a server that never answers.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // Several of these tests write to a connection the server has just closed, which is
        // the point; without this that raises SIGPIPE and takes the whole test runner down
        // instead of returning EPIPE.
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }

    private func send(_ descriptor: Int32, _ text: String) {
        var bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }

    private func receive(_ descriptor: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return "" }
        return String(decoding: buffer[0..<count], as: UTF8.self)
    }

    /// Drains whatever is still buffered and reports whether the peer then closed.
    /// Distinguishes a real EOF (`read` returns 0) from a read that simply timed out with
    /// the connection still open, which is the whole question being asked.
    private func awaitEOF(_ descriptor: Int32, timeout: TimeInterval = 5) -> Bool {
        var deadline = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return true }
            if count < 0 { return false }
        }
    }

    /// Walks this process's descriptors looking for a connected TCP socket whose local
    /// port is the server's — i.e. the server side of an accepted connection — and reports
    /// whether it carries a receive timeout.
    private func hasReceiveTimeout(anyOf port: UInt16) -> Bool {
        for descriptor in 0..<Int32(getdtablesize()) {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            guard named == 0, address.sin_family == sa_family_t(AF_INET) else { continue }
            guard address.sin_port.bigEndian == port else { continue }

            // The listening socket has no peer; only accepted connections do.
            var peer = sockaddr_in()
            var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let hasPeer = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getpeername(descriptor, $0, &peerLength)
                }
            }
            guard hasPeer == 0 else { continue }

            var timeout = timeval()
            var size = socklen_t(MemoryLayout<timeval>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, &size) == 0 else { continue }
            if timeout.tv_sec > 0 || timeout.tv_usec > 0 { return true }
        }
        return false
    }
}
