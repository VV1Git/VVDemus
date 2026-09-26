import Foundation

/// What a Discord profile should say about what is playing, and when it is worth telling Discord.
///
/// Pulled out of `DiscordPresence` (MacApp) for the same reason as `BackgroundAudioPolicy`: every
/// interesting case — a pause, a seek, the gap between two tracks, Discord's rate limit — is a
/// timing question, and none of them should need a running Discord to reach. Compiled into both
/// targets so the suite can run it; only the Mac ever connects.
enum DiscordPresencePolicy {
    /// Off unless switched on. This publishes what you are listening to to everyone who can see
    /// your profile, which is not something an update should start doing on its own.
    static let enabledDefaultsKey = "discordPresenceEnabled"

    /// Discord's activity type for "Listening to …" — the wording Spotify's card uses. `0` would
    /// read "Playing VVDemus", as if it were a game.
    static let listeningActivityType = 2

    /// A pause shorter than this leaves the card alone. Clearing it the moment playback stops made
    /// every quick pause (and every buffering stall that reports as one) blink the whole card off
    /// and back on for everyone watching, and spent two of the five updates Discord allows in 20s.
    static let pauseGrace: TimeInterval = 10

    /// Discord accepts five activity updates per 20 seconds per connection and silently drops the
    /// rest. One every four seconds can never exceed it, and whatever was wanted in between is
    /// coalesced into the next send rather than lost.
    static let minimumSendInterval: TimeInterval = 4

    /// How far the card's start time may drift before it counts as a seek. The start is derived
    /// from the player's position each tick, so it wobbles by the length of a tick and a little
    /// jitter; resending for that would spend the whole rate budget on nothing visible.
    static let seekTolerance: TimeInterval = 2.5

    struct Inputs {
        var track: Track?
        var isPlaying: Bool
        var isLoading: Bool
        /// Seconds into the track.
        var progress: Double
        /// The player's own figure, which is `0` until the item has loaded.
        var duration: Double
        /// How long playback has been paused, or `nil` while it is not.
        var pausedFor: TimeInterval?
        var now: Date
    }

    enum Decision: Equatable {
        case show(DiscordActivity)
        case clear
        /// Leave whatever Discord has alone — the state is between two meaningful ones.
        case hold
    }

    static func decide(_ input: Inputs) -> Decision {
        // Between tracks the player briefly reports loading with the old track, then the new track
        // not yet playing. Neither is worth a card of its own; the new track is a moment away.
        if input.isLoading { return .hold }
        guard let track = input.track else { return .clear }

        if !input.isPlaying {
            guard let pausedFor = input.pausedFor, pausedFor >= pauseGrace else { return .hold }
            return .clear
        }

        let duration = input.duration > 0 ? input.duration : Double(track.durationSeconds ?? 0)
        let progress = max(0, input.progress)
        let start = input.now.addingTimeInterval(-progress)
        let end = duration > progress ? start.addingTimeInterval(duration) : nil

        return .show(DiscordActivity(
            videoId: track.videoId,
            title: track.title,
            artist: track.artist,
            album: track.album,
            artworkUrl: artworkUrl(for: track),
            start: start,
            end: end
        ))
    }

    /// Whether `desired` should be sent now, given what Discord was last told.
    ///
    /// - Parameters:
    ///   - lastSent: `nil` when nothing has been sent on this connection — Discord starts every
    ///     connection with no activity, so that is the same as having sent `.clear`.
    static func shouldSend(
        _ desired: Decision,
        lastSent: Decision?,
        lastSentAt: Date?,
        now: Date
    ) -> Bool {
        let current = lastSent ?? .clear
        switch desired {
        case .hold:
            return false
        case .clear:
            if current == .clear { return false }
        case .show(let activity):
            if case .show(let previous) = current, previous.isSameCard(as: activity) { return false }
        }
        guard let lastSentAt else { return true }
        return now.timeIntervalSince(lastSentAt) >= minimumSendInterval
    }

    /// Discord fetches an external image itself, so this must be a URL anyone on the internet can
    /// load — which YouTube's artwork is. Asked for at 512px, the size a profile card draws at
    /// most, rather than whatever size the track happened to arrive with.
    static func artworkUrl(for track: Track) -> String? {
        guard let url = track.thumbnailUrl, url.hasPrefix("https://") else { return nil }
        let sized = RemoteImage.resizedThumbnailUrl(url, targetPixels: 512)
        // An asset longer than Discord accepts rejects the whole activity, not just the image. A
        // card without artwork is far better than no card.
        return sized.count <= DiscordActivity.maxAssetLength ? sized : nil
    }
}

/// One "Listening to" card.
struct DiscordActivity: Equatable {
    static let maxTextLength = 128
    static let maxAssetLength = 256
    static let maxButtonLabelLength = 32

    var videoId: String
    var title: String
    var artist: String
    var album: String?
    var artworkUrl: String?
    var start: Date
    /// `nil` when the length is unknown, which shows elapsed time instead of a progress bar.
    var end: Date?

    /// The same card as far as anyone looking at it could tell: same song, and a start time within
    /// the seek tolerance.
    func isSameCard(as other: DiscordActivity) -> Bool {
        videoId == other.videoId
            && title == other.title
            && artist == other.artist
            && album == other.album
            && artworkUrl == other.artworkUrl
            && (end == nil) == (other.end == nil)
            && abs(start.timeIntervalSince(other.start)) <= DiscordPresencePolicy.seekTolerance
    }

    /// The `activity` object of a `SET_ACTIVITY` command.
    var json: [String: Any] {
        var timestamps: [String: Any] = ["start": Self.milliseconds(start)]
        if let end { timestamps["end"] = Self.milliseconds(end) }

        var assets: [String: Any] = [:]
        if let artworkUrl {
            assets["large_image"] = artworkUrl
            assets["large_text"] = Self.fit(album ?? title, max: Self.maxTextLength)
        }

        var activity: [String: Any] = [
            "type": DiscordPresencePolicy.listeningActivityType,
            "details": Self.fit(title, max: Self.maxTextLength),
            "state": Self.fit(artist, max: Self.maxTextLength),
            "timestamps": timestamps,
            "buttons": [[
                "label": "Play on YouTube Music",
                "url": "https://music.youtube.com/watch?v=\(videoId)",
            ]],
        ]
        if !assets.isEmpty { activity["assets"] = assets }
        return activity
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Discord rejects the whole activity for a text field outside 2…128 characters, so a one-
    /// letter title or an empty artist would otherwise take the card down with it.
    static func fit(_ text: String, max: Int) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count > max { value = String(value.prefix(max - 1)) + "…" }
        while value.count < 2 { value += value.isEmpty ? "Unknown" : " " }
        return value
    }
}

/// Discord's local RPC framing: a little-endian `UInt32` opcode, a little-endian `UInt32` length,
/// then that many bytes of JSON.
enum DiscordIPC {
    enum Opcode: UInt32 {
        case handshake = 0
        case frame = 1
        case close = 2
        case ping = 3
        case pong = 4
    }

    struct Frame: Equatable {
        var opcode: UInt32
        var payload: Data
    }

    static let headerLength = 8

    static func encode(_ opcode: Opcode, _ payload: Data) -> Data {
        encode(rawOpcode: opcode.rawValue, payload)
    }

    static func encode(rawOpcode: UInt32, _ payload: Data) -> Data {
        var data = Data(capacity: headerLength + payload.count)
        withUnsafeBytes(of: rawOpcode.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// Removes and returns the first complete frame in `buffer`, or `nil` if it does not yet hold
    /// one. A socket read ends wherever it ends, so a frame can arrive split or several together.
    static func nextFrame(from buffer: inout Data) -> Frame? {
        guard buffer.count >= headerLength else { return nil }
        let bytes = [UInt8](buffer.prefix(headerLength))
        func uint32(at offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }
        let opcode = uint32(at: 0)
        let length = Int(uint32(at: 4))
        guard buffer.count >= headerLength + length else { return nil }
        let payload = Data(buffer.dropFirst(headerLength).prefix(length))
        buffer = Data(buffer.dropFirst(headerLength + length))
        return Frame(opcode: opcode, payload: payload)
    }

    static func handshake(clientId: String) -> Data {
        encode(.handshake, json(["v": 1, "client_id": clientId]))
    }

    /// `activity: nil` clears the card.
    static func setActivity(_ activity: DiscordActivity?, pid: Int32, nonce: String = UUID().uuidString) -> Data {
        let args: [String: Any] = ["pid": pid, "activity": activity?.json ?? NSNull()]
        return encode(.frame, json(["cmd": "SET_ACTIVITY", "args": args, "nonce": nonce]))
    }

    /// The sockets the Discord desktop app listens on, in the order it takes them: `discord-ipc-0`
    /// unless another Discord build (Canary, PTB) already has it.
    static func socketPaths(environment: [String: String]) -> [String] {
        let base = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"]
            .lazy
            .compactMap { environment[$0] }
            .first { !$0.isEmpty } ?? "/tmp"
        let directory = base.hasSuffix("/") ? String(base.dropLast()) : base
        return (0..<10).map { "\(directory)/discord-ipc-\($0)" }
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
