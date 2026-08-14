import XCTest
@testable import VVDemus

/// The range arithmetic behind `StreamingResourceLoader`, with no network involved.
///
/// The bug these exist for: iOS's AVFoundation opens a stream by asking for *all data to
/// the end of the resource*, and the loader turned that into a single closed range
/// covering the whole file. googlevideo answers a range that large with **403** on a
/// throttled URL, so the asset failed before a byte of audio arrived and every
/// undownloaded track showed "Couldn't play … Check your connection and try again".
///
/// It reproduced only on a real phone — the simulator and the Mac app share a network path
/// where those URLs aren't throttled and the whole-file range returns 206 — so the network
/// tests all passed while the phone couldn't play anything. Hence pure unit tests: the
/// invariant is "never ask for more than `maximumChunkSize` at once", and that is checkable
/// without depending on whether today's URL happens to be throttled.
final class StreamRangeChunkingTests: XCTestCase {

    private let totalLength: Int64 = 4_025_466 // the track the smoke tests use

    // MARK: - The regression

    func testAllDataToEndDoesNotAskForTheWholeFileAtOnce() {
        let header = StreamingResourceLoader.rangeHeader(
            start: 0,
            finalOffset: totalLength - 1,
            knownLength: totalLength
        )
        XCTAssertEqual(header, "bytes=0-\(StreamingResourceLoader.maximumChunkSize - 1)")
        XCTAssertNotEqual(
            header, "bytes=0-\(totalLength - 1)",
            "This is the exact request the phone was refused with HTTP 403"
        )
    }

    func testEveryChunkStaysWithinTheServerFriendlyCap() {
        var offset: Int64 = 0
        var requests = 0
        while offset < totalLength {
            let header = StreamingResourceLoader.rangeHeader(
                start: offset,
                finalOffset: totalLength - 1,
                knownLength: totalLength
            )
            let (start, end) = try! Self.parse(header)
            XCTAssertEqual(start, offset, "Chunks must be contiguous — a gap is silent audio corruption")
            XCTAssertLessThanOrEqual(
                end - start + 1, StreamingResourceLoader.maximumChunkSize,
                "Chunk \(requests) asked for more than the cap"
            )
            offset = end + 1
            requests += 1
            XCTAssertLessThan(requests, 1000, "Chunking failed to advance")
        }
        XCTAssertEqual(offset, totalLength, "Chunks must tile the file exactly, with no overshoot")
        XCTAssertGreaterThan(requests, 1, "A file this size should take several chunks")
    }

    func testNoChunkRunsPastTheEndOfTheResource() {
        // A range that overshoots the end is refused outright rather than truncated.
        let lastChunkStart = totalLength - 10
        let header = StreamingResourceLoader.rangeHeader(
            start: lastChunkStart,
            finalOffset: totalLength - 1,
            knownLength: totalLength
        )
        XCTAssertEqual(header, "bytes=\(lastChunkStart)-\(totalLength - 1)")
    }

    // MARK: - What each kind of loading request asks for

    func testContentInformationProbeAsksForTwoBytes() {
        // The probe arrives with no dataRequest at all; two bytes is enough for the server
        // to report the full size in Content-Range.
        let planned = StreamingResourceLoader.extent(for: nil, knownLength: nil)
        XCTAssertEqual(planned.start, 0)
        XCTAssertEqual(planned.finalOffset, 1)
    }

    func testAllDataToEndWithUnknownLengthHasNoFinalOffsetYet() {
        let planned = StreamingResourceLoader.extent(
            requestedOffset: 0, requestedLength: 0, requestsAllToEnd: true, knownLength: nil
        )
        XCTAssertEqual(planned.start, 0)
        XCTAssertNil(planned.finalOffset, "The end isn't known until a Content-Range reveals it")
    }

    func testAllDataToEndStopsAtTheLastByteOnceLengthIsKnown() {
        let planned = StreamingResourceLoader.extent(
            requestedOffset: 0, requestedLength: 0, requestsAllToEnd: true, knownLength: totalLength
        )
        XCTAssertEqual(planned.finalOffset, totalLength - 1)
    }

    func testBoundedRequestKeepsItsOwnLength() {
        let planned = StreamingResourceLoader.extent(
            requestedOffset: 1000, requestedLength: 500, requestsAllToEnd: false, knownLength: totalLength
        )
        XCTAssertEqual(planned.start, 1000)
        XCTAssertEqual(planned.finalOffset, 1499)

        // Small enough to fit in one chunk, so it is asked for exactly.
        let header = StreamingResourceLoader.rangeHeader(
            start: planned.start, finalOffset: planned.finalOffset, knownLength: totalLength
        )
        XCTAssertEqual(header, "bytes=1000-1499")
    }

    func testBoundedRequestLargerThanTheCapIsStillChunked() {
        let requested = Int(StreamingResourceLoader.maximumChunkSize * 3)
        let planned = StreamingResourceLoader.extent(
            requestedOffset: 0, requestedLength: requested, requestsAllToEnd: false, knownLength: totalLength
        )
        XCTAssertEqual(planned.finalOffset, Int64(requested) - 1)

        let header = StreamingResourceLoader.rangeHeader(
            start: planned.start, finalOffset: planned.finalOffset, knownLength: totalLength
        )
        XCTAssertEqual(header, "bytes=0-\(StreamingResourceLoader.maximumChunkSize - 1)")
    }

    func testBoundedRequestIsClampedToTheEndOfTheResource() {
        let planned = StreamingResourceLoader.extent(
            requestedOffset: totalLength - 100,
            requestedLength: 10_000,
            requestsAllToEnd: false,
            knownLength: totalLength
        )
        XCTAssertEqual(planned.finalOffset, totalLength - 1)
    }

    func testNegativeOffsetIsTreatedAsTheStartOfTheResource() {
        let planned = StreamingResourceLoader.extent(
            requestedOffset: -5, requestedLength: 100, requestsAllToEnd: false, knownLength: totalLength
        )
        XCTAssertEqual(planned.start, 0)
    }

    // MARK: - Chunk cap

    func testChunkCapIsBelowWhereThrottledUrlsStartRefusing() {
        // Throttled googlevideo URLs serve modest ranges and refuse past roughly 1 MB.
        XCTAssertLessThan(StreamingResourceLoader.maximumChunkSize, 1 << 20)
        // ...but not so small that a track becomes hundreds of requests.
        XCTAssertGreaterThanOrEqual(StreamingResourceLoader.maximumChunkSize, 256 << 10)
    }

    private static func parse(_ header: String) throws -> (Int64, Int64) {
        let body = header.replacingOccurrences(of: "bytes=", with: "")
        let parts = body.split(separator: "-")
        return (try XCTUnwrap(Int64(parts[0])), try XCTUnwrap(Int64(parts[1])))
    }
}
