# A lyrics screen

**Date:** 2026-08-22
**Status:** Drafted, awaiting review

## The problem

The app knows the words to nothing. Every other thing you would want while a song is playing is
here — the queue, the radio it came from, the album it is on — and the one thing people actually
look at during a song is missing.

The interesting part is not fetching text. It is that lyrics have a failure mode the rest of this
app does not: they can be *confidently wrong*. A cover, a live cut, a remix and the studio version
share a title and an artist and differ only in length, so a naive lookup will happily scroll
someone else's timing over your song. Silence is a better answer than that, and plain text is a
better answer than silence.

## What it does

A screen that shows the current track's lyrics, highlighting and scrolling the current line when
timed lyrics exist and the match is trustworthy, and falling back to plain text when either of
those is untrue. Reachable from Now Playing and from any track row. On the Mac it is a panel
beside the content, so lyrics can follow the song while you keep browsing.

## Sources

Two, in order.

**LRCLIB** (`lrclib.net`, no key, no account) is asked first, by artist, title, album and duration.
One response carries both `syncedLyrics` (LRC) and `plainLyrics`, so a match good enough for words
but not for timing costs no extra request. `/api/search` is the fallback when the exact lookup
misses.

**YouTube Music** is second, over machinery already here: `/next` for the videoId, the lyrics tab's
browseId, then `/browse`. Untimed by definition, so it always renders plain.

This is the first host in the app other than YouTube. LRCLIB learns artist, title and duration for
tracks you look up. It is named here so the choice is on the record rather than discovered later in
a proxy log.

Both paths run through `NetworkByteCounter`, so lyrics are visible to the data-usage benchmarks
instead of being traffic nothing measures. LRCLIB gets a politeness budget of its own rather than
sharing YouTube's `RateLimit`: different host, different limits, and spending playback's budget on
lyrics would trade the thing that matters for the thing that does not.

## The decisions, pulled out

Three pure functions, for the reason `CLAUDE.md` gives: each is reachable from `VVDemusTests`
without a network, a second device, or a real song.

### `LyricsMatch.score(track:candidate:)`

Returns `.accept`, `.acceptUntimedOnly`, or `.reject`.

Duration is the strong signal — a live version runs long, and that is the case that actually bites.
Normalized title and artist agreement breaks ties, reusing the normalization in `TrackMatcher`,
which already strips `official`, `lyrics`, `feat` and the rest. A second copy of that list would
drift from the first.

The starting thresholds, to be tuned against real tracks rather than treated as settled:

| Duration difference | Normalized title and artist | Verdict |
|---|---|---|
| within 2s | agree | `.accept` |
| within 2s | disagree | `.reject` |
| 2s to 15s | agree | `.acceptUntimedOnly` |
| over 15s | either | `.reject` |
| track has no `durationSeconds` | agree | `.acceptUntimedOnly` |

Two seconds is what LRCLIB itself treats as the same recording. Beyond fifteen it is a different
cut, and its words are as likely wrong as its timing.

`.acceptUntimedOnly` is the verdict that earns this type its place: the words are probably right
and the timing is not to be trusted, so the screen shows plain text and says so. Without a third
verdict this collapses into either discarding good words or scrolling bad timing.

### `LyricsCursor.activeIndex(in:at:)`

Sorted lines and a playback time in, active index or `nil` out. Binary search, no state.

The cases are the whole point: time before the first line, time past the last, duplicate
timestamps, a seek jumping backwards, and negative time, which `NowPlayingView`'s scrubber produces
mid-drag.

### The LRC parser

Text in, `[LyricsLine]` out. The format is messier than it looks — several timestamps on one line
for a repeated chorus, `[ar:]` and `[ti:]` metadata that is not lyrics, blank lines that are real
instrumental gaps and must survive, and an `[offset:]` tag that shifts every timestamp and is
silently wrong when ignored.

## Model

```swift
struct LyricsLine: Codable, Equatable { let at: TimeInterval; let text: String }

enum LyricsBody: Codable, Equatable {
    case synced([LyricsLine])     // sorted and de-duplicated at construction
    case plain([String])
}

struct Lyrics: Codable, Equatable {
    let body: LyricsBody
    let attribution: String?      // shown, not hidden
    let matchedDuration: Int?     // what it matched against, for diagnosing a bad match later
}
```

## Cache

`LyricsCacheStore`, in the shape the other stores use: an `ObservableObject` singleton, a versioned
`Codable` snapshot, `trimToLimit()`, keyed by `videoId`.

Misses are cached too, with a timestamp, or every open of a track with no lyrics pays two requests
forever. They expire sooner than hits: LRCLIB is community-contributed, and a track with nothing
today may have lyrics next month. A permanent "no lyrics" is a bug that never heals.

### Downloads

A downloaded track gets its lyrics fetched too, so the words are there on a plane. A few KB against
an audio file.

The rule that governs it: **a lyrics failure never fails, delays, or alters the audio download.**
It runs after the audio completes rather than as a step inside it, contributes nothing to
`progress.total`, and turns any error into a cached miss instead of propagating. A song you cannot
hear because a lyrics host was down would be an absurd way to lose a download.

Deleting a download does not evict its lyrics. They are small, and keeping them makes
re-downloading instant.

## The screens

`LyricsView` is shared by both targets. Four states: loading, synced, plain, and nothing found. An
`.acceptUntimedOnly` result renders as plain with a quiet note that the timing was not trusted.
Attribution is always visible.

It carries its own `TransportClearance`. Not `safeAreaInset`, not `contentMargins` — both are
recorded here as silently dropped before they reach a screen.

**Auto-scroll yields to the reader.** Any manual scroll suspends following and reveals a "Jump to
current" control; tapping it or changing track resumes. Following never resumes on its own under
your thumb, because a view that yanks itself back mid-read is worse than one that never scrolled.
Tapping a line seeks to it, which is most of the reason timed lyrics are worth having.

**Routing** is a new case on `LibraryDestination`, not a new destination type. `MacRootView` records
why: a `NavigationLink` carrying a type no inner stack registers is taken by the split view's own
detail stack, which replaces the detail closure entire, transport bar included. A new case costs
one line in the switch that `LibraryDestination` already calls the one place a destination becomes
a screen.

From a track row it is a push, sibling to "Go to Radio", reached the same way through an
environment action resolved on the stack rather than on the screen — the distinction `2da8946`
exists to fix. From `NowPlayingView` it cannot be a push, because that screen is a sheet with no
stack beneath it; there it presents as a cover over the sheet. Same view, two presentations.

For a track that is not playing there is no cursor: static text, no auto-scroll, no seek on tap.

**`MacLyricsPanel`** mirrors `MacQueuePanel` — beside the content, toggled from the transport bar,
with a `TransportClearanceRow` at its foot. The queue and lyrics are mutually exclusive: opening one
closes the other. Two panels either side of a sidebar leave the content column too narrow to browse,
which was the argument for a panel over a sheet in the first place.

## Testing

Everything sharp is pure, so it is `VVDemusTests` with no simulator and no network.

- `LyricsCursor`: empty, one line, exact boundary, before first, past last, duplicate timestamps,
  backward seek, negative time.
- `LyricsMatch`: duration inside and outside tolerance, a live cut running long, a missing
  `durationSeconds`, a cover by another artist, and that normalization comes from `TrackMatcher`.
- LRC parser: multiple timestamps per line, `[offset:]` applied, metadata excluded, blank lines
  preserved, malformed timestamps, CRLF, BOM.
- `LyricsCacheStore`: round-trip, a version bump that does not crash, trim, and a miss expiring
  sooner than a hit.
- `DownloadManager`: a lyrics failure leaves the download successful and `progress.total` untouched.
  This is the regression test that matters most.

`GET /api/lyrics` on `LocalControlServer` reports source, verdict and active line, so the cursor can
be checked against a real playing track from the command line instead of by watching a screen.

## What is deliberately absent

- **Sync and backup.** `RadioCacheStore` has `syncRecords()` and `applySynced(_:)`; the lyrics cache
  will not. It is regenerable from two public endpoints, and carrying it would grow both the peer
  sync and the `.vvdem` backup to move data neither device is better off holding. Absent on purpose,
  not by oversight.
- **Translation and romanization.**
- **Word-level karaoke highlighting.** Lines only.
- **A manual timing offset control.** If timing is wrong often enough to want one, the fix belongs
  in `LyricsMatch`, not in a slider each person has to discover.
- **Shareable lyric cards.**
