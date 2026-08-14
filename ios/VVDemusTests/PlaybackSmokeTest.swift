import AVFoundation
import XCTest
@testable import VVDemus

/// End-to-end: resolve a real stream and actually play it through the real engine.
///
/// Every other suite fakes the engine, which is right for testing logic but means a URL
/// that resolves perfectly and then refuses to play looks like success. This is the test
/// that catches "Couldn't play … Check your connection and try again". Part of the
/// benchmark scheme; hits the network.
@MainActor
final class PlaybackSmokeTest: XCTestCase {

    private let videoId = "5NV6Rdv1a3I"

    /// Step 1: does the app's own resolution path return a URL at all?
    func testStreamResolves() async throws {
        let stream = try await APIClient.shared.stream(videoId: videoId)
        print("\n[resolve] url host: \(URL(string: stream.url)?.host ?? "?")")
        print("[resolve] mime: \(stream.mimeType)")
        print("[resolve] itag: \(URLComponents(string: stream.url)?.queryItems?.first { $0.name == "itag" }?.value ?? "?")")
        XCTAssertFalse(stream.url.isEmpty)
    }

    /// Step 1b: is it resolving **audio-only**, or quietly paying for video nobody watches?
    ///
    /// The bug this exists for produced no error and no failure: playback worked, the
    /// smoke tests above all passed, and the app just used ~3.9x the data because the
    /// muxed fallback had silently become the normal path. Nothing in the suite noticed
    /// for as long as it lasted, because "it plays" was the only thing being asserted.
    func testResolvesAudioOnlyRatherThanFallingBackToVideo() async throws {
        let stream = try await InnerTubeClient.stream(videoId: videoId)
        let itag = URLComponents(string: stream.url)?
            .queryItems?.first { $0.name == "itag" }?.value ?? "?"
        print("[audio-only] mime: \(stream.mimeType), itag: \(itag), "
              + "muxed fallback: \(InnerTubeClient.lastStreamWasMuxedFallback)")

        XCTAssertFalse(
            InnerTubeClient.lastStreamWasMuxedFallback,
            "Fell back to muxed video — audio-only resolution is broken again. Two causes "
            + "look identical from here, and neither is a blocked client:\n"
            + "  1. A missing/refused visitor token (see VisitorDataProvider).\n"
            + "  2. Audio-only resolved but is capped to its first 1 MiB, so it would stop "
            + "a minute into every song and the muxed format is the only one that plays.\n"
            + "Run ThrottleCapDiagnostics *on a device* to tell them apart — expect this "
            + "assertion to fail there whenever the device is capped, which is correct."
        )
        XCTAssertTrue(
            stream.mimeType.hasPrefix("audio/"),
            "Expected an audio-only format, got \(stream.mimeType) — that is video data"
        )
    }

    /// Measures the difference rather than trusting it: the audio-only format has to be
    /// materially smaller than the muxed one, or the whole exercise bought nothing.
    func testAudioOnlyIsSubstantiallySmallerThanTheFallback() async throws {
        let stream = try await InnerTubeClient.stream(videoId: videoId)
        try XCTSkipIf(InnerTubeClient.lastStreamWasMuxedFallback, "Audio-only unavailable right now")

        func totalBytes(_ urlString: String) async throws -> Int {
            var request = URLRequest(url: try XCTUnwrap(URL(string: urlString)))
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            let (_, response) = try await URLSession.shared.data(for: request)
            let range = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Range") ?? ""
            return Int(range.split(separator: "/").last.map(String.init) ?? "") ?? 0
        }

        let audioBytes = try await totalBytes(stream.url)
        XCTAssertGreaterThan(audioBytes, 0, "Could not determine the audio-only size")
        print("[data] audio-only track size: \(String(format: "%.2f", Double(audioBytes) / 1e6)) MB")
        // A 3-4 minute song at itag 140 (~128kbps) lands around 3-5 MB; the muxed
        // equivalent measured 11-23 MB. A generous ceiling still catches a silent
        // regression to video.
        XCTAssertLessThan(audioBytes, 9_000_000,
                          "Far larger than an audio-only track should be — likely video again")
    }

    /// Step 2: will a plain GET actually return media bytes from that URL? A URL that
    /// resolves but 403s on fetch is the failure mode an iOS-client stream can have, since
    /// those URLs can be tied to the client that requested them.
    func testResolvedUrlServesBytes() async throws {
        let stream = try await APIClient.shared.stream(videoId: videoId)
        var request = URLRequest(url: try XCTUnwrap(URL(string: stream.url)))
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[fetch] HTTP \(status), \(data.count) bytes")
        XCTAssertTrue((200...299).contains(status), "The resolved URL refused a plain range request")
        XCTAssertGreaterThan(data.count, 1024)
    }

    /// Step 3: the whole thing — the real `AVPlaybackEngine`, the custom resource loader,
    /// and AVFoundation actually decoding. This is what the user experiences.
    func testRealEngineActuallyPlays() async throws {
        let stream = try await APIClient.shared.stream(videoId: videoId)
        let url = try XCTUnwrap(URL(string: stream.url))

        let engine = AVPlaybackEngine()
        var failure: Error??
        var lastTime: Double = 0
        engine.onItemFailed = { failure = .some($0) }
        engine.onPeriodicTime = { lastTime = $0 }

        engine.replaceItem(url: url, forwardBufferDuration: 60)
        engine.play()

        // Give it a few seconds to buffer and start moving.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, lastTime < 0.5, failure == nil {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        if let failure {
            XCTFail("Playback failed: \(failure?.localizedDescription ?? "unknown error")")
            return
        }
        print("[play] position after start: \(String(format: "%.2f", lastTime))s, engine playing: \(engine.isEnginePlaying)")
        XCTAssertGreaterThan(lastTime, 0, "The player never advanced — no audio was decoded")
    }

    /// Step 3b: play from deep inside the track, past any chunk boundary.
    ///
    /// The resource loader satisfies byte ranges itself, so if it ever under-delivers a
    /// range and reports success anyway, audio truncates part-way through — invisible to a
    /// test that only samples the opening seconds. Seeking well past the first megabyte and
    /// requiring the clock to advance there is what catches it.
    func testPlaysFromDeepInsideTheTrack() async throws {
        let stream = try await APIClient.shared.stream(videoId: videoId)
        let url = try XCTUnwrap(URL(string: stream.url))

        let engine = AVPlaybackEngine()
        var failure: Error??
        var lastTime: Double = 0
        engine.onItemFailed = { failure = .some($0) }
        engine.onPeriodicTime = { lastTime = $0 }

        engine.replaceItem(url: url, forwardBufferDuration: 60)
        // Well beyond the 1 MB mark at any sane bitrate.
        let seekTarget: Double = 150
        engine.seek(to: seekTarget)
        engine.play()

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, lastTime < seekTarget + 0.5, failure == nil {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        if let failure {
            XCTFail("Playback failed deep in the track: \(failure?.localizedDescription ?? "unknown")")
            return
        }
        print("[deep] position: \(String(format: "%.2f", lastTime))s after seeking to \(seekTarget)s")
        XCTAssertGreaterThan(lastTime, seekTarget, "Playback did not advance past the seek point")
    }

    /// Step 4: the same thing through the resource loader the app actually uses, since
    /// that's the layer that rewrites the URL scheme and re-issues the request itself.
    func testResourceLoaderPathServesBytes() async throws {
        let stream = try await APIClient.shared.stream(videoId: videoId)
        let url = try XCTUnwrap(URL(string: stream.url))
        let playable = try XCTUnwrap(StreamingResourceLoader.playableURL(for: url))
        print("[loader] rewritten scheme: \(playable.scheme ?? "?")")

        let asset = AVURLAsset(url: playable)
        let loader = StreamingResourceLoader(realURL: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.callbackQueue)

        let isPlayable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        print("[loader] isPlayable: \(isPlayable), duration: \(String(format: "%.1f", duration.seconds))s")
        loader.shutdown()

        XCTAssertTrue(isPlayable, "AVFoundation could not open the stream through the resource loader")
    }
}

/// Narrows down *why* a URL that serves bytes to a plain request 403s through the loader.
@MainActor
final class ResourceLoaderUrlIntegrityTests: XCTestCase {

    func testSchemeRoundTripPreservesTheSignedUrlExactly() async throws {
        let stream = try await APIClient.shared.stream(videoId: "5NV6Rdv1a3I")
        let original = try XCTUnwrap(URL(string: stream.url))

        // What the loader does: swap the scheme out, then back again.
        let playable = try XCTUnwrap(StreamingResourceLoader.playableURL(for: original))
        var components = try XCTUnwrap(URLComponents(url: playable, resolvingAgainstBaseURL: false))
        components.scheme = "https"
        let roundTripped = try XCTUnwrap(components.url)

        if roundTripped.absoluteString != original.absoluteString {
            print("\n[integrity] URL CHANGED by the scheme round-trip")
            let a = original.absoluteString, b = roundTripped.absoluteString
            print("[integrity] original length \(a.count), round-tripped \(b.count)")
            for (i, (x, y)) in zip(a, b).enumerated() where x != y {
                let start = max(0, i - 40)
                print("[integrity] first difference at \(i):")
                print("[integrity]   original:     …\(String(Array(a)[start..<min(a.count, i + 40)]))")
                print("[integrity]   round-tripped:…\(String(Array(b)[start..<min(b.count, i + 40)]))")
                break
            }
        } else {
            print("\n[integrity] round-trip is byte-identical")
        }
        XCTAssertEqual(roundTripped.absoluteString, original.absoluteString,
                       "A re-encoded signature is rejected with 403")
    }

    /// Issues exactly the request the loader issues, to see the status directly.
    func testLoaderStyleRequestStatus() async throws {
        let stream = try await APIClient.shared.stream(videoId: "5NV6Rdv1a3I")
        let original = try XCTUnwrap(URL(string: stream.url))
        let playable = try XCTUnwrap(StreamingResourceLoader.playableURL(for: original))
        var components = try XCTUnwrap(URLComponents(url: playable, resolvingAgainstBaseURL: false))
        components.scheme = "https"
        let rebuilt = try XCTUnwrap(components.url)

        for (label, url) in [("original", original), ("loader-rebuilt", rebuilt)] {
            var request = URLRequest(url: url)
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
            let (_, response) = try await URLSession.shared.data(for: request)
            print("[request] \(label): HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
    }
}
