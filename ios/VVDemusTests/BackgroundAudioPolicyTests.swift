import XCTest
@testable import VVDemus

/// The rule that decides whether the app keeps its audio session.
///
/// This exists because getting it wrong is silent and severe: a paused music app that
/// deactivates its session loses the Now Playing slot, and every AirPods press afterwards
/// goes to some other app. The reported symptom was "pause with my AirPods works, play
/// again doesn't" — which is exactly what that looks like from the outside.
final class BackgroundAudioPolicyTests: XCTestCase {

    private func decide(
        backgrounded: Bool = true,
        playing: Bool = false,
        device: PlaybackDevice = .iphone,
        server: Bool = true
    ) -> BackgroundAudioPolicy.Decision {
        BackgroundAudioPolicy.decide(
            .init(
                isBackgrounded: backgrounded,
                isPlaying: playing,
                activeDevice: device,
                isConnectServerRunning: server
            )
        )
    }

    // MARK: - The reported bug

    /// Pausing on the phone must never release the session, screen locked or not. Releasing
    /// hands away the remote-control slot, so the next AirPods press cannot resume.
    func testPausingOnThePhoneNeverReleasesTheSession() {
        XCTAssertFalse(decide(backgrounded: true, playing: false, device: .iphone, server: true).releaseSession)
        XCTAssertFalse(decide(backgrounded: true, playing: false, device: .iphone, server: false).releaseSession,
                       "Connect being off is not a reason to give up the AirPods controls")
        XCTAssertFalse(decide(backgrounded: false, playing: false, device: .iphone).releaseSession)
    }

    func testPlayingOnThePhoneNeverReleasesTheSession() {
        XCTAssertFalse(decide(backgrounded: true, playing: true, device: .iphone).releaseSession)
        XCTAssertFalse(decide(backgrounded: false, playing: true, device: .iphone).releaseSession)
    }

    // MARK: - The one case that should release

    /// Casting with nothing playing anywhere: the phone has no business holding the route,
    /// and letting go is what allows AirPods to follow the Mac.
    func testReleasesOnlyWhenCastingAndPaused() {
        XCTAssertTrue(decide(backgrounded: true, playing: false, device: .computer).releaseSession)
    }

    func testDoesNotReleaseWhileTheComputerIsActuallyPlaying() {
        XCTAssertFalse(decide(backgrounded: true, playing: true, device: .computer).releaseSession)
    }

    func testDoesNotReleaseInTheForeground() {
        // A foreground pause used to deactivate with `.notifyOthersOnDeactivation`, which
        // resumed whatever podcast the user had paused elsewhere.
        XCTAssertFalse(decide(backgrounded: false, playing: false, device: .computer).releaseSession)
    }

    // MARK: - Keep-alive

    /// The clip must never run while the phone itself is the active device. Starting a
    /// second audio player on an ordinary pause is what broke resuming from AirPods.
    func testKeepAliveNeverRunsWhileThePhoneIsTheActiveDevice() {
        XCTAssertFalse(decide(backgrounded: true, playing: false, device: .iphone, server: true).runKeepAlive,
                       "A paused phone must not start a silent clip — AirPods resume breaks")
        XCTAssertFalse(decide(backgrounded: true, playing: true, device: .iphone, server: true).runKeepAlive)
    }

    func testKeepAliveRequiresBackgroundAndTheServer() {
        XCTAssertFalse(decide(backgrounded: false, playing: true, device: .computer, server: true).runKeepAlive,
                       "Nothing to keep alive in the foreground")
        XCTAssertFalse(decide(backgrounded: true, playing: true, device: .computer, server: false).runKeepAlive,
                       "Nothing to keep alive without the server")
    }

    /// While casting and playing, the phone is silent but must stay alive to keep serving
    /// the browser.
    func testKeepAliveRunsWhileCastingAndPlaying() {
        XCTAssertTrue(decide(backgrounded: true, playing: true, device: .computer, server: true).runKeepAlive)
    }

    /// The two outcomes are mutually exclusive — running a clip and giving up the session
    /// at the same moment would fight each other.
    func testNeverKeepsAliveAndReleasesAtOnce() {
        for backgrounded in [true, false] {
            for playing in [true, false] {
                for device in [PlaybackDevice.iphone, .computer] {
                    for server in [true, false] {
                        let d = decide(backgrounded: backgrounded, playing: playing, device: device, server: server)
                        XCTAssertFalse(d.runKeepAlive && d.releaseSession,
                                       "b=\(backgrounded) p=\(playing) d=\(device) s=\(server)")
                    }
                }
            }
        }
    }

    // MARK: - Mirroring the Mac

    /// Locked phone, Mac playing: the phone keeps itself alive to stay in the group.
    func testKeepAliveRunsWhileMirroringAPlayingMac() {
        let decision = BackgroundAudioPolicy.decide(.init(
            isBackgrounded: true, isPlaying: true, activeDevice: .iphone,
            isConnectServerRunning: true, isMirroringPeer: true
        ))
        XCTAssertTrue(decision.runKeepAlive)
    }

    /// `BackgroundKeepAlive` always mixes on the strength of this: the clip only ever runs while
    /// the sound is coming from somewhere else, so there is never a reason for it to take the route.
    func testKeepAliveOnlyEverRunsWhileTheSoundIsElsewhere() {
        for backgrounded in [true, false] {
            for playing in [true, false] {
                for device in [PlaybackDevice.iphone, .computer] {
                    for server in [true, false] {
                        for mirroring in [true, false] {
                            let decision = BackgroundAudioPolicy.decide(.init(
                                isBackgrounded: backgrounded, isPlaying: playing, activeDevice: device,
                                isConnectServerRunning: server, isMirroringPeer: mirroring
                            ))
                            if decision.runKeepAlive {
                                XCTAssertTrue(device == .computer || mirroring,
                                              "b=\(backgrounded) p=\(playing) d=\(device) s=\(server) m=\(mirroring)")
                            }
                        }
                    }
                }
            }
        }
    }

    /// The reported bug: Mac playing to AirPods, phone locked, AirPods jump to the phone and the Mac
    /// pauses. The clip took the route whenever it was not casting to a browser — including while
    /// mirroring the Mac — and a route-taking session is what iOS reads as "you have moved back to
    /// the phone".
    @MainActor
    func testTheKeepAliveClipNeverTakesTheRoute() {
        let session = FakeAudioSession()
        let keepAlive = BackgroundKeepAlive(session: session)
        keepAlive.start()
        defer { keepAlive.stop() }
        XCTAssertEqual(session.activations, [.init(casting: true)])
    }
}
