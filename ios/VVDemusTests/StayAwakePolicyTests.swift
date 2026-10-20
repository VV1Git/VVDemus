import XCTest
@testable import VVDemus

/// When the Mac is held awake, and what the lid-closed permission is allowed to grant.
///
/// The real thing needs a lid to shut and an administrator to type a password; every decision
/// behind it is reachable here without either.
final class StayAwakePolicyTests: XCTestCase {

    private func decide(
        whilePlaying: Bool = false,
        lidClosed: Bool = false,
        authorized: Bool = false,
        playing: Bool = true,
        loading: Bool = false,
        pausedFor: TimeInterval? = nil
    ) -> StayAwakePolicy.Decision {
        StayAwakePolicy.decide(.init(
            whilePlayingEnabled: whilePlaying,
            lidClosedEnabled: lidClosed,
            lidClosedAuthorized: authorized,
            isPlaying: playing,
            isLoading: loading,
            pausedFor: pausedFor
        ))
    }

    // MARK: - Idle sleep

    func testBothOffNeverHoldsTheMacAwake() {
        XCTAssertEqual(decide(), .none)
    }

    func testStayAwakeWhilePlayingHoldsOffIdleSleepOnly() {
        XCTAssertEqual(decide(whilePlaying: true), .init(preventIdleSleep: true, disableLidSleep: false))
    }

    /// Between tracks the player reports loading rather than playing; the Mac should not get a
    /// window to fall asleep in.
    func testLoadingCountsAsPlaying() {
        XCTAssertTrue(decide(whilePlaying: true, playing: false, loading: true).preventIdleSleep)
    }

    func testAShortPauseStillHoldsTheMacAwake() {
        XCTAssertTrue(decide(whilePlaying: true, playing: false, pausedFor: 30).preventIdleSleep)
    }

    func testThePauseGraceRunsOut() {
        XCTAssertEqual(
            decide(whilePlaying: true, lidClosed: true, authorized: true, playing: false, pausedFor: StayAwakePolicy.pauseGrace),
            .none
        )
    }

    /// `pausedFor` is `nil` when nothing is loaded — stopped, not paused — and there is nothing to
    /// stay awake for.
    func testNothingLoadedLetsTheMacSleep() {
        XCTAssertEqual(decide(whilePlaying: true, lidClosed: true, authorized: true, playing: false), .none)
    }

    // MARK: - Lid sleep

    func testLidClosedNeedsPermission() {
        XCTAssertEqual(decide(lidClosed: true, authorized: false), .none)
    }

    func testLidClosedWithPermissionAlsoHoldsOffIdleSleep() {
        XCTAssertEqual(decide(lidClosed: true, authorized: true), .init(preventIdleSleep: true, disableLidSleep: true))
    }

    /// The permission outlives the setting until it is removed; it must not act on its own.
    func testPermissionAloneDoesNothing() {
        XCTAssertEqual(decide(authorized: true), .none)
    }

    // MARK: - The sudoers rule

    func testRuleGrantsExactlyTheTwoPmsetCommands() {
        XCTAssertEqual(
            StayAwakePolicy.sudoersRule(user: "jane.doe"),
            "jane.doe ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        )
    }

    /// The name is written into a root-owned file; anything that could carry sudoers or shell
    /// syntax is refused rather than escaped.
    func testRuleRefusesNamesThatAreNotPlainAccountNames() {
        for name in ["", "-rf", "a b", "a,ALL", "x'y", "a\nb", "%admin", "a=b"] {
            XCTAssertNil(StayAwakePolicy.sudoersRule(user: name), name)
        }
    }

    // MARK: - Reading pmset

    func testReadsSleepDisabledFromPmset() {
        let on = """
            System-wide power settings:
             SleepDisabled\t\t1
            Currently in use:
             sleep                1
            """
        XCTAssertTrue(StayAwakePolicy.sleepDisabled(inPmsetOutput: on))
        XCTAssertFalse(StayAwakePolicy.sleepDisabled(inPmsetOutput: on.replacingOccurrences(of: "\t\t1", with: "\t\t0")))
        XCTAssertFalse(StayAwakePolicy.sleepDisabled(inPmsetOutput: "Currently in use:\n sleep 1\n"))
    }
}
