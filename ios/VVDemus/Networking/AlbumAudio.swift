import Foundation

/// The album cut of an album page's rows, where the page handed over the music video instead.
///
/// An album page does not always list the album. For Drake's "Honestly, Nevermind" every row
/// is `MUSIC_VIDEO_TYPE_OMV` — "Falling Back" is DrakeVEVO's "Falling Back (Extended Version)",
/// with the wedding scene's room noise over it, and "Sticky" is the "Official Music Video", a
/// club crowd under the whole song. The album's own `OLAK5uy_` playlist is the same videos
/// again, so it is no way out. The page's titles and lengths are still the album's ("Falling
/// Back", 4:27), which is what makes the row look right and play wrong.
///
/// The `- Topic` audio upload exists — it is what the Songs search returns for "falling back
/// drake" — so it is found by searching and swapped in. Only rows the page itself marked as
/// videos are ever touched: an audio row is already the album, and a row on a live album is the
/// live take because that is the album the user opened, which `isSameSong`'s variant gate keeps
/// that way when the row *is* a video.
///
/// Pure: the searching is `InnerTubeClient.album`'s job, the deciding is this.
enum AlbumAudio {
    /// How far a candidate from some *other* release may be from the row's length and still be
    /// the same recording — a single, a deluxe edition. Spotify-matched catalogue lengths land
    /// within a second or two of each other; a music video's intro or a radio edit does not.
    static let otherReleaseSlackSeconds = 3

    /// `tracks` with each video row in `videoCuts` replaced by its audio counterpart, when
    /// `candidates` has one. The row keeps everything the album page said about it except the
    /// video id and the length, which become the ones that will actually play.
    static func swappingInAudio(_ tracks: [Track], videoCuts: Set<String>, candidates: [Track]) -> [Track] {
        tracks.map { track in
            guard videoCuts.contains(track.videoId),
                  let audio = counterpart(of: track, among: candidates) else { return track }
            return Track(
                videoId: audio.videoId,
                title: track.title,
                artist: track.artist,
                album: track.album,
                thumbnailUrl: track.thumbnailUrl,
                durationSeconds: audio.durationSeconds ?? track.durationSeconds
            )
        }
    }

    /// The candidate that is the same recording as `track`, or nil.
    ///
    /// The same song on the same release wins outright, the closest length first. The same song
    /// elsewhere has to be the same length too, because a title and an artist are all a music
    /// video, a radio edit and an extended mix have in common with the album cut.
    static func counterpart(of track: Track, among candidates: [Track]) -> Track? {
        var best: (track: Track, rank: (Int, Int))?
        for candidate in candidates {
            guard candidate.videoId != track.videoId,
                  !candidate.isLongFormMix,
                  InnerTubeClient.isSameSong(candidate, as: track) else { continue }
            let gap = lengthGap(track, candidate)
            let sameRelease = isSameRelease(track.album, candidate.album)
            if !sameRelease {
                guard let gap, gap <= otherReleaseSlackSeconds else { continue }
            }
            let rank = (sameRelease ? 0 : 1, gap ?? Int.max)
            // Strictly better only: ties keep the earlier candidate, search's best guess.
            if best.map({ rank < $0.rank }) ?? true {
                best = (candidate, rank)
            }
        }
        return best?.track
    }

    private static func lengthGap(_ a: Track, _ b: Track) -> Int? {
        guard let x = a.durationSeconds, let y = b.durationSeconds else { return nil }
        return abs(x - y)
    }

    private static func isSameRelease(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let core = TrackMatcher.normalisedTitle(a).core
        return !core.isEmpty && core == TrackMatcher.normalisedTitle(b).core
    }
}
