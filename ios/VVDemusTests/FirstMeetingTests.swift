import XCTest
@testable import VVDemus

/// Which device keeps its session when the two first see each other.
///
/// The failure mode is loud and immediate — the music stops mid-song on the device someone is
/// listening to, because the other one decided it was in charge — and it is only reachable by
/// arranging two devices in a particular pair of states at the moment they connect. That is
/// exactly the kind of thing that is answered here instead.
///
/// The property that matters most is **symmetry**: both devices run this independently, and if
/// they can both conclude they won, two sessions play at once.
@MainActor
final class FirstMeetingTests: XCTestCase {
    private func meeting(
        localPlaying: Bool,
        peerPlaying: Bool,
        localDesktop: Bool = false,
        peerDesktop: Bool = true,
        localId: String = "peer-aaa",
        peerId: String = "peer-zzz"
    ) -> FirstMeeting {
        FirstMeeting(
            localIsPlaying: localPlaying,
            peerIsPlaying: peerPlaying,
            localIsDesktop: localDesktop,
            peerIsDesktop: peerDesktop,
            localPeerId: localId,
            peerPeerId: peerId
        )
    }

    /// Whatever the two devices are, exactly one of them must come away with the session.
    private func assertSymmetric(
        _ m: FirstMeeting,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let mirrored = FirstMeeting(
            localIsPlaying: m.peerIsPlaying,
            peerIsPlaying: m.localIsPlaying,
            localIsDesktop: m.peerIsDesktop,
            peerIsDesktop: m.localIsDesktop,
            localPeerId: m.peerPeerId,
            peerPeerId: m.localPeerId
        )
        XCTAssertNotEqual(
            m.localKeepsSession,
            mirrored.localKeepsSession,
            "both devices decided the same way — that is either two sessions playing at once, or none",
            file: file,
            line: line
        )
    }

    func testTheDevicePlayingKeepsTheSession() {
        XCTAssertTrue(meeting(localPlaying: true, peerPlaying: false).localKeepsSession)
        XCTAssertFalse(meeting(localPlaying: false, peerPlaying: true).localKeepsSession)
    }

    /// Playing beats being a desktop. The phone here is the one making sound and the peer is a
    /// Mac; the Mac must not interrupt it just for being a Mac.
    func testPlayingBeatsTheDesktopTiebreak() {
        let phonePlayingAgainstIdleMac = meeting(
            localPlaying: true, peerPlaying: false, localDesktop: false, peerDesktop: true
        )
        XCTAssertTrue(phonePlayingAgainstIdleMac.localKeepsSession)
        assertSymmetric(phonePlayingAgainstIdleMac)
    }

    func testTheDesktopBreaksATieWhenBothArePlaying() {
        let phone = meeting(localPlaying: true, peerPlaying: true, localDesktop: false, peerDesktop: true)
        XCTAssertFalse(phone.localKeepsSession, "the Mac is the device you are sat in front of")
        assertSymmetric(phone)
    }

    func testTheDesktopBreaksATieWhenBothArePaused() {
        let phone = meeting(localPlaying: false, peerPlaying: false, localDesktop: false, peerDesktop: true)
        XCTAssertFalse(phone.localKeepsSession)
        assertSymmetric(phone)
    }

    /// Two devices of the same kind — a Mac paired to a Mac, or a phone to a phone — have no
    /// desktop tiebreak left, so the ids decide. Any answer will do provided both reach it.
    func testTwoDevicesOfTheSameKindStillAgree() {
        let bothMacsPaused = meeting(
            localPlaying: false, peerPlaying: false,
            localDesktop: true, peerDesktop: true,
            localId: "peer-aaa", peerId: "peer-zzz"
        )
        XCTAssertFalse(bothMacsPaused.localKeepsSession)
        assertSymmetric(bothMacsPaused)

        let bothPhonesPlaying = meeting(
            localPlaying: true, peerPlaying: true,
            localDesktop: false, peerDesktop: false,
            localId: "peer-zzz", peerId: "peer-aaa"
        )
        XCTAssertTrue(bothPhonesPlaying.localKeepsSession)
        assertSymmetric(bothPhonesPlaying)
    }

    /// The whole table, both ways round. Any clause that ever prefers "me" rather than comparing
    /// the two sides shows up here as both devices keeping the session.
    func testExactlyOneDeviceEverKeepsTheSession() {
        for localPlaying in [true, false] {
            for peerPlaying in [true, false] {
                for localDesktop in [true, false] {
                    for peerDesktop in [true, false] {
                        assertSymmetric(meeting(
                            localPlaying: localPlaying,
                            peerPlaying: peerPlaying,
                            localDesktop: localDesktop,
                            peerDesktop: peerDesktop
                        ))
                    }
                }
            }
        }
    }
}
