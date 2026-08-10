import SwiftUI

/// Whether the paired phone is reachable right now, shown at the top of Home.
///
/// The link is silent by design — a peer that is asleep, on cellular or in another room is the
/// normal case for a LAN-only setup, not an error worth interrupting anyone over. That silence
/// is fine as long as there is somewhere to *look*, which is what this is: it answers "is the
/// other device there?" without ever demanding attention.
struct PhoneStatusIndicator: View {
    @ObservedObject private var pairedStore = PairedPeerStore.shared
    @ObservedObject private var peer = PeerPlayback.shared
    @ObservedObject private var link = PeerLink.shared
    @State private var isHovering = false

    var body: some View {
        if let paired = pairedStore.peer {
            HStack(spacing: Theme.Space.xs) {
                Circle()
                    .fill(peer.isPeerReachable ? Theme.accent : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                Image(systemName: paired.isDesktop ? "desktopcomputer" : "iphone")
                    .font(.caption)
                Text(paired.name)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(peer.isPeerReachable ? .primary : .secondary)
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, Theme.Space.xs)
            .background(
                Capsule().fill(isHovering ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06))
            )
            .onHover { isHovering = $0 }
            .help(helpText(paired.name))
            // Reachability is carried entirely by the dot's fill colour, which VoiceOver cannot
            // read, so `helpText` has to stand in for it — and a label on a multi-child `HStack`
            // is ignored while the children stay separately focusable. Combining first is what
            // makes this one element the label actually applies to.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(helpText(paired.name))
        }
    }

    private func helpText(_ name: String) -> String {
        guard peer.isPeerReachable else { return "\(name) isn't reachable right now" }
        if let synced = link.lastSyncedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "\(name) is connected · synced \(formatter.localizedString(for: synced, relativeTo: Date()))"
        }
        return "\(name) is connected"
    }
}
