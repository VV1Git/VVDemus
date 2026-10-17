import SwiftUI

/// "Playing on <device> ▾" — the one control that moves playback between the linked devices.
///
/// It replaced a handoff button that only pushed, and only from the device that happened to hold
/// the session. A picker says the true thing instead: here are the devices, this is the one making
/// the sound, choose another. Every device in the group shows the same rows and any of them can
/// move playback anywhere — including between two others — which is what makes the group feel
/// like one player rather than several apps that can talk.
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
        if pairedStore.hasPeers {
            Menu {
                deviceRow(
                    name: thisDeviceName,
                    systemImage: PeerIdentity.shared.isDesktop ? "desktopcomputer" : "iphone",
                    isActive: !peer.isMirroring,
                    isReachable: true,
                    action: { move(to: SessionOwnership.shared.localPeerId) }
                )
                ForEach(pairedStore.peers) { member in
                    deviceRow(
                        name: member.name,
                        systemImage: member.isDesktop ? "desktopcomputer" : "iphone",
                        isActive: peer.ownerPeer?.peerId == member.peerId,
                        isReachable: peer.isReachable(member.peerId),
                        action: { move(to: member.peerId) }
                    )
                }
            } label: {
                label
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
            .disabled(link.isHandingOff || !peer.anyPeerReachable)
            .help(peer.anyPeerReachable ? "Choose where the music plays" : "No other device is reachable")
            .accessibilityLabel("Playing on \(activeDeviceName)")
        }
    }

    private var thisDeviceName: String {
        // "This Computer" / "This iPhone" rather than the machine's own name: on the device you
        // are looking at, its name tells you nothing the word "this" does not.
        PeerIdentity.shared.isDesktop ? "This Computer" : "This iPhone"
    }

    private var activeDeviceName: String {
        peer.ownerPeer?.name ?? thisDeviceName
    }

    @ViewBuilder
    private func deviceRow(
        name: String,
        systemImage: String,
        isActive: Bool,
        isReachable: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // The checkmark rather than only a tint: which device is playing is the single fact
            // this menu exists to state, and colour alone does not state it to everyone.
            Label(name, systemImage: isActive ? "checkmark" : systemImage)
        }
        // A member that is asleep or elsewhere stays listed, so the group reads the same on every
        // device, but cannot be chosen — the move would only fail a few seconds later.
        .disabled(isActive || !isReachable)
    }

    private var label: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: peer.ownerPeer.map { $0.isDesktop ? "desktopcomputer" : "iphone" }
                ?? "hifispeaker.fill")
            Text(activeDeviceName)
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

    /// Sends the session to `peerId`, wherever it is now.
    ///
    /// Only the owner can push it, so anything else asks the owner to — for this device or for a
    /// third. The push is already an acked handshake that releases the sender only once the
    /// receiver has the queue (`PeerLink.handOff`), so routing every move through it means there
    /// is one path to keep correct rather than several opposite ones. See
    /// `PeerPlayback.moveSession`.
    private func move(to peerId: String) {
        Task { await PeerPlayback.shared.moveSession(to: peerId) }
    }
}
