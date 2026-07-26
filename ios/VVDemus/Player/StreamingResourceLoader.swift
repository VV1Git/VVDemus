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

    init(realURL: URL) {
        self.realScheme = realURL.scheme ?? "https"
        super.init()
        // Must match the queue `resourceLoader.setDelegate(_:queue:)` is given (main, see
        // `makePlayerItem`) — otherwise AVAssetResourceLoaderDelegate callbacks (main
        // queue) and URLSessionDataDelegate callbacks (previously an arbitrary background
        // queue) mutate `tasksByRequest`/`requestsByTask` from two threads at once with no
        // synchronization, which silently corrupted state and stalled playback after the
        // very first loading request.
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    /// `nil` if the URL can't be remapped (no scheme) — callers should fall back to
    /// handing AVFoundation the real URL directly rather than losing playback entirely.
    static func playableURL(for realURL: URL) -> URL? {
        guard var components = URLComponents(url: realURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = scheme
        return components.url
    }

    private func realRequestURL(from loadingURL: URL) -> URL? {
        guard var components = URLComponents(url: loadingURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = realScheme
        return components.url
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let loadingURL = loadingRequest.request.url, let url = realRequestURL(from: loadingURL) else { return false }
        var request = URLRequest(url: url)
        if let dataRequest = loadingRequest.dataRequest {
            let start = dataRequest.requestedOffset
            if dataRequest.requestsAllDataToEndOfResource {
                request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
            } else {
                let end = start + Int64(dataRequest.requestedLength) - 1
                request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            }
        }
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
            NSLog("[StreamingResourceLoader] request failed with HTTP %ld", http.statusCode)
            requestsByTask.removeValue(forKey: dataTask.taskIdentifier)
            tasksByRequest.removeValue(forKey: key)
            entry.loadingRequest.finishLoading(with: NSError(domain: "StreamingResourceLoader", code: http.statusCode))
            completionHandler(.cancel)
            return
        }
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
        if let error, (error as NSError).code != NSURLErrorCancelled {
            NSLog("[StreamingResourceLoader] request error: %@", error.localizedDescription)
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
