import CryptoKit
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
    /// Roughly a few thousand thumbnails. Past this, the least recently *read* files are
    /// deleted. Without a cap the directory grew for the lifetime of the install; iOS
    /// would eventually purge the whole Caches directory under disk pressure, which is
    /// precisely when the cache was most worth having.
    private let maximumBytes: Int64 = 200 * 1024 * 1024
    /// Tracked so the sweep doesn't have to stat the directory on every single write.
    private var bytesWrittenSinceSweep: Int64 = 0
    private let sweepInterval: Int64 = 10 * 1024 * 1024

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

    /// SHA-256 of the key, not `hashValue`.
    ///
    /// `String.hashValue` is salted with a per-process random seed, so the same URL mapped
    /// to a different filename on every launch: nothing ever hit, every thumbnail was
    /// re-downloaded, and each launch left behind a fresh duplicate copy of the entire
    /// image set. The class existed to prevent exactly that. (`abs(Int.min)` also traps,
    /// and truncating to `Int` invited collisions between differently-sized variants.)
    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.compactMap { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    func data(for key: String) -> Data? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Touch the access date so the eviction sweep can tell hot entries from cold ones.
        var values = URLResourceValues()
        values.contentAccessDate = Date()
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
        return data
    }

    func store(_ data: Data, for key: String) {
        guard !data.isEmpty else { return }
        try? data.write(to: fileURL(for: key), options: .atomic)
        bytesWrittenSinceSweep += Int64(data.count)
        if bytesWrittenSinceSweep >= sweepInterval {
            bytesWrittenSinceSweep = 0
            evictIfNeeded()
        }
    }

    func clear() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
        bytesWrittenSinceSweep = 0
    }

    func totalBytes() -> Int64 {
        entries().reduce(0) { $0 + $1.size }
    }

    private struct Entry {
        let url: URL
        let size: Int64
        let accessed: Date
    }

    private func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ) else { return [] }
        return files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let accessed = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            return Entry(url: url, size: Int64(values.fileSize ?? 0), accessed: accessed)
        }
    }

    /// Least-recently-accessed first, down to 80% of the cap so this doesn't run again on
    /// the very next write.
    private func evictIfNeeded() {
        let all = entries()
        var total = all.reduce(Int64(0)) { $0 + $1.size }
        guard total > maximumBytes else { return }
        let target = Int64(Double(maximumBytes) * 0.8)
        for entry in all.sorted(by: { $0.accessed < $1.accessed }) {
            guard total > target else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
