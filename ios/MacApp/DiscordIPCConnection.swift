import Darwin
import Foundation
import os

/// One connection to the Discord desktop app's local RPC socket.
///
/// Plain POSIX rather than Network.framework: this is a Unix-domain stream socket in the user's
/// temporary directory, the whole protocol is length-prefixed frames, and a blocking read on a
/// thread of its own is the least machinery that does it. Reachable only because the Mac target
/// runs without the App Sandbox — a sandboxed app has a different `TMPDIR` and cannot see Discord's.
///
/// Events arrive on the main queue. Once `.closed` has been delivered the connection is finished;
/// make a new one to try again.
final class DiscordIPCConnection: @unchecked Sendable {
    enum Event {
        /// Discord accepted the handshake and will take commands.
        case ready
        /// A command failed. Discord keeps the connection open after this.
        case commandError(String)
        /// The socket is gone — Discord quit, rejected the client id, or `close()` was called.
        case closed(reason: String?)
    }

    static let logger = Logger(subsystem: "com.vvdemus", category: "discord")

    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "com.vvdemus.discord.write")
    private let onEvent: (Event) -> Void

    private init(fd: Int32, onEvent: @escaping (Event) -> Void) {
        self.fd = fd
        self.onEvent = onEvent
    }

    /// Connects to the first Discord socket that answers and sends the handshake, or returns `nil`
    /// when Discord is not running.
    static func open(clientId: String, onEvent: @escaping (Event) -> Void) -> DiscordIPCConnection? {
        let environment = ProcessInfo.processInfo.environment
        for path in DiscordIPC.socketPaths(environment: environment) where FileManager.default.fileExists(atPath: path) {
            guard let fd = connectSocket(path: path) else { continue }
            let connection = DiscordIPCConnection(fd: fd, onEvent: onEvent)
            connection.startReading()
            connection.send(DiscordIPC.handshake(clientId: clientId))
            logger.info("connected to \(path, privacy: .public)")
            return connection
        }
        return nil
    }

    func send(_ frame: Data) {
        writeQueue.async { [fd] in
            frame.withUnsafeBytes { raw in
                guard var pointer = raw.baseAddress else { return }
                var remaining = raw.count
                while remaining > 0 {
                    let written = Darwin.write(fd, pointer, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        // The reader sees the same broken socket and reports it; nothing to add.
                        return
                    }
                    pointer += written
                    remaining -= written
                }
            }
        }
    }

    /// Wakes the reader, which closes the descriptor and delivers `.closed`. Only the reader ever
    /// calls `close(2)`, so a close racing a read cannot close some other file that reused the number.
    func close() {
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    // MARK: - Private

    private static func connectSocket(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        // A write to a socket Discord has just closed would otherwise kill this whole app with
        // SIGPIPE, rather than failing the write.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            Darwin.close(fd)
            return nil
        }
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            // A socket file left behind by a Discord that crashed: it exists and refuses.
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    private func startReading() {
        let thread = Thread { [self] in readLoop() }
        thread.name = "com.vvdemus.discord.read"
        thread.start()
    }

    private func readLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        var closeReason: String?

        reading: while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            buffer.append(contentsOf: chunk[0..<count])

            while let frame = DiscordIPC.nextFrame(from: &buffer) {
                switch DiscordIPC.Opcode(rawValue: frame.opcode) {
                case .frame:
                    handle(payload: frame.payload)
                case .ping:
                    send(DiscordIPC.encode(.pong, frame.payload))
                case .close:
                    // Sent before hanging up, carrying why — most usefully "Invalid Client ID".
                    closeReason = Self.message(in: frame.payload)
                    break reading
                default:
                    continue
                }
            }
        }

        Darwin.close(fd)
        Self.logger.info("closed: \(closeReason ?? "socket ended", privacy: .public)")
        DispatchQueue.main.async { [onEvent] in onEvent(.closed(reason: closeReason)) }
    }

    private func handle(payload: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
        let event: Event?
        switch object["evt"] as? String {
        case "READY":
            event = .ready
        case "ERROR":
            let message = Self.message(in: payload) ?? "unknown error"
            Self.logger.error("\(object["cmd"] as? String ?? "command", privacy: .public) failed: \(message, privacy: .public)")
            event = .commandError(message)
        default:
            event = nil
        }
        if let event {
            DispatchQueue.main.async { [onEvent] in onEvent(event) }
        }
    }

    private static func message(in payload: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        if let data = object["data"] as? [String: Any], let message = data["message"] as? String { return message }
        return object["message"] as? String
    }
}
