import SwiftUI

/// "Download to Phone" — queues a download on a linked phone rather than this device.
///
/// One button per phone in the group. With a single phone it keeps its old name; with two, each
/// is named, since "Phone" no longer says which.
///
/// Downloads are the one part of the library that deliberately does *not* sync: the files are
/// large and device-local, and a Mac full of offline audio does nothing for you on a train. This
/// is the missing half of that decision — choosing on the desktop, where browsing is comfortable,
/// what should end up on the phone, where offline actually matters.
struct DownloadToPhoneButton: View {
    let tracks: [Track]
    @ObservedObject private var pairedStore = PairedPeerStore.shared
    @ObservedObject private var status = DownloadToPhoneStatus.shared

    private var phones: [PairedPeer] {
        pairedStore.peers.filter { !$0.isDesktop }
    }

    var body: some View {
        if !tracks.isEmpty {
            ForEach(phones) { peer in
                button(for: peer, named: phones.count > 1)
            }
        }
    }

    @ViewBuilder
    private func button(for peer: PairedPeer, named: Bool) -> some View {
        let outcome = status.outcome(for: tracks, on: peer.peerId)
        Button {
            Task { await send(to: peer) }
        } label: {
            Label(label(for: outcome, peer: peer, named: named), systemImage: symbol(for: outcome))
        }
        .disabled(outcome == .sending)
        // Sending is a round trip to another device, and this button only ever lives inside
        // a menu — which takes its content down the moment something in it is tapped. Left
        // to dismiss, the reply always arrived after the only thing that could have shown it
        // had gone, which is how both outcomes ended up in `PairLog` and nowhere else.
        //
        // iOS only: AppKit menus have no equivalent, and the modifier is unavailable there
        // rather than merely inert. The Mac therefore still closes its menu on the click —
        // which is exactly why the outcome lives in `DownloadToPhoneStatus` rather than in
        // `@State` on this view. Reopening the menu shows what happened, for four seconds.
        #if os(iOS)
        .menuActionDismissBehavior(.disabled)
        #endif
    }

    private func title(for peer: PairedPeer, named: Bool) -> String {
        let destination = named ? peer.name : "Phone"
        return tracks.count == 1 ? "Download to \(destination)" : "Download \(tracks.count) to \(destination)"
    }

    private func label(for outcome: DownloadToPhoneStatus.Outcome, peer: PairedPeer, named: Bool) -> String {
        switch outcome {
        case .idle: title(for: peer, named: named)
        case .sending: "Sending…"
        case .sent: "Sent to \(peer.name)"
        case .failed: "Couldn't reach \(peer.name)"
        }
    }

    /// Menus draw their labels in the system's own style and ignore `foregroundStyle`, so the
    /// glyph is what has to carry the difference between the two outcomes.
    private func symbol(for outcome: DownloadToPhoneStatus.Outcome) -> String {
        switch outcome {
        case .idle, .sending: "arrow.down.circle"
        case .sent: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func send(to peer: PairedPeer) async {
        status.begin(tracks, on: peer.peerId)
        do {
            try await PeerClient.requestDownloads(tracks, on: peer)
            PairLog.info("asked \(peer.name) to download \(tracks.count) track(s)")
            status.finish(tracks, on: peer.peerId, sent: true)
        } catch {
            PairLog.error("download request to \(peer.name) failed: \(error.localizedDescription)")
            status.finish(tracks, on: peer.peerId, sent: false)
        }
    }
}

/// Where a download request's outcome lives while the button that started it is being torn down.
///
/// `DownloadToPhoneButton` exists only inside menus, so `@State` on it is gone before the reply
/// comes back — the `isSending` flag this replaces could never render, because the menu holding
/// the button had already closed by the time it was true. Holding the outcome outside the view is
/// what makes it survivable at all: the menu shows it live for as long as it stays open, and
/// still has it if it is closed and opened again.
@MainActor
final class DownloadToPhoneStatus: ObservableObject {
    static let shared = DownloadToPhoneStatus()

    enum Outcome: Equatable { case idle, sending, sent, failed }

    @Published private var latest: Outcome = .idle
    /// Which tracks `latest` belongs to, and which phone they went to. Every row's menu carries
    /// one of these buttons per phone, so an unscoped "Sent" would turn up under the next song
    /// whose menu you opened — or beside the other phone's button — claiming something that
    /// never happened for it.
    private var subject: [String] = []
    private var clearTask: Task<Void, Never>?

    private init() {}

    func outcome(for tracks: [Track], on peerId: String) -> Outcome {
        subject == Self.subject(tracks, peerId) ? latest : .idle
    }

    func begin(_ tracks: [Track], on peerId: String) {
        clearTask?.cancel()
        clearTask = nil
        subject = Self.subject(tracks, peerId)
        latest = .sending
    }

    private static func subject(_ tracks: [Track], _ peerId: String) -> [String] {
        [peerId] + tracks.map(\.videoId)
    }

    func finish(_ tracks: [Track], on peerId: String, sent: Bool) {
        clearTask?.cancel()
        subject = Self.subject(tracks, peerId)
        latest = sent ? .sent : .failed
        // Long enough to read, short enough that a menu opened much later doesn't report on a
        // request from ten minutes ago as though it had just happened.
        clearTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self.latest = .idle
            self.subject = []
        }
    }
}
