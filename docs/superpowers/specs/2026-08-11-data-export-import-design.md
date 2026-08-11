# Export and import your data

**Date:** 2026-08-11
**Status:** Approved, not yet implemented

## The problem

Everything the app knows about you — liked songs, playlists, radio history, recent searches,
thirteen months of listening events — lives in `UserDefaults` on one device. Peer sync copies it
to a second device, but that is a live relationship between two phones, not a backup. There is no
way to put your library somewhere you control, and no way to get it back onto a device that has
been wiped or replaced.

## What it does

One file holds everything that syncs, plus the app's preferences. Exporting writes it; importing
merges it back in.

## The file

`VVDemus Backup 2026-08-11.vvdem` — pretty-printed JSON, ISO-8601 dates, under a custom UTType
(`com.vvdemus.backup`, conforming to `public.json`, extension `vvdem`) declared in both targets'
`Info.plist`, so the import picker offers backups rather than every JSON file on the device.

```json
{ "format": "vvdem.backup",
  "version": 1,
  "exportedAt": "2026-08-11T22:04:11Z",
  "exportedBy": { "peerId": "…", "deviceName": "Nishant's MacBook Pro" },
  "appVersion": "…",
  "payload": { … SyncPayload … },
  "preferences": { "data_saver_enabled": false } }
```

`payload` is a whole `SyncPayload`, exactly as `SyncEngine.snapshot(eventsSince: nil)` produces
it: likes, playlists with their per-entry fractional order keys and tombstones, radio history,
generated caches (daylist, Home feed, every cached station), recent searches, and the full event
log. Unfiltered and by construction — a store that joins sync later joins the backup with it,
with nothing here to keep in step.

`eventsSince` is written `nil`. It is a request from a live peer for what to send back, and means
nothing in a file.

### Why a wrapper and not a bare `SyncPayload`

The `version` field. A file written by a future build lands in an older one as a sentence the
user can act on rather than a decode failure with no explanation. Version mismatches are
**rejected outright** — no partial decode, no best-effort import.

### What is deliberately absent

- **Pairing and peer identity.** `PairedPeerStore` and `PeerIdentity` are not in `SyncPayload`
  and are not added. Two devices sharing a peer id would break `EditStamp`'s deterministic
  tiebreak, which is the thing that makes two copies of a playlist converge.
- **VVDemus Connect's on/off state.** It runs an unauthenticated HTTP server that anyone on the
  same network can drive. Opening a listener should be a thing you did on purpose, on that
  device, on that network — not a side effect of restoring a backup. It is also genuinely
  per-device: you enable it on the machine you want to drive from a browser. Neither exported
  nor imported, so `preferences` holds exactly what import will apply.
- **Downloaded audio.** The files, and the list of them: `DownloadManager` is not part of sync.

## Import semantics: merge, never replace

Import calls `SyncEngine.merge(_:)` — the same function a peer sync round calls, with the same
rules. Newest `EditStamp` wins per record, tombstones are respected, and the operation is
idempotent: importing the same file twice changes nothing the second time.

Consequences, all intended:

- Nothing on the device is destroyed by an import.
- An import **cannot roll back**. Unlike a song after exporting, and importing that backup will
  not re-like it — the local edit is newer and wins.
- There is no "replace everything" path. It would need a wipe of every synced store behind a
  confirmation, and it is the one button in this feature that could lose a library.

`merge` also advances `SyncCursor` for the file's `peerId`. That stays correct here: the cursor
records "I hold everything from peer X up to T", and merging X's export up to T is precisely what
makes that true. The cursor never moves backwards, so a stale file cannot widen a later real
sync's window. The peer id is read for the cursor and never adopted as this device's own.

## Components

### `ios/VVDemus/Sync/BackupFile.swift`

- `BackupFile: Codable` — the wrapper above.
- `BackupCodec` — `encode(_:) -> Data` and `decode(_:) throws -> BackupFile`, throwing
  `BackupError.notABackup`, `.unsupportedVersion(Int)`, `.corrupt`.

Pure: no stores, no filesystem, no singletons. This is the unit the tests exercise, in keeping
with the rest of the sync layer, whose decision types were each pulled out of their owner for the
same reason.

### `ios/VVDemus/Views/Components/DataTransferSection.swift`

The Settings section and both flows, kept out of `SettingsView` so that file stays a list of
sections.

- **Export** builds `SyncEngine.snapshot(eventsSince: nil)` on the main actor, reads
  `data_saver_enabled`, encodes, and hands a `FileDocument` to `.fileExporter` — one code path
  that is a share sheet on iOS and a save panel on Mac.
- **Import** uses `.fileImporter(allowedContentTypes: [.vvdemBackup])`, reads the
  security-scoped URL, decodes, merges, applies preferences, and reports the result with the
  existing `SyncSummary.description` — so it says "3 liked songs, 1 playlist, 42 plays", or
  "Already up to date", in the words a peer sync already uses. Decode errors become an alert.

### Changes elsewhere

- `SettingsView` renders `DataTransferSection()` beneath Paired Device.
- Both `Info.plist` files declare the exported UTType; a `UTType.vvdemBackup` extension names it.

The section carries a footer:

> Export writes your playlists, liked songs, listening history, radios and preferences to a
> single file. Importing merges that file into this device: nothing is replaced, and importing
> the same file twice changes nothing the second time. VVDemus Connect isn't included — it stays
> set per device.

The last sentence is not padding. Without it, Connect not coming back reads as a bug.

## Testing

In `VVDemusTests`, against `BackupCodec` directly:

- **Round trip.** A hand-built payload encodes and decodes to an equal value. A playlist's order
  keys and a removed entry's tombstone survive verbatim — those are what the merge rules read,
  and a file that loses them merges wrongly rather than failing.
- **Rejections.** Arbitrary JSON gives `.notABackup`; `"version": 2` gives
  `.unsupportedVersion(2)`; truncated bytes give `.corrupt`. Each is distinct, because the
  failure this feature must never have is a silently empty library.
- **Merge equivalence.** A `PlaylistRecord` decoded from a file merges identically to one that
  arrived over the wire, via `PlaylistRecord.merging`.

## Known limits

- `ListeningStatsStore.merge` prunes events older than its thirteen-month window, so a backup
  older than that will not restore listening history beyond it.
- Merge cannot roll back, as above.
- Downloaded audio is not in the file.
