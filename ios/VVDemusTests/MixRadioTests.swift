import XCTest
@testable import VVDemus

/// A radio of several songs: the picks first, then songs like the *set* of them.
///
/// Exercised through the pure `MixRadioBlend` and a fake `RadioSource`, so nothing here goes
/// near YouTube. Most cases compare songs by id alone, so the fixtures' look-alike titles
/// ("Track a1", "Track a2") cannot be merged as one song by the title matcher; the one case
/// about that matcher uses real titles.
final class MixRadioTests: XCTestCase {

    private let byId: (Track, Track) -> Bool = { $0.videoId == $1.videoId }

    private func ids(_ tracks: [Track]) -> [String] { tracks.map(\.videoId) }

    private func blend(
        _ seeds: [String], _ radios: [[String]], limit: Int = 50, avoiding: Set<String> = []
    ) -> [String] {
        ids(MixRadioBlend.blend(
            seeds: Fixtures.tracks(seeds),
            radios: radios.map(Fixtures.tracks),
            limit: limit,
            avoiding: avoiding,
            isSameSong: byId
        ))
    }

    // MARK: - The picks

    func testPicksLeadInTheOrderTheyWerePicked() {
        let result = blend(["s1", "s2", "s3"], [["s1", "a"], ["s2", "b"], ["s3", "c"]])
        XCTAssertEqual(Array(result.prefix(3)), ["s1", "s2", "s3"])
    }

    func testAPickIsNotRepeatedWhenAnotherSeedsRadioSuggestsIt() {
        // s2 turning up in s1's radio is exactly the overlap a mix is made of, but it is
        // already in the list as a pick and must not appear a second time further down.
        let result = blend(["s1", "s2"], [["s1", "s2", "a"], ["s2", "s1", "b"]])
        XCTAssertEqual(result.filter { $0 == "s2" }.count, 1)
        XCTAssertEqual(result.filter { $0 == "s1" }.count, 1)
    }

    func testTheSamePickTwiceIsOnePick() {
        XCTAssertEqual(blend(["s1", "s1"], [["s1"], ["s1"]]), ["s1"])
    }

    // MARK: - Like the set, not like the first

    func testASongEveryRadioSharesOutranksAnyOneRadiosOwnPicks() {
        // `shared` sits at rank 5 in all three radios; `a1`, `b1`, `c1` each top one radio only.
        let result = blend(
            ["s1", "s2", "s3"],
            [
                ["s1", "a1", "a2", "a3", "a4", "shared"],
                ["s2", "b1", "b2", "b3", "b4", "shared"],
                ["s3", "c1", "c2", "c3", "c4", "shared"],
            ]
        )
        XCTAssertEqual(result[3], "shared")
    }

    func testWithNoOverlapTheSeedsTakeTurns() {
        // A single-seed radio would be all of a1…a3 before anything from the second seed.
        let result = blend(["s1", "s2"], [["s1", "a1", "a2", "a3"], ["s2", "b1", "b2", "b3"]])
        XCTAssertEqual(result, ["s1", "s2", "a1", "b1", "a2", "b2", "a3", "b3"])
    }

    func testASongIsCountedOncePerRadio() {
        // Two uploads of one song in the same radio must not vote for it twice.
        let dup = Fixtures.track("dup1", title: "Same Song", artist: "Band")
        let dupCopy = Fixtures.track("dup2", title: "Same Song", artist: "Band")
        let result = MixRadioBlend.blend(
            seeds: Fixtures.tracks(["s1", "s2"]),
            radios: [
                [Fixtures.track("s1"), dup, dupCopy],
                [Fixtures.track("s2"), Fixtures.track("b1"), Fixtures.track("b2")],
            ],
            limit: 50,
            isSameSong: { $0.title == $1.title && $0.artist == $1.artist }
        )
        XCTAssertEqual(ids(result), ["s1", "s2", "dup1", "b1", "b2"])
    }

    func testAVideoAndItsAudioUploadFromTwoRadiosCountAsOneSharedSong() {
        let video = Fixtures.track("vid", title: "The Less I Know The Better (Official Video)", artist: "Tame Impala")
        let audio = Fixtures.track("aud", title: "The Less I Know The Better", artist: "Tame Impala")
        let result = MixRadioBlend.blend(
            seeds: [Fixtures.track("s1", title: "Borderline", artist: "Tame Impala"),
                    Fixtures.track("s2", title: "Feels Like We Only Go Backwards", artist: "Tame Impala")],
            radios: [
                [Fixtures.track("x1", title: "Let It Happen", artist: "Tame Impala"), video],
                [Fixtures.track("y1", title: "Eventually", artist: "Tame Impala"), audio],
            ],
            limit: 50
        )
        let merged = ids(result).filter { $0 == "vid" || $0 == "aud" }
        XCTAssertEqual(merged, ["vid"], "one song, found by both radios")
        XCTAssertEqual(ids(result)[2], "vid", "and ranked as shared, ahead of either radio's own first pick")
    }

    // MARK: - Length and refresh

    func testTheLimitCountsThePicks() {
        let result = blend(["s1", "s2"], [["s1", "a1", "a2", "a3"], ["s2", "b1", "b2", "b3"]], limit: 4)
        XCTAssertEqual(result, ["s1", "s2", "a1", "b1"])
    }

    func testAvoidedSongsGoBehindEveryNewOneButStillFill() {
        let result = blend(
            ["s1"], [["s1", "old1", "old2", "new1", "new2"]],
            avoiding: ["old1", "old2"]
        )
        XCTAssertEqual(result, ["s1", "new1", "new2", "old1", "old2"])
    }

    // MARK: - Fetching

    func testOneSeedsRadioFailingStillBuildsFromTheRest() async throws {
        let source = FakeMixSource(radios: ["s1": ["s1", "a1"]])
        let result = try await MixRadioService.build(seeds: Fixtures.tracks(["s1", "s2"]), source: source, isSameSong: byId)
        XCTAssertEqual(ids(result), ["s1", "s2", "a1"])
    }

    func testEveryRadioFailingIsAnError() async {
        let source = FakeMixSource(radios: [:])
        do {
            _ = try await MixRadioService.build(seeds: Fixtures.tracks(["s1", "s2"]), source: source, isSameSong: byId)
            XCTFail("expected an error")
        } catch {}
    }

    func testARefreshReadsOnePageDeeper() async throws {
        let source = FakeMixSource(
            radios: ["s1": ["s1", "a1"]],
            continuations: ["s1": ["a2", "a3"]]
        )
        let first = try await MixRadioService.build(seeds: Fixtures.tracks(["s1"]), source: source, isSameSong: byId)
        XCTAssertEqual(ids(first), ["s1", "a1"], "a first build does not spend the extra request")

        let refreshed = try await MixRadioService.build(
            seeds: Fixtures.tracks(["s1"]), avoiding: ["a1"], source: source, isSameSong: byId
        )
        XCTAssertEqual(ids(refreshed), ["s1", "a2", "a3", "a1"])
    }

    // MARK: - Naming

    func testTitles() {
        let a = Fixtures.track("a", title: "Alpha")
        let b = Fixtures.track("b", title: "Beta")
        let c = Fixtures.track("c", title: "Gamma")
        XCTAssertEqual(MixRadio(seeds: [a]).title, "Alpha Radio")
        XCTAssertEqual(MixRadio(seeds: [a, b]).title, "Alpha + Beta Radio")
        XCTAssertEqual(MixRadio(seeds: [a, b, c]).title, "Alpha + 2 More Radio")
    }
}

/// Answers each seed with a fixed page, and its continuation token with a fixed second page.
/// A seed with no page throws, standing in for a request that failed.
private struct FakeMixSource: RadioSource {
    var radios: [String: [String]]
    var continuations: [String: [String]] = [:]

    struct Missing: Error {}

    func page(seed: String, limit: Int) async throws -> RadioPage {
        guard let ids = radios[seed] else { throw Missing() }
        return RadioPage(
            tracks: Fixtures.tracks(ids),
            continuation: continuations[seed] == nil ? nil : "next:\(seed)"
        )
    }

    func continuationPage(_ token: String) async throws -> RadioPage {
        let seed = String(token.dropFirst("next:".count))
        guard let ids = continuations[seed] else { throw Missing() }
        return RadioPage(tracks: Fixtures.tracks(ids), continuation: nil)
    }
}
