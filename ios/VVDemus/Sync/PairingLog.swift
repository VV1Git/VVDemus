import Foundation
import os

/// One place every step of pairing and syncing reports to.
///
/// Pairing spans two devices, three layers (Bonjour, HTTP, the crypto) and two directions, and
/// when it fails the visible symptom is the same in every case: nothing happens. Without a trace
/// there is no way to tell "never attempted" from "attempted and refused" from "reached the peer
/// and was rejected" — a distinction that took far too long to establish the hard way.
///
/// Everything is logged `.public`. `Logger` redacts interpolated values by default, which would
/// turn exactly the useful part — the address, the peer name, the error — into `<private>`.
enum PairLog {
    private static let logger = Logger(subsystem: "com.vvdemus", category: "pairing")

    static func info(_ message: @autoclosure () -> String) {
        emit(message(), isError: false)
    }

    static func error(_ message: @autoclosure () -> String) {
        emit(message(), isError: true)
    }

    /// Written twice, on purpose.
    ///
    /// `Logger` is the right API but its `info` level is memory-only unless the system decides
    /// otherwise — `log show --info` came back empty for these, which is no use to anyone trying
    /// to find out why pairing failed. `NSLog` always reaches both the Xcode console and the log
    /// store, so it is what makes the trace reliably retrievable after the fact.
    ///
    /// The message is passed as a `%@` argument and never interpolated into the format string:
    /// these lines carry URLs and error text, and a stray `%` in them makes `NSLog` read
    /// arbitrary stack as a format argument and print garbage.
    private static func emit(_ text: String, isError: Bool) {
        if isError {
            logger.error("[VVPair] \(text, privacy: .public)")
        } else {
            logger.info("[VVPair] \(text, privacy: .public)")
        }
        NSLog("[VVPair] %@", text)
    }
}
