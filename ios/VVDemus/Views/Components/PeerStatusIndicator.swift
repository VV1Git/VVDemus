import SwiftUI

/// Whether the paired device is reachable right now, shown at the top of Home on both platforms.
///
/// The link is silent by design — a peer that is asleep, on cellular or in another room is the
/// normal case for a LAN-only setup, not an error worth interrupting anyone over. That silence
/// is fine as long as there is somewhere to *look*, which is what this is: it answers "is the
/// other device there?" without ever demanding attention.
struct PeerStatusIndicator: View {
    @ObservedObject private var pairedStore = PairedPeerStore.shared
    @ObservedObject private var peer = PeerPlayback.shared
    @ObservedObject private var link = PeerLink.shared

    var body: some View {
        if let paired = pairedStore.peer {
            // Tappable, because "it says disconnected and it isn't" needs somewhere to go.
            //
            // A failed poll arms a backoff that doubles to 30s (`PeerPlayback.refresh`), which is
            // right for a peer that is genuinely asleep and wrong for the moment it comes back:
            // the dot could stay grey for half a minute after the phone was reachable again.
            // Home's Refresh looks like the answer and is not — it rebuilds the feed and never
            // touches the peer poll. `force` skips the backoff, and this is the control whose
            // whole subject is the thing being polled.
            Button {
                Task {
                    await PeerPlayback.shared.refresh(force: true)
                    await PeerLink.shared.syncNow()
                }
            } label: {
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
            }
            // Plain, so becoming a button changes what it *does* and not how it looks — the
            // system toolbar pill is still the only background here.
            .buttonStyle(.plain)
            // No capsule and no hover fill of its own: this is a toolbar item, and the system
            // gives a toolbar item both. Drawing them here produced a pill inside a pill — the
            // inner one ending short of the Refresh button while the outer one wrapped both.
            //
            // The inset stays, though. A system toolbar *button* carries its own internal
            // padding; a bare custom view does not, so with this removed as well the status dot
            // sat hard against the pill's left edge with the glyph crowding after it.
            .padding(.horizontal, Theme.Space.sm)
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
        guard peer.isPeerReachable else { return "\(name) isn't reachable right now — click to check again" }
        if let synced = link.lastSyncedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "\(name) is connected · synced \(formatter.localizedString(for: synced, relativeTo: Date()))"
        }
        return "\(name) is connected"
    }
}
