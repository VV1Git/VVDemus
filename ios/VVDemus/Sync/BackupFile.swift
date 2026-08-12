import Foundation

/// One exported library, as it sits on disk.
///
/// A wrapper around `SyncPayload` rather than the bare payload, and the whole reason is
/// `version`: a file written by a future build has to land in an older one as a sentence the
/// user can act on, not as a decode failure with nothing to say. The envelope fields are
/// deliberately the cheap ones to read — `format` and `version` are decoded on their own, before
/// anything touches the payload, so "this is a JSON file but not one of ours" and "this is ours
/// and it is damaged" stay different answers.
struct BackupFile: Codable {
    /// Written into every file and required on the way back in, so a `.vvdem` extension is not
    /// the only thing standing between a stray JSON document and a merge.
    static let formatIdentifier = "vvdem.backup"

    /// The only version this build reads or writes. Bumping it is a promise to reject every
    /// older file outright, so it moves only when the payload's shape genuinely breaks.
    static let currentVersion = 1

    /// Which device wrote the file. Recorded so a user with two backups can tell them apart —
    /// never adopted on import. Two devices sharing a peer id would break `EditStamp`'s
    /// deterministic tiebreak, which is the thing that makes two copies of a playlist converge.
    struct Exporter: Codable, Equatable {
        var peerId: String
        var deviceName: String
    }

    /// The app preferences that travel with a library.
    ///
    /// Exactly one, and the omission is the interesting part: **VVDemus Connect's on/off state
    /// is deliberately not here.** Connect runs an unauthenticated HTTP server that anyone on
    /// the same network can drive, so opening that listener has to be something you did on
    /// purpose, on that device, on that network — not a side effect of restoring a backup. It is
    /// also genuinely per-device: you turn it on for the machine you want to drive from a
    /// browser. Keeping it out of the file means `preferences` holds exactly what an import will
    /// apply, with nothing silently dropped on the way in.
    ///
    /// A typed struct rather than a `[String: Bool]` for the same reason: a dictionary would let
    /// a future key ride along and be applied — or ignored — without anyone deciding.
    struct Preferences: Codable, Equatable {
        var dataSaverEnabled: Bool

        /// The wire name is the `UserDefaults` key itself
        /// (`InnerTubeClient.dataSaverDefaultsKey`), so the file reads as the setting it
        /// restores. It cannot reference the constant — a `CodingKey` raw value must be a
        /// literal — so the two are kept in step by hand and by test.
        enum CodingKeys: String, CodingKey {
            case dataSaverEnabled = "data_saver_enabled"
        }
    }

    var format: String
    var version: Int
    var exportedAt: Date
    var exportedBy: Exporter
    var appVersion: String
    /// A whole `SyncPayload`, exactly as `SyncEngine.snapshot(eventsSince: nil)` produces it —
    /// unfiltered by construction, so a store that joins sync later joins the backup with it and
    /// there is nothing here to keep in step.
    var payload: SyncPayload
    var preferences: Preferences

    /// Stamps `format` and `version` itself rather than taking them, so no call site can write a
    /// file claiming to be something this build did not produce.
    init(exportedAt: Date, exportedBy: Exporter, appVersion: String, payload: SyncPayload, preferences: Preferences) {
        self.format = Self.formatIdentifier
        self.version = Self.currentVersion
        self.exportedAt = exportedAt
        self.exportedBy = exportedBy
        self.appVersion = appVersion
        // `eventsSince` is a live peer asking what to send back; in a file it means nothing, and
        // a non-nil value read by some later importer would silently narrow what it accepted.
        // `snapshot` fills it in unconditionally, so it is cleared here rather than at the call
        // site, where forgetting it would go unnoticed.
        var payload = payload
        payload.eventsSince = nil
        self.payload = payload
        self.preferences = preferences
    }
}

// MARK: - Failures

/// Why a file could not be imported, in the three shapes the user can actually distinguish.
///
/// Kept separate rather than collapsed into one "couldn't read that" because the failure this
/// feature must never have is a silently empty library: "that isn't a backup", "that backup is
/// from a newer build" and "that file is damaged" each lead somewhere different, and only the
/// middle one is the user's own doing.
enum BackupError: Error, Equatable, LocalizedError {
    /// Valid JSON, but nothing this app wrote — no `format`/`version` envelope.
    case notABackup
    /// Ours, but a version this build refuses. Rejected outright: a best-effort decode of a
    /// shape we do not know would merge a half-understood library into a real one.
    case unsupportedVersion(Int)
    /// Ours or not, the bytes do not parse, or the payload under a good envelope does not.
    case corrupt

    /// Shown to the user verbatim, so these are sentences rather than diagnostics.
    var errorDescription: String? {
        switch self {
        case .notABackup:
            return "That file isn't a VVDemus backup."
        case .unsupportedVersion(let version):
            // Only the forward case can happen today — version 1 is the first — but a file
            // claiming version 0 must not be described as newer, which is the one thing the
            // user could act on and would then be wrong about.
            return version > BackupFile.currentVersion
                ? "This backup was made by a newer version of VVDemus."
                : "This backup was made by a version of VVDemus this app can no longer read."
        case .corrupt:
            return "This backup file is damaged and couldn't be read."
        }
    }
}

// MARK: - The codec

/// Reads and writes `BackupFile`.
///
/// Pure — no stores, no singletons, no `UserDefaults`, no filesystem — for the same reason the
/// rest of this directory is factored that way: the whole promise of the feature is that a
/// library survives a round trip, and that has to be provable in `VVDemusTests` without a second
/// device or a file picker. Everything that needs the main actor (building the snapshot, reading
/// the preference, writing the file) stays outside.
enum BackupCodec {
    /// Pretty-printed and key-sorted because a backup is a file the user keeps: it should be
    /// readable in a text editor, and diffable against a later export. ISO-8601 for the reason
    /// the peer wire already uses it (`PeerClient.encoder`) — the default strategy writes a
    /// `Date` as seconds since 2001, and every merge rule in this directory turns on comparing
    /// dates, so an unreadable timestamp is an unreadable file.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The exact counterpart of `encoder`. `dataDecodingStrategy` is left at its `.base64`
    /// default on both sides deliberately: `GeneratedRecord.payload` is opaque JSON encoded by a
    /// default-configured coder inside the stores, and it has to come back byte for byte or
    /// `applySynced` cannot read it.
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Just the envelope. Decoded first and on its own so that a JSON file which is not a backup
    /// is reported as such, instead of surfacing as whatever the payload happened to trip over.
    private struct Envelope: Decodable {
        var format: String
        var version: Int
    }

    static func encode(_ file: BackupFile) throws -> Data {
        try encoder.encode(file)
    }

    static func decode(_ data: Data) throws -> BackupFile {
        // Parseability first, because it is the one question whose answer is not "not a backup".
        // Truncated bytes are damage; a well-formed document with the wrong keys is someone
        // picking the wrong file, and telling those two apart is the entire point of having
        // three error cases.
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw BackupError.corrupt }

        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.format == BackupFile.formatIdentifier else {
            throw BackupError.notABackup
        }
        guard envelope.version == BackupFile.currentVersion else {
            throw BackupError.unsupportedVersion(envelope.version)
        }

        // Past the envelope the file has said it is ours and it is this version, so anything
        // still wrong with it is damage rather than a mistaken pick.
        do {
            return try decoder.decode(BackupFile.self, from: data)
        } catch {
            throw BackupError.corrupt
        }
    }
}
