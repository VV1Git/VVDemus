import AppKit
import Combine
import IOKit.pwr_mgt

/// Keeps the Mac awake while music plays, as far as Settings ▸ Stay Awake allows.
///
/// Two separate mechanisms, because macOS has two separate reasons to sleep. The idle timer is
/// answered by a power assertion, which any app may take. The lid is not: closing it with no
/// external display sleeps the Mac whatever assertions are held, and the only switch that
/// overrides it is `pmset disablesleep`, which needs root. Root is granted once, through the
/// administrator prompt, as a sudoers rule naming that one command — after which it can be flipped
/// with the lid already shut and nobody there to type a password.
///
/// The rules for when either is wanted live in `StayAwakePolicy`; this type only applies them.
@MainActor
final class StayAwake: ObservableObject {
    static let shared = StayAwake()

    /// The sudoers rule is in place and answers without a password.
    @Published private(set) var lidAuthorized = false
    /// The administrator prompt is up, or the rule is being written or removed.
    @Published private(set) var isAsking = false
    /// Lid sleep is switched off right now — by this app, or already by someone else.
    @Published private(set) var lidSleepDisabled = false
    @Published private(set) var lidError: String?

    private var assertion: IOPMAssertionID?
    private var lastPlayingAt: Date?
    /// Whether this app is the one that switched lid sleep off. Sleep someone had already disabled
    /// by hand is theirs, and is left disabled when playback stops.
    private var ownsLidSleep = false
    private var lidChangeInFlight = false
    private var wantsLidSleepDisabled = false
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    func start() {
        guard timer == nil else { return }

        if UserDefaults.standard.bool(forKey: StayAwakePolicy.lidSleepDisabledByAppDefaultsKey) {
            // The last run switched lid sleep off and never put it back.
            ownsLidSleep = true
            lidSleepDisabled = true
        }

        let player = PlayerService.shared
        // `@Published` emits before the property changes; hopping to the next run-loop turn is
        // what lets `tick` read the new value rather than the one being replaced.
        player.$isPlaying.combineLatest(player.$isLoading, player.$currentTrack)
            .receive(on: RunLoop.main)
            .sink { _ in StayAwake.shared.tick() }
            .store(in: &cancellables)

        // Only the pause grace needs a clock; everything else is driven by the player.
        let timer = Timer(timeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { StayAwake.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { StayAwake.shared.restoreBeforeQuit() }
        }

        Task {
            await refreshAuthorization()
            tick()
        }
    }

    /// For the Settings toggles, so a change acts now rather than on the next tick.
    func settingsChanged() {
        tick()
    }

    /// Settings ▸ Keep playing with the lid closed. Switching it on asks for permission when there
    /// is none yet, and switches itself back off if that is refused; switching it off restores
    /// lid sleep and offers to remove the permission again.
    func lidClosedChanged(_ enabled: Bool) async {
        if enabled {
            guard !lidAuthorized else { return tick() }
            isAsking = true
            let error = await Self.installRule()
            await refreshAuthorization()
            isAsking = false
            if !lidAuthorized {
                lidError = error
                UserDefaults.standard.set(false, forKey: StayAwakePolicy.lidClosedDefaultsKey)
            } else {
                lidError = nil
            }
            tick()
        } else {
            tick()
            guard lidAuthorized else { return }
            // Lid sleep is put back first, while the rule still lets it be done without a prompt.
            // Bounded, so a restore that keeps failing cannot hold the toggle forever.
            var waited = 0
            while lidChangeInFlight || (lidSleepDisabled && ownsLidSleep), waited < 50 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            isAsking = true
            _ = await Self.removeRule()
            await refreshAuthorization()
            isAsking = false
            lidError = nil
        }
    }

    private func tick() {
        let player = PlayerService.shared
        let now = Date()
        let active = player.isPlaying || player.isLoading
        if active { lastPlayingAt = now }
        if player.currentTrack == nil { lastPlayingAt = nil }

        let defaults = UserDefaults.standard
        let decision = StayAwakePolicy.decide(.init(
            whilePlayingEnabled: defaults.bool(forKey: StayAwakePolicy.whilePlayingDefaultsKey),
            lidClosedEnabled: defaults.bool(forKey: StayAwakePolicy.lidClosedDefaultsKey),
            lidClosedAuthorized: lidAuthorized,
            isPlaying: player.isPlaying,
            isLoading: player.isLoading,
            pausedFor: active ? nil : lastPlayingAt.map { now.timeIntervalSince($0) }
        ))
        setIdleAssertion(decision.preventIdleSleep)
        setLidSleepDisabled(decision.disableLidSleep)
    }

    // MARK: - Idle sleep

    private func setIdleAssertion(_ wanted: Bool) {
        if wanted, assertion == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Playing music" as CFString,
                &id
            )
            if result == kIOReturnSuccess { assertion = id }
        } else if !wanted, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }

    // MARK: - Lid sleep

    private func setLidSleepDisabled(_ wanted: Bool) {
        wantsLidSleepDisabled = wanted
        guard !lidChangeInFlight, wanted != lidSleepDisabled else { return }
        lidChangeInFlight = true
        let owned = ownsLidSleep
        Task.detached {
            let outcome = Self.applyLidSleep(disabled: wanted, owned: owned)
            await MainActor.run { StayAwake.shared.finishLidChange(disabled: wanted, outcome: outcome) }
        }
    }

    private enum LidOutcome {
        case applied(owned: Bool)
        case failed(String)
    }

    private func finishLidChange(disabled: Bool, outcome: LidOutcome) {
        lidChangeInFlight = false
        switch outcome {
        case .applied(let owned):
            lidSleepDisabled = disabled
            ownsLidSleep = disabled && owned
            lidError = nil
            UserDefaults.standard.set(ownsLidSleep, forKey: StayAwakePolicy.lidSleepDisabledByAppDefaultsKey)
        case .failed(let message):
            lidError = message
            if disabled {
                // Most likely the rule was removed behind this app's back. Without rechecking,
                // every play would retry and fail the same way.
                Task { await refreshAuthorization() }
                return
            }
        }
        if wantsLidSleepDisabled != lidSleepDisabled, lidAuthorized || !wantsLidSleepDisabled {
            setLidSleepDisabled(wantsLidSleepDisabled)
        }
    }

    nonisolated private static func applyLidSleep(disabled: Bool, owned: Bool) -> LidOutcome {
        if disabled {
            if StayAwakePolicy.sleepDisabled(inPmsetOutput: run(StayAwakePolicy.pmsetPath, ["-g"]).output) {
                return .applied(owned: false)
            }
        } else if !owned {
            return .applied(owned: false)
        }
        let result = run("/usr/bin/sudo", ["-n", StayAwakePolicy.pmsetPath, "-a", "disablesleep", disabled ? "1" : "0"])
        guard result.status == 0 else {
            return .failed(disabled ? "Couldn't keep the Mac awake with the lid closed" : "Couldn't turn lid sleep back on")
        }
        return .applied(owned: true)
    }

    /// Synchronous: the process is about to exit, and a task started now would not finish.
    private func restoreBeforeQuit() {
        setIdleAssertion(false)
        guard lidSleepDisabled, ownsLidSleep else { return }
        if case .applied = Self.applyLidSleep(disabled: false, owned: true) {
            UserDefaults.standard.set(false, forKey: StayAwakePolicy.lidSleepDisabledByAppDefaultsKey)
        }
    }

    // MARK: - Permission

    private func refreshAuthorization() async {
        lidAuthorized = await Task.detached {
            Self.run("/usr/bin/sudo", ["-n", "-l", StayAwakePolicy.pmsetPath, "-a", "disablesleep", "1"]).status == 0
        }.value
    }

    /// Writes the sudoers rule through the administrator prompt. Returns why it did not, or `nil`.
    nonisolated private static func installRule() async -> String? {
        guard let rule = StayAwakePolicy.sudoersRule(user: NSUserName()) else {
            return "This account's name can't be used in a sudoers rule"
        }
        // Checked by `visudo` before it is moved into place: a malformed file in sudoers.d breaks
        // `sudo` for every command on the Mac, not just this one.
        let script = """
            f=$(/usr/bin/mktemp) && /usr/bin/printf '%s\\n' '\(rule)' > "$f" \
            && /usr/sbin/visudo -cqf "$f" && /usr/sbin/chown root:wheel "$f" && /bin/chmod 0440 "$f" \
            && /bin/mv -f "$f" '\(StayAwakePolicy.sudoersPath)'
            """
        let prompt = "Spotify β wants to keep your Mac awake with the lid closed while music is playing."
        return await runAsAdministrator(script, prompt: prompt) ? nil : "Permission wasn't given"
    }

    nonisolated private static func removeRule() async -> Bool {
        let prompt = "Spotify β wants to remove its permission to keep your Mac awake with the lid closed."
        return await runAsAdministrator("/bin/rm -f '\(StayAwakePolicy.sudoersPath)'", prompt: prompt)
    }

    nonisolated private static func runAsAdministrator(_ shell: String, prompt: String) async -> Bool {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let source = "do shell script \(quoted(shell)) with prompt \(quoted(prompt)) with administrator privileges"
        return await Task.detached { run("/usr/bin/osascript", ["-e", source]).status == 0 }.value
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
