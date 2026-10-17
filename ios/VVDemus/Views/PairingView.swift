import SwiftUI

/// Linking this device to others, and seeing the group it is part of, on a screen of its own.
///
/// Deliberately not rows in the Settings `List`. It started that way and the controls there were
/// unreliable in a way that resisted every fix: the button took neither a click nor a tap, the
/// text field's `onSubmit` never fired, and eventually even `onChange` on its own binding stopped
/// arriving — the section had simply stopped updating, while a button in the *first* row of the
/// same section still worked. Rather than keep guessing at which List-row interaction was eating
/// what, this is a plain stack, which has none of that behaviour. It is also the better home for
/// it: pairing is a focused, one-time task, not a settings toggle.
struct PairingView: View {
    @ObservedObject private var pairedStore = PairedPeerStore.shared
    @ObservedObject private var session = PairingSession.shared
    @ObservedObject private var discovery = PeerDiscovery.shared
    @ObservedObject private var link = PeerLink.shared
    @ObservedObject private var playback = PeerPlayback.shared

    @State private var enteredCode = ""
    @State private var selectedPeerId: String?
    @State private var status: String?
    @State private var isPairing = false
    /// The code the last automatic attempt used, so the sixth digit fires once rather than on
    /// every keystroke that keeps the length at six.
    @State private var lastAttemptedCode = ""
    /// The member whose removal is waiting on a confirmation.
    @State private var pendingRemoval: PairedPeer?
    @State private var confirmingLeave = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                if pairedStore.hasPeers {
                    group
                    Divider()
                    Text("Link Another Device").font(.title3.weight(.semibold))
                }
                linkNewDevice
            }
            .padding(Theme.Metrics.gutter)
            .transportClearance()
            .frame(maxWidth: 520, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.screenBackground)
        .navigationTitle(pairedStore.hasPeers ? "Linked Devices" : "Connect a Device")
        .compactNavigationTitle()
        .task {
            session.beginDisplaying()
            discovery.startBrowsing()
        }
        // Both, not just the timer. The browse was only stopped on the *successful* pairing path,
        // so backing out of this screen without pairing left `_vvdemus._tcp` being searched for
        // the rest of the process — multicast traffic and a radio that never idles, for a screen
        // nobody is looking at.
        .onDisappear {
            session.stopDisplaying()
            discovery.stopBrowsing()
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "this device") from the group?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { member in
            Button("Remove", role: .destructive) {
                Task { await link.remove(member) }
            }
        } message: { member in
            Text("Every device in the group stops syncing with \(member.name). To bring it back, pair it again with a code.")
        }
        .confirmationDialog(
            "Leave the group?",
            isPresented: $confirmingLeave,
            titleVisibility: .visible
        ) {
            Button("Leave Group", role: .destructive) {
                Task { await link.leaveGroup() }
                status = nil
                enteredCode = ""
            }
        } message: {
            Text("This device stops syncing with all of them. Your library stays on every device.")
        }
    }

    // MARK: - The group

    @ViewBuilder
    private var group: some View {
        if let name = link.justPairedWith {
            Label("Paired with \(name)", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.accent)
        }

        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            ForEach(pairedStore.peers) { member in
                memberRow(member)
            }
        }

        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Last synced \(link.lastSyncedAt.map(Self.relative) ?? "— not yet")")
                .foregroundStyle(.secondary)
            // What came over, not merely that something did.
            if let summary = link.lastSummary, link.lastSyncedAt != nil {
                Text(summary.description).foregroundStyle(.secondary).font(.footnote)
            }
        }

        if link.isSyncing {
            HStack(spacing: Theme.Space.sm) {
                ProgressView().controlSize(.small)
                Text(link.phase ?? "Exchanging libraries…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button("Sync Now") { Task { await link.syncNow() } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }

        Button("Leave Group", role: .destructive) { confirmingLeave = true }

        Text("Your likes, playlists, radios and listening history merge across every linked device whenever they're on the same WiFi. None of them needs the others to work.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func memberRow(_ member: PairedPeer) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Circle()
                .fill(playback.isReachable(member.peerId) ? Theme.accent : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Label(member.name, systemImage: member.isDesktop ? "desktopcomputer" : "iphone")
                    .font(.body.weight(.medium))
                Text(statusLine(for: member))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let error = link.memberStatus[member.peerId]?.lastError {
                    Text(error).font(.footnote).foregroundStyle(Theme.warning)
                }
            }
            Spacer(minLength: Theme.Space.md)
            Button("Remove", role: .destructive) { pendingRemoval = member }
                .buttonStyle(.borderless)
        }
    }

    private func statusLine(for member: PairedPeer) -> String {
        var parts: [String] = []
        if let synced = link.memberStatus[member.peerId]?.lastSyncedAt {
            parts.append("Synced \(Self.relative(synced))")
        } else {
            parts.append(playback.isReachable(member.peerId) ? "Connected" : "Not reached yet")
        }
        // Said, because a device that turns up here without anyone typing its code is otherwise
        // a surprise. It is the group working as intended, and this is where to find out why.
        if let introducer = member.introducedBy {
            parts.append("added through \(pairedStore.peer(id: introducer)?.name ?? "another device")")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Linking a new device

    /// Devices on the network worth offering: those not in the group yet, and members that are
    /// on the network but not answering — which, for a device Bonjour can see, usually means
    /// its key no longer matches, and pairing it again by code is the way to mend that.
    private var candidates: [DiscoveredPeer] {
        discovery.peers.filter { pairedStore.peer(id: $0.peerId) == nil || !playback.isReachable($0.peerId) }
    }

    @ViewBuilder
    private var linkNewDevice: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("This device's code").font(.caption).foregroundStyle(.secondary)
            Text(session.code)
                .font(.pairingCode)
                .textSelection(.enabled)
            Text("New code in \(session.secondsRemaining)s")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Other device").font(.caption).foregroundStyle(.secondary)
            if candidates.isEmpty {
                HStack(spacing: Theme.Space.sm) {
                    ProgressView().controlSize(.small)
                    Text(pairedStore.hasPeers ? "Looking for a new device…" : "Looking for your other device…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("Other device", selection: $selectedPeerId) {
                    ForEach(candidates) { peer in
                        Text(peer.name).tag(Optional(peer.peerId))
                    }
                }
                .labelsHidden()
                .onChange(of: candidates) { _, peers in
                    if selectedPeerId == nil || !peers.contains(where: { $0.peerId == selectedPeerId }) {
                        selectedPeerId = peers.first?.peerId
                    }
                }
                .onAppear { selectedPeerId = selectedPeerId ?? candidates.first?.peerId }
            }
        }

        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Code from the other device").font(.caption).foregroundStyle(.secondary)
            TextField("000000", text: $enteredCode)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title2, design: .monospaced))
                .frame(maxWidth: 220)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .onSubmit { Task { await pair() } }
                // Pairing starts the moment the sixth digit lands, which is how every other
                // six-digit code field behaves — so it is what people do anyway, and it does not
                // depend on the button being pressed.
                .onChange(of: enteredCode) { _, typed in
                    let digits = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard digits.count == 6 else {
                        // Editing back below six arms the next attempt, so a wrong code can be
                        // corrected and retried without leaving the screen.
                        lastAttemptedCode = ""
                        return
                    }
                    guard digits != lastAttemptedCode, !isPairing else { return }
                    lastAttemptedCode = digits
                    Task { await pair() }
                }

            Button(isPairing ? "Pairing…" : "Pair") { Task { await pair() } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(isPairing)
        }

        if isPairing {
            HStack(spacing: Theme.Space.sm) {
                ProgressView().controlSize(.small)
                Text("Contacting your other device…").font(.footnote).foregroundStyle(.secondary)
            }
        }

        if let status {
            Text(status).font(.footnote).foregroundStyle(Theme.warning)
        }

        Text(pairedStore.hasPeers
            ? "Open this screen on the new device and type the six digits it shows, or type this device's code over there. Linking with any one device links it with the whole group."
            : "Open this screen on your other device and type the six digits it shows. You only do this once — after that they find each other on their own. To add a third device later, pair it with either one.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    /// The chosen device, defaulting to the only one on the network — the usual case, and it
    /// saves making someone pick from a list of one.
    private var resolvedPeer: DiscoveredPeer? {
        if let selectedPeerId {
            return candidates.first { $0.peerId == selectedPeerId }
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    private func pair() async {
        let digits = enteredCode.trimmingCharacters(in: .whitespacesAndNewlines)
        PairLog.info("UI: pair requested — \(digits.count) digits, \(candidates.count) candidate(s) discovered, selected=\(selectedPeerId ?? "none")")
        guard digits.count == 6 else {
            status = "Enter the six digits shown on your other device."
            return
        }
        guard let peer = resolvedPeer else {
            status = candidates.isEmpty
                ? "Haven't found your other device yet. Make sure it's on the same WiFi with the app open."
                : "Pick which device to pair with."
            return
        }
        isPairing = true
        status = nil
        defer { isPairing = false }
        do {
            try await PeerClient.pair(with: peer, code: digits)
            enteredCode = ""
            link.confirmPaired(with: peer.name)
            link.groupDidChange()
            await link.syncNow()
        } catch {
            PairLog.error("UI: pairing failed — \(error.localizedDescription)")
            status = error.localizedDescription
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
