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
    /// Volume for the device currently producing sound, 0...1. Each device keeps its own
    /// level (see `PlayerService.volume`), so this changes when `activeDevice` does — and a
    /// casting browser applies it to its `<audio>` element, since while it is casting this
    /// is *its* level.
    let volume: Double
    // No `hasPrevious`: it was encoded into every broadcast and read by nothing. The web
    // UI's previous button is always enabled and simply POSTs `/api/previous`, which the
    // phone no-ops when there is no back stack.
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
    /// What plays next, with its stream URL already resolved, so a casting browser can
    /// carry on by itself if the phone is unreachable when the current track ends.
    let nextTrack: Track?
    let nextStreamUrl: String?
    /// Identifies this run of the app. `playbackEpoch` restarts at 0 every launch, so a
    /// browser holding a high epoch would reject every snapshot from a relaunched phone
    /// forever — a page that looks healthy (socket connected, HTTP 200) and is completely
    /// frozen. The browser compares this and resets its counters when it changes.
    let serverInstanceId: String
    /// Changes whenever the library's shape does — radio stations, playlists, downloads.
    /// The web remote reloads its sidebar when this moves, so a radio you just started
    /// appears under Radio straight away instead of only after a page reload.
    let librarySignature: Int

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

    /// Note that `nextTrack`/`nextStreamUrl` are kept even in a trimmed broadcast: they
    /// are small, and they're the browser's only lifeline if the phone drops off between
    /// this broadcast and the end of the current track.
    func withoutQueues() -> StateSnapshot {
        StateSnapshot(
            isPlaying: isPlaying,
            isLoading: isLoading,
            progress: progress,
            duration: duration,
            isShuffling: isShuffling,
            volume: volume,
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
            trackLoadEpoch: trackLoadEpoch,
            nextTrack: nextTrack,
            nextStreamUrl: nextStreamUrl,
            serverInstanceId: serverInstanceId,
            librarySignature: librarySignature
        )
    }
}

/// The browser telling the phone what it is *actually* playing, after having moved on by
/// itself while the phone was unreachable.
struct AdoptPlaybackBody: Decodable {
    let videoId: String
    let progress: Double
    /// Identifies the tab, so a browser that kept playing through an outage can be handed
    /// casting back rather than silenced. See `LocalControlServer.mayReclaimCasting`.
    let clientId: String?
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
    /// Which tab is reporting. Only the tab that owns casting may refresh the liveness
    /// clock — otherwise a stale tab kept the phone believing a browser was playing when
    /// none was, and the fallback to the phone could never fire. Optional so an older
    /// client still works (it simply can't be attributed, and is treated as the owner).
    let clientId: String?
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
    /// The track a radio was built from, when the browser is playing out of a radio — so
    /// the station gets filed under Your Radio exactly as it would from the phone.
    let contextSeed: Track?
}

struct SeekRequestBody: Decodable {
    let seconds: Double
}

/// Sets the level for whichever device is currently producing sound — the web slider is a
/// remote for the active device, exactly as the transport buttons are. Clamped on arrival
/// by `PlayerService.setVolume`, so a hand-written request can't mute playback with a value
/// no slider could produce.
struct VolumeRequestBody: Decodable {
    let volume: Double
}

struct TrackOnlyBody: Decodable {
    let track: Track
}

struct VideoIdBody: Decodable {
    let videoId: String
}

/// The casting browser reporting that its `<audio>` element could not load the URL the
/// phone gave it — see `POST /api/playback/stream-failed`. (There is no `RadioPlayBody`
/// here any more: it existed only for `POST /api/radio/play`, which nothing ever called.)
struct StreamFailedBody: Decodable {
    /// The track the failed URL belonged to. Checked against what the phone thinks is
    /// playing, so a report about a track already skipped past is ignored rather than
    /// costing a pointless re-resolve.
    let videoId: String
    /// Optional for the same reason it is on `PlaybackReportBody` — anything that isn't the
    /// bundled web UI sends none — but a request that does carry one must come from the tab
    /// that owns casting.
    let clientId: String?
}

/// Answers `/api/playback/stream-failed` with the replacement URL directly, so the browser
/// can reload immediately instead of waiting up to a second for the next state broadcast to
/// carry it.
struct StreamFailedResponse: Encodable {
    let videoId: String
    let streamUrl: String
}

/// Answers `/api/stream` with a URL for a track that hasn't started yet, so the casting
/// browser can bank it against the phone being unreachable when it needs it.
///
/// The snapshot already carries one such URL (`nextStreamUrl`), which buys exactly one
/// track transition — enough to survive a blip, not enough to survive a phone that sleeps
/// mid-album. This route lets the browser fill a small window of them.
struct ResolvedStreamResponse: Encodable {
    let videoId: String
    let streamUrl: String
}

struct CreatePlaylistBody: Decodable {
    let name: String
}

struct AddToPlaylistBody: Decodable {
    let track: Track
}
