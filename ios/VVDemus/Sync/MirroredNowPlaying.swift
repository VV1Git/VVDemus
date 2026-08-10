import Combine
import Foundation

/// What the device that owns the session is playing, as the device mirroring it sees it.
///
/// The lock screen, Control Centre and the AirPods gestures are the whole of the interface a
/// phone in a pocket has, and on a mirror `PlayerService` has nothing to fill them with: its
/// player is empty by design, so `currentTrack` is nil and the Now Playing slot goes blank the
/// moment the Mac takes the session. This is what stands in for it — the same handful of fields
/// `NowPlayingSnapshot` needs, read off the owner's state instead of a local player.
struct MirroredNowPlaying: Equatable {
    var track: Track
    var isPlaying: Bool
    var elapsed: Double
    var duration: Double?
}

/// Where `PlayerService` reads the owner's playback from, on a device that is not the owner.
///
/// A seam for the same reason `SessionOwning` is one: the live implementation reaches
/// `PeerPlayback.shared`, which has a timer, a Bonjour browse and another whole app behind it,
/// and the thing worth pinning down — that this phone's Now Playing slot shows the Mac's song and
/// its buttons reach the Mac — needs none of that.
///
/// `onChange` is set by `PlayerService`, exactly as `PlaybackEngine`'s callbacks are: the Now
/// Playing slot has to be repainted when the news changes, and on a mirror nothing local changes
/// at all — the engine is detached, so the periodic time observer that drives every other
/// republish never ticks.
@MainActor
protocol MirroredNowPlayingSource: AnyObject {
    /// The owner's playback, or nil whenever this device is not mirroring one.
    var nowPlaying: MirroredNowPlaying? { get }
    /// Fired on the main actor when `nowPlaying` has changed.
    var onChange: (() -> Void)? { get set }
}

/// The unpaired case, and the one every test gets unless it asks for otherwise — see
/// `NoSessionOwner`, which exists for the same reason.
@MainActor
final class NoMirroredNowPlaying: MirroredNowPlayingSource {
    static let shared = NoMirroredNowPlaying()

    var nowPlaying: MirroredNowPlaying? { nil }

    /// Deliberately drops what it is given rather than storing it. Nothing here ever fires, and
    /// a shared singleton holding the last closure it was handed would keep one `PlayerService`
    /// per test alive for the lifetime of the process.
    var onChange: (() -> Void)? {
        get { nil }
        set {}
    }
}

/// The live source: the paired device's session, as `PeerPlayback` last saw it.
///
/// Reads the same `displayed…` accessors the transport bar reads, so the lock screen and the app
/// can never disagree about which song is playing or whether it is paused — including the
/// optimistic play state `PeerPlayback` holds for the second between a press and the owner being
/// seen to obey it.
@MainActor
final class PeerMirroredNowPlaying: MirroredNowPlayingSource {
    static let shared = PeerMirroredNowPlaying()

    var onChange: (() -> Void)?

    private var cancellable: AnyCancellable?
    /// What the last `onChange` described, so the same news is not delivered three times over.
    private var lastDelivered: MirroredNowPlaying?

    /// Subscribed from `init`, which runs when `PlayerService.shared` is first built and hands
    /// this to itself — there is no separate start to forget.
    private init() {
        // `objectWillChange` rather than `$peerState`, because a snapshot is not the only thing
        // that decides what belongs on the lock screen: the peer going unreachable and ownership
        // moving are both changes to *other* published properties, and each of them ends the
        // mirrored session as surely as an empty snapshot would.
        cancellable = PeerPlayback.shared.objectWillChange.sink { [weak self] _ in
            // A hop, because this is `willChange`: every Combine notification an `@Published`
            // property raises is sent *before* the property is written, so reading the peer's
            // state from inside the sink reads the snapshot the poll has just superseded — and
            // the lock screen would sit one poll behind for as long as the mirroring lasted.
            Task { @MainActor in self?.deliverIfChanged() }
        }
    }

    var nowPlaying: MirroredNowPlaying? {
        let peer = PeerPlayback.shared
        // `isMirroring` first, and not merely `peerState`: when this device owns the session the
        // `displayed…` accessors answer with *this* device's own player, and publishing that
        // here would be `PlayerService` republishing itself through a second path.
        guard peer.isMirroring, let track = peer.displayedTrack else { return nil }
        return MirroredNowPlaying(
            track: track,
            isPlaying: peer.displayedIsPlaying,
            elapsed: peer.displayedProgress,
            // The owner's figure once it has one, the track's own metadata until then: a peer
            // that is still resolving a stream reports a duration of zero, and a scrubber with
            // no length at all is worse than one seeded from what the track says it is.
            duration: peer.displayedDuration > 0
                ? peer.displayedDuration
                : track.durationSeconds.map(Double.init)
        )
    }

    /// One delivery per poll, rather than one per published property.
    ///
    /// A single successful poll writes `isPeerReachable` and `peerState` — and sometimes
    /// `isMirroring` — and each of those is an `objectWillChange` of its own, so the same second
    /// of news arrives two or three times with identical values. Comparing against the last
    /// delivery also means a peer that is paused and unmoving stops republishing altogether
    /// instead of rewriting the Now Playing slot every second for the length of the pause.
    private func deliverIfChanged() {
        let current = nowPlaying
        guard current != lastDelivered else { return }
        lastDelivered = current
        onChange?()
    }
}
