import SwiftUI

/// Settings ▸ Show on Discord.
struct DiscordPresenceSection: View {
    @AppStorage(DiscordPresencePolicy.enabledDefaultsKey) private var enabled = false
    @ObservedObject private var presence = DiscordPresence.shared

    var body: some View {
        Section {
            Toggle("Show on Discord", isOn: $enabled)
                .onChange(of: enabled) { _, _ in presence.enabledChanged() }

            if enabled {
                LabeledContent("Status") {
                    Text(statusText)
                        .foregroundStyle(statusIsProblem ? Theme.warning : .secondary)
                }
            }
        } footer: {
            Text("Shows the song you're listening to on your Discord profile, the way Spotify does — including music playing from your paired phone while this app is open. Needs the Discord desktop app running on this Mac. It's hidden after about ten seconds paused.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        switch presence.status {
        case .off: return "Off"
        case .notConfigured: return "No Discord application ID in this build"
        case .waitingForDiscord: return "Waiting for Discord to open"
        case .connected: return "Connected"
        case .rejected(let reason): return "Discord refused: \(reason)"
        }
    }

    private var statusIsProblem: Bool {
        switch presence.status {
        case .notConfigured, .rejected: return true
        default: return false
        }
    }
}
