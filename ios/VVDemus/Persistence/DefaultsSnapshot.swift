import Foundation

/// Reads a Codable blob out of `UserDefaults` without destroying it when it can't be read.
///
/// Every store here was written the same way:
///
/// ```swift
/// guard let data = defaults.data(forKey: key),
///       let decoded = try? JSONDecoder().decode(T.self, from: data) else { return }
/// ```
///
/// which looks safe and is not. A decode failure leaves the published array empty, and the
/// *first subsequent mutation* calls `save()` — overwriting the still-perfectly-good blob
/// with a one-element array. Add a required field to `Track` in a future version, restore
/// a backup, or hit a half-written preferences plist, and the user silently loses their
/// liked songs, every playlist, their download list and a year of listening stats, with no
/// error, no log and no way back.
///
/// So: on a decode failure the original bytes are copied to a side key and the caller is
/// told to leave its state alone rather than start from empty.
enum DefaultsSnapshot {
    /// Suffix appended to the key under which unreadable data is preserved.
    static let corruptSuffix = "_corrupt"

    /// The three genuinely different outcomes. Collapsing "corrupt" into `nil` was the
    /// whole problem: a store that can't tell them apart starts from empty and its next
    /// mutation saves that empty state straight over the good data — which is exactly the
    /// loss this type was written to prevent.
    enum Outcome<T> {
        case missing
        case corrupt
        case value(T)

        var value: T? { if case .value(let v) = self { return v }; return nil }
        var isCorrupt: Bool { if case .corrupt = self { return true }; return false }
    }

    static func read<T: Decodable>(
        _ type: T.Type,
        forKey key: String,
        from defaults: UserDefaults = .standard,
        decoder: JSONDecoder = JSONDecoder()
    ) -> Outcome<T> {
        guard let data = defaults.data(forKey: key) else { return .missing }
        if let decoded = try? decoder.decode(type, from: data) { return .value(decoded) }
        // Unique per corruption, never overwriting an existing backup: a second schema
        // change would otherwise replace the last good copy with the already-degraded one.
        // A bare timestamp is not enough — two failures inside the same second collide.
        let stamp = "\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8))"
        let backupKey = "\(key)\(corruptSuffix)_\(stamp)"
        NSLog("[DefaultsSnapshot] '%@' failed to decode — preserved as '%@'", key, backupKey)
        defaults.set(data, forKey: backupKey)
        return .corrupt
    }

    static func load<T: Decodable>(
        _ type: T.Type,
        forKey key: String,
        from defaults: UserDefaults = .standard,
        decoder: JSONDecoder = JSONDecoder()
    ) -> T? {
        read(type, forKey: key, from: defaults, decoder: decoder).value
    }

    static func save<T: Encodable>(
        _ value: T,
        forKey key: String,
        to defaults: UserDefaults = .standard,
        encoder: JSONEncoder = JSONEncoder()
    ) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
