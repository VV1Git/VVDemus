import SwiftUI

/// "Playing on <device> ▾" — the one control that moves playback between the paired devices.
///
/// It replaced a handoff button that only pushed, and only from the device that happened to hold
/// the session. A picker says the true thing instead: here are the devices, this is the one making
/// the sound, choose another. Both devices show the same two rows and either can move playback,
/// which is what makes the pair feel like one player rather than two apps that can talk.
///
/// Deliberately not a `PlaybackDevice` control. That enum is the browser's `.iphone`/`.computer`
/// cast switch and means something else entirely; this moves the whole session between two paired
/// apps and never touches it.
struct DevicePicker: View {
    @ObservedObject private var pairedStore = PairedPeerStore.shared
    @ObservedObject private var peer = PeerPlayback.shared
    @ObservedObject private var link = PeerLink.shared

    /// The bar this sits in is at the bottom of the window on both platforms, so the menu has to
    /// open upward or it opens off-screen.
    var opensUpward = true

    var body: some View {
        if let paired = pairedStore.peer {
            Menu {
                deviceRow(
                    name: thisDeviceName,
                    systemImage: PeerIdentity.shared.isDesktop ? "desktopcomputer" : "iphone",
                    isActive: !peer.isMirroring,
                    action: playHere
                )
                deviceRow(
                    name: paired.name,
                    systemImage: paired.isDesktop ? "desktopcomputer" : "iphone",
                    isActive: peer.isMirroring,
                    action: playOnPeer
                )
            } label: {
                label(paired: paired)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .menuOrder(opensUpward ? .fixed : .automatic)
            // `.fixedSize()` only where there is room to be honoured. The iPhone transport row is
            // six rigid fixed-frame controls with one `Spacer`, so a label that refuses to
            // compress — carrying a device name of any length — makes the row wider than the
            // screen and pushes the Queue button off the edge entirely.
            #if os(macOS)
            .fixedSize()
            #endif
            // Visible but inert while a move is in flight, rather than vanishing: this is the only
            // way to move playback now, and a control that disappears mid-press reads as broken.
            .disabled(link.isHandingOff || !peer.isPeerReachable)
            .help(peer.isPeerReachable ? "Choose where the music plays" : "\(paired.name) isn't reachable")
            .accessibilityLabel("Playing on \(activeDeviceName(paired: paired))")
        }
    }

    private var thisDeviceName: String {
        // "This Computer" / "This iPhone" rather than the machine's own name: on the device you
        // are looking at, its name tells you nothing the word "this" does not.
        PeerIdentity.shared.isDesktop ? "This Computer" : "This iPhone"
    }

    private func activeDeviceName(paired: PairedPeer) -> String {
        peer.isMirroring ? paired.name : thisDeviceName
    }

    @ViewBuilder
    private func deviceRow(
        name: String,
        systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // The checkmark rather than only a tint: which device is playing is the single fact
            // this menu exists to state, and colour alone does not state it to everyone.
            Label(name, systemImage: isActive ? "checkmark" : systemImage)
        }
        .disabled(isActive)
    }

    private func label(paired: PairedPeer) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: peer.isMirroring
                ? (paired.isDesktop ? "desktopcomputer" : "iphone")
                : "hifispeaker.fill")
            Text(activeDeviceName(paired: paired))
                .font(.miniSubtitle)
                .lineLimit(1)
                // Truncated rather than allowed to set the row's width: device names are whatever
                // someone called their laptop, and "Vedant's 16-inch MacBook Pro (Work)" should
                // shorten this label, not the scrubber beside it on the Mac or the queue button
                // beside it on the phone.
                .frame(maxWidth: 160, alignment: .leading)
        }
        // Accented while the sound is somewhere else, which is exactly when it matters that you
        // can tell at a glance — the same rule the device glyph used before it became a menu.
        .foregroundStyle(peer.isMirroring ? Theme.accent : .secondary)
        .padding(.horizontal, Theme.Space.xs)
        .frame(minWidth: Theme.Metrics.hitTarget, minHeight: Theme.Metrics.hitTarget)
        .contentShape(Rectangle())
    }

    // MARK: - Moving playback

    /// Pull: this device cannot take a session, so it asks the one that has it to push.
    ///
    /// The push is already an acked handshake that releases the sender only once this device has
    /// the queue (`PeerLink.handOffToPeer`), so routing "play here" through it means there is one
    /// path to keep correct rather than two opposite ones.
    private func playHere() {
        guard peer.isMirroring else { return }
        Task { await PeerPlayback.shared.requestSessionFromPeer() }
    }

    private func playOnPeer() {
        guard !peer.isMirroring else { return }
        Task { await link.handOffToPeer() }
    }
}
