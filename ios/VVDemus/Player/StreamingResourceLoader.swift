import AVFoundation

/// Routes AVPlayer's own network fetches through a plain `URLSession` instead of letting
/// AVFoundation hit the network directly — the only way to see (and count) streaming
/// playback bytes, which `NetworkByteCounter` couldn't see at all before this, even
/// though normal listening (not downloads, not images/API calls) is most of this app's
/// actual cellular usage.
///
/// AVFoundation only routes a URL through a custom resource loader delegate if it doesn't
/// recognize the URL's scheme, so `playableURL(for:)` swaps the real `https` scheme for an
/// invented one; `resourceLoader(_:shouldWaitForLoadingOfRequestedResource:)` swaps it back
/// before making the real request. Data streams back to AVFoundation incrementally as it
/// arrives (not buffered and delivered all at once) so playback can start before the whole
/// file downloads, matching how AVFoundation's own default loading behaves.
final class StreamingResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    static let scheme = "vvdemus-stream"

    private let realScheme: String
    private var session: URLSession!
    private var tasksByRequest: [ObjectIdentifier: (task: URLSessionDataTask, loadingRequest: AVAssetResourceLoadingRequest)] = [:]
    private var requestsByTask: [Int: ObjectIdentifier] = [:]
    /// Total size of the resource, learned from the first `Content-Range`, used to keep
    /// later chunks from running past the end.
    private var knownContentLength: Int64?

    /// The one queue every callback into this object runs on. Both the
    /// `AVAssetResourceLoaderDelegate` callbacks (via `setDelegate(_:queue:)`) and the
    /// `URLSessionDataDelegate` callbacks are bound to it, so `tasksByRequest` /
    /// `requestsByTask` are only ever touched from one thread — the race that used to
    /// corrupt them and stall playback after the first loading request.
    ///
    /// It is deliberately *not* the main queue. Every byte of streamed audio passes
    /// through `didReceive data:`, so running it on main pushed the whole download,
    /// at network throughput, through the same thread as SwiftUI's rendering — visible
    /// as scroll jank whenever a track was buffering.
    let callbackQueue = DispatchQueue(label: "com.vvdemus.streamloader")

    init(realURL: URL) {
        self.realScheme = realURL.scheme ?? "https"
        super.init()
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = callbackQueue
        let configuration = URLSessionConfiguration.default
        // Deliberately generous: this is an *idle* timeout, and a short one turns a tunnel
        // or a lift into a failed item, a re-resolve and — on the second occurrence in one
        // track — a stop. AVFoundation rides out gaps on its own given the chance.
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    /// A `URLSession` holds its delegate strongly until it is invalidated, so this object
    /// and its session retain each other. One loader is created per track played, so
    /// without an explicit teardown every track leaked a session, a delegate and any
    /// in-flight tasks for the rest of the app's life.
    func shutdown() {
        // Torn down on the loader's own queue so it serializes with the delegate callbacks.
        // Invalidating from the main actor left a window where AVFoundation — still holding
        // the old asset until `replaceCurrentItem` lands, and re-issuing loading requests in
        // response to the cancellations — called `dataTask(with:)` on a dead session.
        // That raises `NSGenericException`, which is not catchable in Swift: the app
        // aborted. Reached by skipping any streamed track while it was still buffering.
        callbackQueue.async { [self] in
            isShutDown = true
            session.invalidateAndCancel()
        }
    }

    /// Set on `callbackQueue`, read on `callbackQueue` — no cross-thread access.
    private var isShutDown = false

    /// `nil` if the URL can't be remapped (no scheme) — callers should fall back to
    /// handing AVFoundation the real URL directly rather than losing playback entirely.
    static func playableURL(for realURL: URL) -> URL? {
        guard var components = URLComponents(url: realURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = scheme
        return components.url
    }

    /// Ranges are **closed** but not artificially chunked.
    ///
    /// An earlier version capped every request at 1 MB, because the audio-only URLs the app
    /// briefly used refused anything larger. Those URLs are gone (they were throttled and
    /// couldn't serve a whole track), and capping is actively risky here: a data request is
    /// only partially satisfied, and whether AVFoundation re-requests the remainder is an
    /// assumption rather than a contract — get it wrong and playback truncates mid-track.
    /// The muxed URLs actually in use serve any range, so ask for what was asked for.
    static let fallbackSpan: Int64 = 64 << 20 // 64 MB — larger than any track

    /// The `Range` header for a loading request — always present, always **closed**, and
    /// never larger than `maximumChunkSize`.
    ///
    /// Three separate things were wrong here, and each one alone is a 403 from googlevideo:
    ///
    /// 1. The content-information probe AVFoundation issues first arrives with no
    ///    `dataRequest`, and used to produce no `Range` header at all.
    /// 2. "All data to the end of the resource" produced an open-ended `bytes=N-`.
    /// 3. A closed range covering the whole file — the obvious reading of "all data" once
    ///    the total size is known — is larger than the server will serve.
    ///
    /// The asset therefore failed to open before a single byte of audio arrived, which
    /// surfaced as "Couldn't play … Check your connection and try again". The old muxed
    /// itag-18 URLs tolerated all three forms, which is why this only appeared once
    /// playback moved to the audio-only formats.
    static func rangeHeader(
        requestedOffset: Int64,
        requestedLength: Int,
        requestsAllToEnd: Bool,
        knownLength: Int64?
    ) -> String {
        let start = max(0, requestedOffset)
        // No length asked for: this is the content-information probe. Two bytes is enough
        // for the server to report the full size in `Content-Range`.
        if !requestsAllToEnd && requestedLength <= 0 {
            return "bytes=\(start)-\(start + 1)"
        }
        let wanted = requestsAllToEnd ? fallbackSpan : Int64(requestedLength)
        var end = start + wanted - 1
        // Never ask past the last byte. A range that overshoots the end of the resource is
        // refused outright rather than truncated (`bytes=0-<size>` → 403), which is what
        // made the requests near the end of a track fail once chunking was in place.
        if let knownLength, knownLength > 0 {
            end = min(end, knownLength - 1)
        }
        return "bytes=\(start)-\(max(end, start))"
    }

    static func rangeHeader(for dataRequest: AVAssetResourceLoadingDataRequest?, knownLength: Int64?) -> String {
        guard let dataRequest else { return "bytes=0-1" }
        return rangeHeader(
            requestedOffset: dataRequest.requestedOffset,
            requestedLength: dataRequest.requestedLength,
            requestsAllToEnd: dataRequest.requestsAllDataToEndOfResource,
            knownLength: knownLength
        )
    }

    private func realRequestURL(from loadingURL: URL) -> URL? {
        guard var components = URLComponents(url: loadingURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = realScheme
        return components.url
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !isShutDown else { return false }
        guard let loadingURL = loadingRequest.request.url, let url = realRequestURL(from: loadingURL) else { return false }
        var request = URLRequest(url: url)
        request.setValue(
            Self.rangeHeader(for: loadingRequest.dataRequest, knownLength: knownContentLength),
            forHTTPHeaderField: "Range"
        )
        let task = session.dataTask(with: request)
        let key = ObjectIdentifier(loadingRequest)
        tasksByRequest[key] = (task, loadingRequest)
        requestsByTask[task.taskIdentifier] = key
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(loadingRequest)
        if let entry = tasksByRequest.removeValue(forKey: key) {
            requestsByTask.removeValue(forKey: entry.task.taskIdentifier)
            entry.task.cancel()
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let key = requestsByTask[dataTask.taskIdentifier], let entry = tasksByRequest[key] else {
            completionHandler(.allow)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            NSLog("[StreamingResourceLoader] request failed with HTTP %ld (range=%@, known=%@)",
                  http.statusCode,
                  dataTask.originalRequest?.value(forHTTPHeaderField: "Range") ?? "none",
                  knownContentLength.map(String.init) ?? "unknown")
            requestsByTask.removeValue(forKey: dataTask.taskIdentifier)
            tasksByRequest.removeValue(forKey: key)
            entry.loadingRequest.finishLoading(with: NSError(domain: "StreamingResourceLoader", code: http.statusCode))
            completionHandler(.cancel)
            return
        }
        if let total = Self.totalLength(from: http) { knownContentLength = total }
        if let info = entry.loadingRequest.contentInformationRequest {
            if let mimeType = http.mimeType {
                info.contentType = StreamingResourceLoader.contentType(forMimeType: mimeType)
            }
            // For a 206 response, `expectedContentLength` is only the size of *this*
            // range (often a tiny initial probe, e.g. 2 bytes) — the real full-resource
            // size comes from Content-Range's total. Using expectedContentLength here
            // unconditionally told AVFoundation the entire resource was just a couple
            // bytes long, which it correctly refused to open.
            let contentLength = Self.totalLength(from: http) ?? (http.expectedContentLength >= 0 ? http.expectedContentLength : 0)
            info.contentLength = contentLength
            info.isByteRangeAccessSupported = true
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let key = requestsByTask[dataTask.taskIdentifier], let entry = tasksByRequest[key] else { return }
        entry.loadingRequest.dataRequest?.respond(with: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = requestsByTask.removeValue(forKey: task.taskIdentifier),
              let entry = tasksByRequest.removeValue(forKey: key) else { return }
        if let error {
            // Cancellation included. `finishLoading()` means "this range completed", so
            // reporting a cancelled task that way handed AVFoundation a truncated range as
            // though it were whole — silently short audio rather than a clean failure.
            if (error as NSError).code != NSURLErrorCancelled {
                NSLog("[StreamingResourceLoader] request error: %@", error.localizedDescription)
            }
            entry.loadingRequest.finishLoading(with: error)
        } else {
            entry.loadingRequest.finishLoading()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let bytes = metrics.transactionMetrics.reduce(Int64(0)) { $0 + $1.countOfResponseBodyBytesReceived }
        Task { @MainActor in NetworkByteCounter.shared.record(bytes, for: .streaming) }
    }

    private static func totalLength(from response: HTTPURLResponse) -> Int64? {
        guard let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
              let totalString = contentRange.split(separator: "/").last else { return nil }
        return Int64(totalString)
    }

    private static func contentType(forMimeType mimeType: String) -> String {
        if mimeType.hasPrefix("audio") { return "public.mpeg-4-audio" }
        if mimeType.hasPrefix("video") { return "public.mpeg-4" }
        return "public.data"
    }
}
