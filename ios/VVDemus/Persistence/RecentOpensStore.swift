import Foundation

/// When each collection was last opened, so Home's shortcut grid can order radios, playlists
/// and albums against each other rather than only within their own kind.
///
/// Every one of those already carries a timestamp of its own, and none of them means "opened":
/// a radio's is when its seed last *played*, an album's is when it was last added to history,
/// and a playlist has only `createdAt`. That last one is the reason this exists — a playlist
/// you made a year ago and opened five minutes ago would otherwise sort last on a grid whose
/// whole premise is recency.
///
/// **Local, and deliberately not synced.** It is a record of what happened on this device;
/// the phone and the Mac having different ideas about what you most recently looked at on
/// *them* is correct, not drift. The things themselves — which albums exist, which radios,
/// which playlists — do sync.
@MainActor
final class RecentOpensStore: ObservableObject {
    static let shared = RecentOpensStore()

    private let defaultsKey = "recent_opens_v1"
    /// Enough for several screens' worth of grid on the widest window, with room to spare.
    /// Bounded at all because nothing else prunes it: without a cap this grows by one entry
    /// per collection ever opened and is written back whole on every open.
    private let limit = 64

    @Published private(set) var opens: [String: Date] = [:]

    private init() {
        opens = DefaultsSnapshot.load([String: Date].self, forKey: defaultsKey) ?? [:]
    }

    // `nonisolated`: these are string formatting and nothing else, and the ordering rule that
    // reads them (`HomeShortcuts.ranked`) is deliberately a pure function with no actor of its
    // own — so hopping to the main one to build a dictionary key would be the only reason it
    // needed to be async.
    nonisolated static func radioKey(_ videoId: String) -> String { "radio:\(videoId)" }
    nonisolated static func playlistKey(_ id: UUID) -> String { "playlist:\(id.uuidString)" }
    nonisolated static func albumKey(_ browseId: String) -> String { "album:\(browseId)" }

    func openedAt(_ key: String) -> Date? { opens[key] }

    func markOpened(_ key: String) {
        opens[key] = Date()
        if opens.count > limit {
            // Oldest first, so what survives is what the grid would have shown anyway.
            for stale in opens.sorted(by: { $0.value < $1.value }).prefix(opens.count - limit) {
                opens.removeValue(forKey: stale.key)
            }
        }
        guard let data = try? JSONEncoder().encode(opens) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
