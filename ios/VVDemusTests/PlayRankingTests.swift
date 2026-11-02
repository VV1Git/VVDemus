import XCTest
@testable import VVDemus

/// The Stats leaderboards' order, which has to be the same every time for the same plays.
final class PlayRankingTests: XCTestCase {

    private func play(_ id: String, artist: String = "A", at seconds: TimeInterval) -> PlayEvent {
        PlayEvent(
            track: Track(videoId: id, title: id, artist: artist, album: nil, thumbnailUrl: nil, durationSeconds: 100),
            playedAt: Date(timeIntervalSince1970: seconds), secondsPlayed: 100
        )
    }

    private func ranked(_ events: [PlayEvent], limit: Int = 10) -> [String] {
        PlayRanking.top(events, by: \.track.videoId, limit: limit).map(\.key)
    }

    func testMorePlaysRankHigher() {
        XCTAssertEqual(ranked([play("a", at: 1), play("b", at: 2), play("b", at: 3)]), ["b", "a"])
    }

    func testATieGoesToTheMoreRecentlyPlayed() {
        XCTAssertEqual(ranked([play("a", at: 5), play("b", at: 9), play("c", at: 1)]), ["b", "a", "c"])
    }

    func testATieOnBothGoesByKey() {
        XCTAssertEqual(ranked([play("b", at: 1), play("a", at: 1)]), ["a", "b"])
    }

    /// The bug itself: the same plays, counted again and again, in any order, rank the same.
    func testTheSamePlaysAlwaysRankTheSame() {
        let events = (0..<30).map { play("s\($0 % 12)", at: TimeInterval($0 % 3)) }
        let first = ranked(events, limit: 5)
        for _ in 0..<50 {
            XCTAssertEqual(ranked(events.shuffled(), limit: 5), first)
        }
    }
}
