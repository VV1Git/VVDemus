//
//  HttpServer.swift
//  Swifter
//
//  Copyright (c) 2014-2016 Damian Kołakowski. All rights reserved.
//

import Foundation
import Dispatch

public protocol HttpServerIODelegate: class {
    func socketConnectionReceived(_ socket: Socket)
}

open class HttpServerIO {

    public weak var delegate: HttpServerIODelegate?

    private var socket = Socket(socketFileDescriptor: -1)
    private var sockets = Set<Socket>()

    public enum HttpServerIOState: Int32 {
        case starting
        case running
        case stopping
        case stopped
    }

    // VVDemus fork: guards `stateValue`. See `state`.
    private let stateLock = NSLock()
    private var stateValue: Int32 = HttpServerIOState.stopped.rawValue

    /// VVDemus fork fix: the setter was
    ///     OSAtomicCompareAndSwapInt(self.state.rawValue, state.rawValue, &stateValue)
    /// which reads `stateValue` through the getter while simultaneously passing it `inout`
    /// to the compare-and-swap — an exclusivity violation Thread Sanitizer flags on every
    /// start/stop, and worse than cosmetic: if the value changes between the read and the
    /// swap the CAS simply fails and the transition is *lost*. A dropped `.stopped` leaves
    /// a server that has shut down still reporting `operating == true`, which is exactly
    /// the state `LocalControlServer.restartIfAcceptLoopDied` relies on to notice trouble.
    /// A plain guarded store cannot lose a write.
    public private(set) var state: HttpServerIOState {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return HttpServerIOState(rawValue: stateValue)!
        }
        set(state) {
            stateLock.lock()
            stateValue = state.rawValue
            stateLock.unlock()
        }
    }

    public var operating: Bool { return self.state == .running }

    /// String representation of the IPv4 address to receive requests from.
    /// It's only used when the server is started with `forceIPv4` option set to true.
    /// Otherwise, `listenAddressIPv6` will be used.
    public var listenAddressIPv4: String?

    /// String representation of the IPv6 address to receive requests from.
    /// It's only used when the server is started with `forceIPv4` option set to false.
    /// Otherwise, `listenAddressIPv4` will be used.
    public var listenAddressIPv6: String?

    private let queue = DispatchQueue(label: "swifter.httpserverio.clientsockets")

    /// Largest number of connections served at once; anything beyond this is answered with
    /// a 503 and closed straight away.
    ///
    /// VVDemus fork addition. Each connection holds one `DispatchQueue.global` thread for
    /// as long as it lives, and that pool tops out around 64 threads for the whole process.
    /// A browser alone opens up to six keep-alive sockets plus a WebSocket per tab, so a
    /// couple of stale tabs used to be enough to exhaust the pool — at which point work
    /// stops being scheduled *anywhere* in the app while this loop cheerfully keeps
    /// accepting more. Refusing politely is much better than wedging the process.
    public var maximumConcurrentConnections = 32

    private var activeConnections = 0

    /// - Returns: true if a slot was taken, false if the server is already at capacity.
    private func acquireConnectionSlot() -> Bool {
        return queue.sync {
            guard activeConnections < maximumConcurrentConnections else { return false }
            activeConnections += 1
            return true
        }
    }

    private func releaseConnectionSlot() {
        queue.sync { activeConnections = max(0, activeConnections - 1) }
    }

    /// Connections currently being served. Exposed for tests.
    public var connectionCount: Int {
        return queue.sync { activeConnections }
    }

    public func port() throws -> Int {
        return Int(try socket.port())
    }

    public func isIPv4() throws -> Bool {
        return try socket.isIPv4()
    }

    deinit {
        stop()
    }

    @available(macOS 10.10, *)
    public func start(_ port: in_port_t = 8080, forceIPv4: Bool = false, priority: DispatchQoS.QoSClass = DispatchQoS.QoSClass.background) throws {
        guard !self.operating else { return }
        stop()
        self.state = .starting
        let address = forceIPv4 ? listenAddressIPv4 : listenAddressIPv6
        self.socket = try Socket.tcpSocketForListen(port, forceIPv4, SOMAXCONN, address)
        self.state = .running
        DispatchQueue.global(qos: priority).async { [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.operating else { return }
            // VVDemus fork fix: this was
            //     while let socket = try? strongSelf.socket.acceptClientSocket()
            // which turned *every* accept() failure into "leave the loop", followed by
            // `stop()` closing the listening socket. Most accept() failures are routine —
            // ECONNABORTED when a peer resets between SYN and accept (which is what a
            // sleeping laptop or a flapping Wi-Fi link looks like), EINTR, or EMFILE when
            // the process is momentarily out of descriptors. Any one of them permanently
            // killed the server, silently, until the user toggled Connect off and on.
            var consecutiveFailures = 0
            acceptLoop: while strongSelf.operating {
                let socket: Socket
                do {
                    socket = try strongSelf.socket.acceptClientSocket()
                    consecutiveFailures = 0
                } catch SocketError.acceptFailed(let code, let description) {
                    consecutiveFailures += 1
                    switch HttpServerIO.disposition(forAcceptErrno: code) {
                    case .retry:
                        // A guard against an unforeseen error that repeats immediately:
                        // retrying is right, spinning a core to do it is not.
                        if consecutiveFailures > 8 {
                            Thread.sleep(forTimeInterval: 0.05)
                        }
                        continue acceptLoop
                    case .backOff:
                        // Out of file descriptors. Nothing will change until something
                        // else releases one, so wait a little — longer each time, capped —
                        // rather than hammering accept().
                        Thread.sleep(forTimeInterval: min(0.05 * Double(consecutiveFailures), 1.0))
                        continue acceptLoop
                    case .fatal:
                        // The listening socket itself is unusable (EBADF after stop(),
                        // EINVAL, ENOTSOCK); retrying would loop forever.
                        print("Swifter: accept() failed and cannot be retried: \(description)")
                        break acceptLoop
                    }
                } catch {
                    print("Swifter: accept() failed: \(error)")
                    break acceptLoop
                }

                // VVDemus fork fix: refuse politely once the thread pool would be at risk,
                // instead of accepting connections there is no thread left to serve.
                guard strongSelf.acquireConnectionSlot() else {
                    strongSelf.rejectOverCapacity(socket)
                    continue acceptLoop
                }

                DispatchQueue.global(qos: priority).async { [weak self] in
                    guard let strongSelf = self else {
                        socket.close()
                        return
                    }
                    defer { strongSelf.releaseConnectionSlot() }
                    guard strongSelf.operating else {
                        socket.close()
                        return
                    }
                    // VVDemus fork fix: registered synchronously, and only while the server
                    // is still running. It used to be a `queue.async` insert, so a socket
                    // accepted in the instant before stop() could land in the set *after*
                    // stop() had emptied it — never closed, thread and descriptor held for
                    // the life of the process.
                    var registered = false
                    strongSelf.queue.sync {
                        guard strongSelf.operating else { return }
                        strongSelf.sockets.insert(socket)
                        registered = true
                    }
                    guard registered else {
                        socket.close()
                        return
                    }

                    strongSelf.handleConnection(socket)

                    strongSelf.queue.sync {
                        _ = strongSelf.sockets.remove(socket)
                    }
                }
            }
            strongSelf.stop()
        }
    }

    /// What the accept loop should do about a given `accept(2)` errno.
    ///
    /// VVDemus fork addition. Split out as a pure function of the errno so the
    /// transient-versus-fatal decision — the whole point of the fix — can be tested
    /// without provoking real kernel errors.
    public enum AcceptDisposition: Equatable {
        /// Routine, per-connection failure: try again immediately.
        case retry
        /// Resource exhaustion: try again, but pause first.
        case backOff
        /// The listening socket is gone: give up.
        case fatal
    }

    public static func disposition(forAcceptErrno code: Int32) -> AcceptDisposition {
        switch code {
        case ECONNABORTED, EINTR, EPROTO, EAGAIN, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH, ETIMEDOUT, ECONNRESET:
            return .retry
        case EMFILE, ENFILE, ENOBUFS, ENOMEM:
            return .backOff
        default:
            // EBADF, EINVAL, ENOTSOCK, EOPNOTSUPP, EFAULT — the listening socket cannot
            // serve another connection no matter how many times it is asked.
            return .fatal
        }
    }

    /// VVDemus fork addition: answers a connection that arrived over the concurrency cap.
    /// Written straight from the accept thread (it is ~70 bytes, well inside any send
    /// buffer) so no thread has to be found for a connection that is about to be dropped.
    private func rejectOverCapacity(_ socket: Socket) {
        try? socket.writeUTF8("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        socket.close()
    }

    public func stop() {
        guard self.operating else { return }
        self.state = .stopping
        // Shutdown connected peers because they can live in 'keep-alive' or 'websocket' loops.
        //
        // VVDemus fork fix: this used to iterate `self.sockets` with no synchronization at
        // all, while the accept loop inserted into and removed from it on another thread —
        // a Set mutated during iteration, i.e. a crash or a silently skipped (and so
        // leaked) descriptor. The snapshot and the clear now happen together under the
        // same queue that guards every other access; the closes happen outside it, since
        // close(2) has no business running under a lock other threads need.
        let live: Set<Socket> = self.queue.sync {
            let snapshot = self.sockets
            self.sockets.removeAll(keepingCapacity: true)
            return snapshot
        }
        for socket in live {
            socket.close()
        }
        socket.close()
        self.state = .stopped
    }

    open func dispatch(_ request: HttpRequest) -> ([String: String], (HttpRequest) -> HttpResponse) {
        return ([:], { _ in HttpResponse.notFound })
    }

    private func handleConnection(_ socket: Socket) {
        let parser = HttpParser()
        while self.operating, let request = try? parser.readHttpRequest(socket) {
            let request = request
            request.address = try? socket.peername()
            let (params, handler) = self.dispatch(request)
            request.params = params
            let response = handler(request)
            var keepConnection = parser.supportsKeepAlive(request.headers)
            do {
                if self.operating {
                    keepConnection = try self.respond(socket, response: response, keepAlive: keepConnection)
                }
            } catch {
                print("Failed to send response: \(error)")
            }
            if let session = response.socketSession() {
                delegate?.socketConnectionReceived(socket)
                session(socket)
                break
            }
            if !keepConnection { break }
        }
        socket.close()
    }

    private struct InnerWriteContext: HttpResponseBodyWriter {

        let socket: Socket

        func write(_ file: String.File) throws {
            try socket.writeFile(file)
        }

        func write(_ data: [UInt8]) throws {
            try write(ArraySlice(data))
        }

        func write(_ data: ArraySlice<UInt8>) throws {
            try socket.writeUInt8(data)
        }

        func write(_ data: NSData) throws {
            try socket.writeData(data)
        }

        func write(_ data: Data) throws {
            try socket.writeData(data)
        }
    }

    private func respond(_ socket: Socket, response: HttpResponse, keepAlive: Bool) throws -> Bool {
        guard self.operating else { return false }

        // Some web-socket clients (like Jetfire) expects to have header section in a single packet.
        // We can't promise that but make sure we invoke "write" only once for response header section.

        var responseHeader = String()

        responseHeader.append("HTTP/1.1 \(response.statusCode) \(response.reasonPhrase)\r\n")

        let content = response.content()

        if content.length >= 0 {
            responseHeader.append("Content-Length: \(content.length)\r\n")
        }

        if keepAlive && content.length != -1 {
            responseHeader.append("Connection: keep-alive\r\n")
        }

        for (name, value) in response.headers() {
            responseHeader.append("\(name): \(value)\r\n")
        }

        responseHeader.append("\r\n")

        try socket.writeUTF8(responseHeader)

        if let writeClosure = content.write {
            let context = InnerWriteContext(socket: socket)
            try writeClosure(context)
        }

        return keepAlive && content.length != -1
    }
}
