import Foundation

/// When the Mac should be kept from sleeping, and how lid-closed playback is granted.
///
/// Pulled out of `StayAwake` (MacApp) for the same reason as `DiscordPresencePolicy`: the cases
/// worth checking — a pause, the grace after one, a setting switched on without permission — are
/// timing and state questions that should not need a lid to close to reach. Compiled into both
/// targets so the suite can run it; only the Mac ever acts on it.
enum StayAwakePolicy {
    /// Keeps the Mac from idling to sleep while music plays. Covers clamshell mode with an
    /// external display, where the lid is already shut and only the idle timer stops playback.
    static let whilePlayingDefaultsKey = "stayAwakeWhilePlaying"

    /// Keeps playing with the lid closed and no external display — what macOS otherwise always
    /// sleeps on. Needs an administrator's permission, so it is off until someone grants it.
    static let lidClosedDefaultsKey = "stayAwakeWithLidClosed"

    /// Set while this app has lid sleep switched off, and cleared when it puts it back. A crash in
    /// between would otherwise leave the Mac unable to sleep on lid close with nothing to say why;
    /// the next launch sees this and restores it.
    static let lidSleepDisabledByAppDefaultsKey = "lidSleepDisabledByApp"

    /// How long after a pause the Mac is still held awake. Long enough to resume from the phone or
    /// the web remote with the lid shut — the server has to be awake to hear it — and short enough
    /// that a laptop left paused in a bag does go to sleep.
    static let pauseGrace: TimeInterval = 120

    /// The one file this feature adds to `/etc/sudoers.d`.
    static let sudoersPath = "/etc/sudoers.d/vvdemus-lid-sleep"
    static let pmsetPath = "/usr/bin/pmset"

    struct Inputs {
        var whilePlayingEnabled: Bool
        var lidClosedEnabled: Bool
        /// Whether the sudoers rule is in place, so `pmset` can be run without a password prompt
        /// — which is the only way it can run once the lid is shut and nobody can type one.
        var lidClosedAuthorized: Bool
        var isPlaying: Bool
        var isLoading: Bool
        /// How long playback has been paused with a track still loaded, or `nil` when it is
        /// playing or there is nothing to resume.
        var pausedFor: TimeInterval?
    }

    struct Decision: Equatable {
        /// An idle-sleep assertion: the display may still sleep, the system does not.
        var preventIdleSleep: Bool
        /// `pmset disablesleep 1`: the system does not sleep even when the lid closes.
        var disableLidSleep: Bool

        static let none = Decision(preventIdleSleep: false, disableLidSleep: false)
    }

    static func decide(_ input: Inputs) -> Decision {
        let active = input.isPlaying || input.isLoading || (input.pausedFor.map { $0 < pauseGrace } ?? false)
        guard active else { return .none }
        let lid = input.lidClosedEnabled && input.lidClosedAuthorized
        // Lid-closed playback implies the idle case too: a Mac that stays up with its lid shut
        // should not then doze off from the idle timer halfway through an album.
        return Decision(preventIdleSleep: input.whilePlayingEnabled || lid, disableLidSleep: lid)
    }

    /// The sudoers line that lets `user` switch lid sleep off and on without a password, and
    /// nothing else. `nil` for a name that is not a plain account name — it is spliced into a
    /// root-owned file, so anything that could carry sudoers syntax is refused outright.
    static func sudoersRule(user: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !user.isEmpty, !user.hasPrefix("-"), user.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }
        return "\(user) ALL=(root) NOPASSWD: \(pmsetPath) -a disablesleep 0, \(pmsetPath) -a disablesleep 1"
    }

    /// Whether `pmset -g` output reports sleep as already disabled.
    static func sleepDisabled(inPmsetOutput output: String) -> Bool {
        output.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 2 && fields[0] == "SleepDisabled" && fields[1] == "1"
        }
    }
}
