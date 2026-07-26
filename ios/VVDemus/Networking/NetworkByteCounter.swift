import Foundation

/// Rough network usage counter, split by what the request was for — lets Data Saver's
/// real effect be measured instead of assumed. Two real sources of cellular use can't be
/// captured this way and are stated as a limitation rather than silently omitted:
/// AVPlayer manages its own networking for live (non-downloaded) streaming with no
/// delegate hook short of a custom `AVAssetResourceLoader`, which this app doesn't use —
/// for that, compare cellular usage in iOS Settings before/after a change instead.
@MainActor
final class NetworkByteCounter: ObservableObject {
    static let shared = NetworkByteCounter()

    enum Category: String, CaseIterable, Identifiable {
        case image = "Images"
        case api = "API (search / radio / home)"
        case download = "Downloads"
        case streaming = "Streaming playback"

        var id: String { rawValue }
    }

    @Published private(set) var bytes: [Category: Int64] = [:]

    private init() {}

    func record(_ count: Int64, for category: Category) {
        guard count > 0 else { return }
        bytes[category, default: 0] += count
    }

    func reset() {
        bytes = [:]
    }

    var total: Int64 { bytes.values.reduce(0, +) }
}

/// Tallies response bytes into `NetworkByteCounter` for whichever ad-hoc `URLSession` it's
/// attached to. `URLSessionTaskMetrics` is available regardless of which thread the
/// session's calls originate from (search/radio/artwork fetches can run from either the
/// main actor or LocalControlServer's background Swifter threads), so this hops to the
/// main actor itself rather than requiring callers to.
final class ByteCountingSessionDelegate: NSObject, URLSessionTaskDelegate {
    let category: NetworkByteCounter.Category

    init(category: NetworkByteCounter.Category) {
        self.category = category
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let received = metrics.transactionMetrics.reduce(Int64(0)) { $0 + $1.countOfResponseBodyBytesReceived }
        let category = category
        Task { @MainActor in NetworkByteCounter.shared.record(received, for: category) }
    }
}

/// Shared sessions used in place of `URLSession.shared` for image and InnerTube API calls,
/// purely so their bytes are visible to `NetworkByteCounter`.
enum NetworkSessions {
    static let image = URLSession(configuration: .default, delegate: ByteCountingSessionDelegate(category: .image), delegateQueue: nil)
    static let api = URLSession(configuration: .default, delegate: ByteCountingSessionDelegate(category: .api), delegateQueue: nil)
}
