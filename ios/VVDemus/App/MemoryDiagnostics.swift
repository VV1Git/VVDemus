import Foundation
import UIKit
import os

/// Periodically logs the app's actual resident memory footprint via `os.Logger`, viewable
/// live in Console.app (filter: subsystem "com.vvdemus.app", category "memory") while the
/// phone is connected, or afterward via Console.app > Devices > [phone] > collected logs.
/// Exists so a future "the app got killed for memory again" report comes with a real trend
/// line instead of a single after-the-fact crash report with no history.
enum MemoryDiagnostics {
    private static let logger = Logger(subsystem: "com.vvdemus.app", category: "memory")
    private static var timer: Timer?

    static func startLogging(interval: TimeInterval = 60) {
        guard timer == nil else { return }
        logNow(note: "app launch")
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            logNow(note: "periodic")
        }
        // Fires while iOS is under memory pressure, before it resorts to killing the app —
        // the clearest signal available that a session is heading toward another jetsam.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            logNow(note: "MEMORY WARNING")
        }
    }

    static func logNow(note: String) {
        guard let megabytes = residentMemoryMB() else { return }
        logger.notice("footprint: \(megabytes, format: .fixed(precision: 1)) MB (\(note, privacy: .public))")
    }

    private static func residentMemoryMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / 1024 / 1024
    }
}
