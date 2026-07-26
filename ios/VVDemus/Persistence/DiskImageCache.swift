import Foundation

/// Disk-backed companion to `RemoteImage`'s in-memory cache. Without this, every app
/// relaunch re-downloaded every thumbnail from scratch, even ones already seen thousands
/// of times — the in-memory `NSCache` only helps within a single running session.
/// Keyed by whatever string the caller passes (URL + requested pixel size), so a small
/// row thumbnail and a large hero image for the same track are stored as separate files
/// instead of one overwriting the other.
actor DiskImageCache {
    static let shared = DiskImageCache()

    private let directory: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("ImageCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        directory = dir
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(String(abs(key.hashValue), radix: 16))
    }

    func data(for key: String) -> Data? {
        try? Data(contentsOf: fileURL(for: key))
    }

    func store(_ data: Data, for key: String) {
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    func clear() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}
