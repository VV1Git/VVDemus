import Foundation

/// Which device is actually producing sound right now. The phone remains the single
/// source of truth for queue/radio/stats logic either way — this only decides whether
/// the phone's own AVPlayer is the audio output, or a connected browser is (with the
/// phone silently tracking playback via periodic reports from that browser).
enum PlaybackDevice: String, Codable {
    case iphone
    case computer
}

/// JSON snapshot of PlayerService's state, sent to the web UI both as a plain GET
/// response and periodically over the WebSocket for live sync.
struct StateSnapshot: Codable {
    let isPlaying: Bool
    let isLoading: Bool
    let progress: Double
    let duration: Double
    let isShuffling: Bool
    let hasPrevious: Bool
    let queueContextTitle: String?
    let currentTrack: Track?
    /// Omitted from a periodic broadcast when unchanged since the previous one — the queue
    /// and liked list are by far the heaviest part of a snapshot (a full mix is ~100 track
    /// objects) and they barely ever change, yet they were re-encoded and re-sent every
    /// second. A `/api/state` response always includes them; over the socket, absent means
    /// "unchanged, keep what you have". See `StateSnapshot.withoutQueues`.
    let manualQueue: [Track]?
    let contextQueue: [Track]?
    let likedVideoIds: [String]?
    let activeDevice: PlaybackDevice
    /// Only populated when `activeDevice == .computer` — either a directly-fetchable
    /// googlevideo.com URL, or this server's own `/api/audio/local/:videoId` route for a
    /// downloaded track (which the browser can't reach on the phone's disk otherwise).
    let streamUrl: String?
    /// The track `streamUrl` was resolved for. Resolving is async, so a snapshot taken
    /// just after a track change can carry a `currentTrack` that hasn't got its URL yet —
    /// the browser compares this against `currentTrack` and waits rather than loading
    /// whatever URL happens to be present.
    let streamVideoId: String?
    /// Which browser tab currently owns "This Computer" playback (the `clientId` it sent
    /// with `/api/device`), or nil when the phone is the active device. Exactly one tab
    /// may produce sound; every other tab compares this against its own id and stays
    /// silent. Also what lets a reloaded tab reclaim casting instead of leaving playback
    /// stranded on a device with nothing listening.
    let castClientId: String?
    /// Counter identifying the phone's most recent playback instruction — the browser
    /// echoes it back with its progress reports so stale ones can be discarded. See
    /// `PlayerService.playbackEpoch`.
    let playbackEpoch: Int
    /// Increments each time a track is started from the top — including a restart of the
    /// track already playing, which the videoId alone can't distinguish. See
    /// `PlayerService.trackLoadEpoch`.
    let trackLoadEpoch: Int

    /// Identifies the contents of the heavy fields, so an unchanged one can be left out of
    /// the next broadcast.
    var queueFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(manualQueue?.map(\.videoId))
        hasher.combine(contextQueue?.map(\.videoId))
        hasher.combine(likedVideoIds)
        hasher.combine(queueContextTitle)
        return hasher.finalize()
    }

    func withoutQueues() -> StateSnapshot {
        StateSnapshot(
            isPlaying: isPlaying,
            isLoading: isLoading,
            progress: progress,
            duration: duration,
            isShuffling: isShuffling,
            hasPrevious: hasPrevious,
            queueContextTitle: queueContextTitle,
            currentTrack: currentTrack,
            manualQueue: nil,
            contextQueue: nil,
            likedVideoIds: nil,
            activeDevice: activeDevice,
            streamUrl: streamUrl,
            streamVideoId: streamVideoId,
            castClientId: castClientId,
            playbackEpoch: playbackEpoch,
            trackLoadEpoch: trackLoadEpoch
        )
    }
}

/// A command relayed from the phone to whichever browser is the active playback device,
/// so the phone's transport buttons/lock-screen controls still work while casting.
struct PlaybackCommandMessage: Codable {
    let type = "command"
    let action: String
    let seconds: Double?
}

struct DeviceRequestBody: Decodable {
    let device: PlaybackDevice
    /// Identifies the browser tab making the request, so the server can tell which tab
    /// owns cast playback. Optional so a request from anything but the bundled web UI
    /// still works (it just won't own casting).
    let clientId: String?
}

/// Periodic progress report POSTed by the browser while it's the active playback device,
/// so the phone's lock-screen info and listening stats stay accurate without the phone
/// itself decoding any audio.
struct PlaybackReportBody: Decodable {
    let progress: Double
    let duration: Double
    let isPlaying: Bool
    /// The track the browser is actually playing. Reports are sent about once a second,
    /// so when the track changes there are always some still describing the outgoing one;
    /// without this the phone would take the old track's position as the new track's.
    let videoId: String?
    /// The `playbackEpoch` this report was produced under — anything older than the phone's
    /// current epoch describes playback from before the phone's latest instruction.
    let epoch: Int?
}

struct DaylistSnapshot: Codable {
    let title: String
    let tracks: [Track]
}

/// A WebSocket push telling connected browsers that a radio's track list changed — sent
/// whenever RadioCacheStore is updated, from either the phone or the web UI itself, so
/// both stay in sync instead of drifting apart.
struct RadioUpdateMessage: Codable {
    let type = "radio"
    let videoId: String
    let tracks: [Track]
}

/// Wraps the periodic now-playing broadcast so the web UI can tell it apart from a
/// `RadioUpdateMessage` on the same socket.
struct StateMessage: Codable {
    let type = "state"
    let state: StateSnapshot
}

// MARK: - Request bodies

struct PlayRequestBody: Decodable {
    let track: Track
    let context: [Track]?
    let contextTitle: String?
}

struct SeekRequestBody: Decodable {
    let seconds: Double
}

struct TrackOnlyBody: Decodable {
    let track: Track
}

struct VideoIdBody: Decodable {
    let videoId: String
}

struct RadioPlayBody: Decodable {
    let seedTrack: Track
    let shuffled: Bool?
}

struct CreatePlaylistBody: Decodable {
    let name: String
}

struct AddToPlaylistBody: Decodable {
    let track: Track
}
