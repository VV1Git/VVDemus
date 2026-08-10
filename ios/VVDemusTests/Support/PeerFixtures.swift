import Foundation
@testable import VVDemus

/// Building blocks for the peer-link tests.
///
/// `StateSnapshot` has twenty-two fields and every peer test needs one; hand-rolling it per test
/// buries the two or three values a test is actually about under twenty that are noise. Kept here
/// rather than duplicated per file so adding a field to the wire breaks one place, not seven.
enum PeerFixtures {
    static let localPeer = "peer-local"
    static let remotePeer = "peer-remote"

    static func track(_ id: String, duration: Int? = 200) -> Track {
        Track(
            videoId: id,
            title: "Track \(id)",
            artist: "Artist",
            album: nil,
            thumbnailUrl: nil,
            durationSeconds: duration
        )
    }

    /// A snapshot as the *peer* would send it. Defaults describe the ordinary case — the remote
    /// device owning the session and playing something — so a test names only what it is varying.
    static func snapshot(
        currentTrack: Track? = track("a"),
        isPlaying: Bool = true,
        progress: Double = 12,
        duration: Double = 200,
        isLoading: Bool = false,
        isShuffling: Bool = false,
        volume: Double = 1,
        queueContextTitle: String? = "Some Radio",
        manualQueue: [Track] = [],
        contextQueue: [Track] = [],
        playbackEpoch: Int = 1,
        trackLoadEpoch: Int = 1,
        serverInstanceId: String = "instance-1",
        sessionOwnerId: String? = remotePeer,
        sessionClaim: Int? = 1,
        contextSeed: Track? = nil
    ) -> StateSnapshot {
        StateSnapshot(
            isPlaying: isPlaying,
            isLoading: isLoading,
            progress: progress,
            duration: duration,
            isShuffling: isShuffling,
            volume: volume,
            queueContextTitle: queueContextTitle,
            currentTrack: currentTrack,
            manualQueue: manualQueue,
            contextQueue: contextQueue,
            likedVideoIds: [],
            activeDevice: .iphone,
            streamUrl: nil,
            streamVideoId: nil,
            castClientId: nil,
            playbackEpoch: playbackEpoch,
            trackLoadEpoch: trackLoadEpoch,
            nextTrack: nil,
            nextStreamUrl: nil,
            serverInstanceId: serverInstanceId,
            librarySignature: 0,
            sessionOwnerId: sessionOwnerId,
            sessionClaim: sessionClaim,
            contextSeed: contextSeed
        )
    }

    /// Ownership backed by a throwaway defaults suite, so a test never reads or writes the real
    /// app's — see the note on `SessionOwnership.init(defaults:localPeerId:)`.
    @MainActor
    static func ownership(
        localPeerId: String = localPeer,
        suite: String = UUID().uuidString
    ) -> SessionOwnership {
        SessionOwnership(
            defaults: UserDefaults(suiteName: suite) ?? .standard,
            localPeerId: localPeerId
        )
    }
}

/// Records what `PlayerService` tried to send to the paired device, and answers whether it went.
///
/// Standing in for `PeerPlayback` rather than driving a real one: the question these tests ask is
/// "did this method route to the peer instead of acting locally", which needs no network, no
/// polling and no second app.
@MainActor
final class SpySessionOwner: SessionOwning {
    /// Flip to make every intent relay, as it would while mirroring.
    var isMirroring = false
    private(set) var relayed: [PlayerService.PlaybackIntent] = []
    private(set) var claims = 0

    func relay(_ intent: PlayerService.PlaybackIntent) -> Bool {
        guard isMirroring else { return false }
        relayed.append(intent)
        return true
    }

    func claimSession() { claims += 1 }
}
