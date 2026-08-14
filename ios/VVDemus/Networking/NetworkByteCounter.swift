import Foundation

/// Rough network usage counter, split by what the request was for — lets Data Saver's
/// real effect be measured instead of assumed. Streaming playback *is* counted: it goes
/// through `StreamingResourceLoader`, a custom `AVAssetResourceLoader` that exists partly
/// for this reason. Bytes AVFoundation fetches on its own (the fallback path when a URL
/// can't be remapped) still can't be seen from here.
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
    /// Bounded timeouts. The default is 60 seconds per request, so on a captive portal or
    /// a half-open connection a search sat spinning for a full minute before failing.
    private static func configuration(useURLCache: Bool) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        // Images already have their own disk cache (`DiskImageCache`); leaving
        // `URLCache.shared` on top of it stored a second copy of every thumbnail.
        if !useURLCache { configuration.urlCache = nil }
        return configuration
    }

    static let image = URLSession(
        configuration: configuration(useURLCache: false),
        delegate: ByteCountingSessionDelegate(category: .image),
        delegateQueue: nil
    )
    static let api = URLSession(
        configuration: configuration(useURLCache: true),
        delegate: ByteCountingSessionDelegate(category: .api),
        delegateQueue: nil
    )
}
