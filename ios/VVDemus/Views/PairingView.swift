import SwiftUI

/// Connecting this device to the other one, on a screen of its own.
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

    @State private var enteredCode = ""
    @State private var selectedPeerId: String?
    @State private var status: String?
    @State private var isPairing = false
    /// The code the last automatic attempt used, so the sixth digit fires once rather than on
    /// every keystroke that keeps the length at six.
    @State private var lastAttemptedCode = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                if let peer = pairedStore.peer {
                    paired(peer)
                } else {
                    unpaired
                }
            }
            .padding(Theme.Metrics.gutter)
            .transportClearance()
            .frame(maxWidth: 520, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.screenBackground)
        .navigationTitle("Connect a Device")
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
    }

    // MARK: - Paired

    @ViewBuilder
    private func paired(_ peer: PairedPeer) -> some View {
        if link.justPairedWith != nil {
            Label("Paired with \(peer.name)", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.accent)
        }

        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(peer.isDesktop ? "Your computer" : "Your phone")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(peer.name).font(.title3.weight(.medium))
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

        if let error = link.lastError {
            Text(error).font(.footnote).foregroundStyle(Theme.warning)
        }

        Button("Unpair", role: .destructive) {
            pairedStore.unpair()
            status = nil
            enteredCode = ""
        }

        Text("Your likes, playlists, radios and listening history merge across both devices whenever they're on the same WiFi. Neither one needs the other to work.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: - Not yet paired

    @ViewBuilder
    private var unpaired: some View {
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
            if discovery.peers.isEmpty {
                HStack(spacing: Theme.Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Looking for your other device…").foregroundStyle(.secondary)
                }
            } else {
                Picker("Other device", selection: $selectedPeerId) {
                    ForEach(discovery.peers) { peer in
                        Text(peer.name).tag(Optional(peer.peerId))
                    }
                }
                .labelsHidden()
                .onChange(of: discovery.peers) { _, peers in
                    if selectedPeerId == nil || !peers.contains(where: { $0.peerId == selectedPeerId }) {
                        selectedPeerId = peers.first?.peerId
                    }
                }
                .onAppear { selectedPeerId = selectedPeerId ?? discovery.peers.first?.peerId }
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

        Text("Open this screen on your other device and type the six digits it shows. You only do this once — after that they find each other on their own.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    /// The chosen device, defaulting to the only one on the network — the usual case, and it
    /// saves making someone pick from a list of one.
    private var resolvedPeer: DiscoveredPeer? {
        if let selectedPeerId {
            return discovery.peers.first { $0.peerId == selectedPeerId }
        }
        return discovery.peers.count == 1 ? discovery.peers.first : nil
    }

    private func pair() async {
        let digits = enteredCode.trimmingCharacters(in: .whitespacesAndNewlines)
        PairLog.info("UI: pair requested — \(digits.count) digits, \(discovery.peers.count) peer(s) discovered, selected=\(selectedPeerId ?? "none")")
        guard digits.count == 6 else {
            status = "Enter the six digits shown on your other device."
            return
        }
        guard let peer = resolvedPeer else {
            status = discovery.peers.isEmpty
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
            discovery.stopBrowsing()
            link.confirmPaired(with: peer.name)
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
