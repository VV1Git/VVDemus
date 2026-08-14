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
///
/// One loading request becomes a *sequence* of HTTP range requests, each capped at
/// `maximumChunkSize` — see there for why asking for the range AVFoundation actually names
/// is what broke playback on the phone.
final class StreamingResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    static let scheme = "vvdemus-stream"

    /// One AVFoundation loading request, and how far through its byte range we have got.
    ///
    /// A loading request is satisfied by a *sequence* of HTTP requests rather than one, so
    /// the progress through it has to live somewhere across callbacks — see
    /// `maximumChunkSize` for why it is split up at all.
    private final class LoadingContext {
        let loadingRequest: AVAssetResourceLoadingRequest
        /// The next byte to ask the server for.
        var nextOffset: Int64
        /// The last byte this request needs, inclusive. `nil` while the resource size is
        /// still unknown — AVFoundation asks for "everything to the end" before anything
        /// has revealed how long "the end" is.
        var finalOffset: Int64?
        /// The inclusive end of the chunk currently in flight, so a short response can be
        /// recognized as the end of the resource when `finalOffset` is unknown.
        var requestedChunkEnd: Int64 = 0
        var task: URLSessionDataTask?
        var hasFilledContentInformation = false
        var hasDeliveredData = false

        init(loadingRequest: AVAssetResourceLoadingRequest, nextOffset: Int64, finalOffset: Int64?) {
            self.loadingRequest = loadingRequest
            self.nextOffset = nextOffset
            self.finalOffset = finalOffset
        }
    }

    private let realScheme: String
    private var session: URLSession!
    private var contextsByRequest: [ObjectIdentifier: LoadingContext] = [:]
    private var requestKeysByTask: [Int: ObjectIdentifier] = [:]
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

    /// How much one HTTP request may ask for.
    ///
    /// googlevideo refuses a large range on a throttled URL — the whole-file
    /// `bytes=0-<size-1>` that iOS's AVFoundation provokes comes back **403** — while the
    /// same URL serves modest ranges perfectly. That is the entire "Couldn't play … Check
    /// your connection and try again" bug: the resolved URL is fine, the network is fine,
    /// and the very first data request is refused before a byte of audio arrives.
    ///
    /// It reproduced only on a real phone. The simulator shares the Mac's network path,
    /// where the same URLs are not throttled and the whole-file range returns 206 — so the
    /// smoke tests passed on the simulator and on the Mac app while every undownloaded
    /// track failed on the phone. `VVDemusTests/StreamUrlRangeTests` samples 256 KB
    /// windows, which is why it never caught it either.
    ///
    /// 512 KB is deliberately well under the ~1 MB where throttled URLs start refusing
    /// (see the `audioOnlyClients` note in `InnerTubeClient` for the same cap observed on
    /// the IOS player client), and is still only ~8 requests for a typical 4 MB track.
    static let maximumChunkSize: Int64 = 512 << 10

    /// The stretch of bytes a loading request needs: where it starts, and the last byte it
    /// wants (inclusive), or `nil` for "to the end" while the length is still unknown.
    ///
    /// Kept as a pure function over primitives because `AVAssetResourceLoadingDataRequest`
    /// cannot be constructed in a test.
    static func extent(
        requestedOffset: Int64,
        requestedLength: Int,
        requestsAllToEnd: Bool,
        knownLength: Int64?
    ) -> (start: Int64, finalOffset: Int64?) {
        let start = max(0, requestedOffset)
        if requestsAllToEnd {
            // Only as far as the resource actually goes. A range that overshoots the end is
            // refused outright rather than truncated (`bytes=0-<size>` → 403).
            return (start, knownLength.flatMap { $0 > 0 ? $0 - 1 : nil })
        }
        // No length asked for: this is the content-information probe. Two bytes is enough
        // for the server to report the full size in `Content-Range`.
        guard requestedLength > 0 else { return (start, start + 1) }
        var final = start + Int64(requestedLength) - 1
        if let knownLength, knownLength > 0 {
            final = min(final, knownLength - 1)
        }
        return (start, max(final, start))
    }

    static func extent(
        for dataRequest: AVAssetResourceLoadingDataRequest?,
        knownLength: Int64?
    ) -> (start: Int64, finalOffset: Int64?) {
        guard let dataRequest else { return (0, 1) }
        return extent(
            requestedOffset: dataRequest.requestedOffset,
            requestedLength: dataRequest.requestedLength,
            requestsAllToEnd: dataRequest.requestsAllDataToEndOfResource,
            knownLength: knownLength
        )
    }

    /// The **closed** `Range` header for one chunk: never larger than `maximumChunkSize`,
    /// never past what the loading request needs, never past the end of the resource.
    static func rangeHeader(start: Int64, finalOffset: Int64?, knownLength: Int64?) -> String {
        let start = max(0, start)
        var end = start + maximumChunkSize - 1
        if let finalOffset { end = min(end, finalOffset) }
        if let knownLength, knownLength > 0 { end = min(end, knownLength - 1) }
        return "bytes=\(start)-\(max(end, start))"
    }

    private func realRequestURL(from loadingURL: URL) -> URL? {
        guard var components = URLComponents(url: loadingURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = realScheme
        return components.url
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !isShutDown else { return false }
        guard let loadingURL = loadingRequest.request.url, realRequestURL(from: loadingURL) != nil else { return false }
        let planned = Self.extent(for: loadingRequest.dataRequest, knownLength: knownContentLength)
        let context = LoadingContext(
            loadingRequest: loadingRequest,
            nextOffset: planned.start,
            finalOffset: planned.finalOffset
        )
        contextsByRequest[ObjectIdentifier(loadingRequest)] = context
        startNextChunk(for: context)
        return true
    }

    /// Asks for the next `maximumChunkSize` bytes of `context`'s range. The loading request
    /// is only finished once its whole extent has been served, so AVFoundation never has to
    /// re-request a remainder — the old capped version finished early instead, which handed
    /// back a truncated range as though it were whole.
    private func startNextChunk(for context: LoadingContext) {
        // Torn down between chunks: end the request rather than leaving it unanswered.
        // `finishLoading()` here would claim a half-served range was complete.
        guard !isShutDown else {
            finish(context, with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
            return
        }
        guard let loadingURL = context.loadingRequest.request.url,
              let url = realRequestURL(from: loadingURL) else {
            finish(context, with: NSError(domain: "StreamingResourceLoader", code: -1))
            return
        }
        var request = URLRequest(url: url)
        let header = Self.rangeHeader(
            start: context.nextOffset,
            finalOffset: context.finalOffset,
            knownLength: knownContentLength
        )
        request.setValue(header, forHTTPHeaderField: "Range")
        context.requestedChunkEnd = Self.chunkEnd(from: header) ?? context.nextOffset
        let task = session.dataTask(with: request)
        context.task = task
        requestKeysByTask[task.taskIdentifier] = ObjectIdentifier(context.loadingRequest)
        task.resume()
    }

    /// Ends a loading request and forgets it. `error == nil` means the whole extent was served.
    private func finish(_ context: LoadingContext, with error: Error?) {
        if let task = context.task { requestKeysByTask.removeValue(forKey: task.taskIdentifier) }
        contextsByRequest.removeValue(forKey: ObjectIdentifier(context.loadingRequest))
        if let error {
            context.loadingRequest.finishLoading(with: error)
        } else {
            context.loadingRequest.finishLoading()
        }
    }

    private static func chunkEnd(from header: String) -> Int64? {
        header.split(separator: "-").last.flatMap { Int64($0) }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(loadingRequest)
        if let context = contextsByRequest.removeValue(forKey: key) {
            if let task = context.task {
                requestKeysByTask.removeValue(forKey: task.taskIdentifier)
                task.cancel()
            }
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let key = requestKeysByTask[dataTask.taskIdentifier], let context = contextsByRequest[key] else {
            completionHandler(.allow)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            // A range past the end after data has already been served is the end of the
            // resource, not a failure — it is how a resource of unknown length terminates.
            if http.statusCode == 416, context.hasDeliveredData {
                finish(context, with: nil)
                completionHandler(.cancel)
                return
            }
            NSLog("[StreamingResourceLoader] request failed with HTTP %ld (range=%@, known=%@)",
                  http.statusCode,
                  dataTask.originalRequest?.value(forHTTPHeaderField: "Range") ?? "none",
                  knownContentLength.map(String.init) ?? "unknown")
            finish(context, with: NSError(domain: "StreamingResourceLoader", code: http.statusCode))
            completionHandler(.cancel)
            return
        }
        if let total = Self.totalLength(from: http) {
            knownContentLength = total
            // The size was unknown when this request was planned ("everything to the end"),
            // so now it is known, pin down where the end actually is.
            if context.finalOffset == nil, total > 0 { context.finalOffset = total - 1 }
        }
        if let info = context.loadingRequest.contentInformationRequest, !context.hasFilledContentInformation {
            context.hasFilledContentInformation = true
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
        guard let key = requestKeysByTask[dataTask.taskIdentifier], let context = contextsByRequest[key] else { return }
        context.loadingRequest.dataRequest?.respond(with: data)
        context.hasDeliveredData = true
        context.nextOffset += Int64(data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = requestKeysByTask.removeValue(forKey: task.taskIdentifier),
              let context = contextsByRequest[key] else { return }
        if let error {
            // Cancellation included. `finishLoading()` means "this range completed", so
            // reporting a cancelled task that way handed AVFoundation a truncated range as
            // though it were whole — silently short audio rather than a clean failure.
            if (error as NSError).code != NSURLErrorCancelled {
                NSLog("[StreamingResourceLoader] request error: %@", error.localizedDescription)
            }
            finish(context, with: error)
            return
        }
        // One chunk of the range is done; the loading request is not, until every byte it
        // asked for has been handed over.
        if let final = context.finalOffset {
            guard context.nextOffset > final else {
                startNextChunk(for: context)
                return
            }
        } else if context.nextOffset > context.requestedChunkEnd {
            // Length still unknown and the server served the whole chunk, so there is
            // probably more. A short chunk means the resource ended.
            startNextChunk(for: context)
            return
        }
        finish(context, with: nil)
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
