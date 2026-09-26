import Foundation

/// Shows what is playing on the Discord profile of whoever is signed in to Discord on this Mac.
///
/// Reads `PeerPlayback`'s displayed state rather than `PlayerService`'s, so a session the phone
/// owns — music coming out of the phone while this Mac mirrors it — is shown too. The rules for
/// what to show and when to send live in `DiscordPresencePolicy`; this type only runs them against
/// the clock and a socket.
@MainActor
final class DiscordPresence: ObservableObject {
    static let shared = DiscordPresence()

    enum Status: Equatable {
        case off
        /// No Discord application id was built in. See `DISCORD_CLIENT_ID` in project.yml.
        case notConfigured
        /// Discord is not running, or has not answered yet.
        case waitingForDiscord
        case connected
        /// Discord hung up with a reason — in practice, an application id it does not recognise.
        case rejected(String)
    }

    @Published private(set) var status: Status = .off

    /// The Discord application whose name follows "Listening to". Build-time rather than a setting,
    /// because it names one registered application and not a per-user choice.
    let clientId: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "DiscordClientID") as? String ?? ""
        // An unset build setting is left in the plist as the literal `$(DISCORD_CLIENT_ID)` by
        // some build paths rather than expanded to nothing.
        return value.allSatisfy(\.isNumber) ? value : ""
    }()

    private var connection: DiscordIPCConnection?
    private var timer: Timer?
    private var lastSent: DiscordPresencePolicy.Decision?
    private var lastSentAt: Date?
    private var pausedSince: Date?
    private var nextConnectAttempt = Date.distantPast

    /// Retrying a missing Discord every second would be a `stat` of ten paths a second for as long
    /// as Discord stays closed, which is most of the time for most people.
    private static let reconnectInterval: TimeInterval = 10

    private init() {}

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: DiscordPresencePolicy.enabledDefaultsKey)
    }

    func start() {
        guard timer == nil else { return }
        // Once a second, the same cadence `PeerPlayback` polls the phone at — nothing this shows can
        // change faster than that when the phone owns the session.
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { DiscordPresence.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// For the Settings toggle, so switching it on or off acts now rather than on the next tick.
    func enabledChanged() {
        nextConnectAttempt = .distantPast
        tick()
    }

    private func tick() {
        guard isEnabled else {
            disconnect()
            status = .off
            return
        }
        guard !clientId.isEmpty else {
            status = .notConfigured
            return
        }

        let now = Date()
        let playback = PeerPlayback.shared
        let isPlaying = playback.displayedIsPlaying
        if isPlaying || playback.displayedTrack == nil {
            pausedSince = nil
        } else if pausedSince == nil {
            pausedSince = now
        }

        guard let connection else {
            connectIfDue(now: now)
            return
        }
        // Handshake still in flight: anything sent before READY is ignored.
        guard status == .connected else { return }

        let decision = DiscordPresencePolicy.decide(.init(
            track: playback.displayedTrack,
            isPlaying: isPlaying,
            isLoading: playback.displayedIsLoading,
            progress: playback.displayedProgress,
            duration: playback.displayedDuration,
            pausedFor: pausedSince.map { now.timeIntervalSince($0) },
            now: now
        ))
        guard DiscordPresencePolicy.shouldSend(decision, lastSent: lastSent, lastSentAt: lastSentAt, now: now) else {
            return
        }

        switch decision {
        case .show(let activity):
            connection.send(DiscordIPC.setActivity(activity, pid: ProcessInfo.processInfo.processIdentifier))
        case .clear:
            connection.send(DiscordIPC.setActivity(nil, pid: ProcessInfo.processInfo.processIdentifier))
        case .hold:
            return
        }
        lastSent = decision
        lastSentAt = now
    }

    private func connectIfDue(now: Date) {
        guard now >= nextConnectAttempt else { return }
        nextConnectAttempt = now.addingTimeInterval(Self.reconnectInterval)

        var opened: DiscordIPCConnection?
        opened = DiscordIPCConnection.open(clientId: clientId) { [weak self] event in
            // Events from a connection that has since been replaced describe nothing current.
            guard let self, let opened, self.connection === opened else { return }
            self.handle(event)
        }
        connection = opened
        if opened == nil, !isRejected { status = .waitingForDiscord }
    }

    private func handle(_ event: DiscordIPCConnection.Event) {
        switch event {
        case .ready:
            status = .connected
            // A fresh connection starts with no activity, whatever the last one was showing.
            lastSent = nil
            lastSentAt = nil
            tick()
        case .commandError:
            // Logged by the connection. Forgetting what was sent means the next tick tries again,
            // under the same rate limit as any other send.
            lastSent = nil
        case .closed(let reason):
            connection = nil
            lastSent = nil
            lastSentAt = nil
            if let reason, isEnabled {
                status = .rejected(reason)
                // A rejected id stays rejected until someone rebuilds with a different one;
                // hammering Discord with it every ten seconds would change nothing.
                nextConnectAttempt = .distantFuture
            } else if isEnabled {
                status = .waitingForDiscord
            }
        }
    }

    private var isRejected: Bool {
        if case .rejected = status { return true }
        return false
    }

    private func disconnect() {
        // Closing the socket is itself what clears the card: Discord drops an application's
        // activity the moment its connection goes.
        connection?.close()
        connection = nil
        lastSent = nil
        lastSentAt = nil
        pausedSince = nil
        nextConnectAttempt = .distantPast
    }
}
