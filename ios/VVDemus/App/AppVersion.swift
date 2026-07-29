import Foundation

/// What build is actually running.
///
/// Exists because "am I on the latest?" was unanswerable from inside the app. The marketing
/// version and build number are set in `project.yml`, but neither changes unless someone
/// remembers to bump them — so the useful part is `builtAt`, which is read from the
/// executable's modification date and therefore moves on every single build with no
/// discipline required.
enum AppVersion {
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// When this binary was compiled. Derived from the executable's modification date rather
    /// than a baked-in constant, so it cannot drift out of step with the code.
    static var builtAt: Date? {
        guard let url = Bundle.main.executableURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attributes[.modificationDate] as? Date
    }

    /// e.g. "1.1 (42) — built 29 Jul, 12:23". The date is the part that actually answers
    /// the question.
    static var summary: String {
        var text = "Version \(marketing) (\(build))"
        if let builtAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "d MMM, HH:mm"
            text += " — built \(formatter.string(from: builtAt))"
        }
        return text
    }
}
