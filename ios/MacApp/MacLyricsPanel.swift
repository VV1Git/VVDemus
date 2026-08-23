import SwiftUI

/// The words, as a panel beside the content, for the same reason the queue is one: on a Mac
/// lyrics are something you keep open while you carry on browsing, and a sheet would make
/// reading them and using the app two separate activities.
///
/// It is the queue's twin down to the width, and that is deliberate — the two are mutually
/// exclusive (opening one closes the other, decided in the transport bar), so they occupy the
/// same strip of window one after the other. A panel that came back a different width would
/// make the content column jump every time you switched between them.
///
/// Everything below the header is `LyricsView`, unchanged from the phone's. The panel owns the
/// chrome and the answer to "which track", nothing else.
struct MacLyricsPanel: View {
    @Binding var isShown: Bool
    @ObservedObject var player: PlayerService
    @ObservedObject private var peer = PeerPlayback.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            // The transport's track, not `player.currentTrack`, and the two differ exactly when
            // the phone owns the session: the bar an inch below this panel is showing the song
            // playing over there, and a panel captioned "Lyrics" beside it showing a different
            // song's words would be read as a bug in the lyrics, not as a mirroring subtlety.
            //
            // `LyricsView` reads the same source for the playhead, so the words follow the
            // song whichever device is making the sound.
            if let track = peer.displayedTrack {
                LyricsView(track: track, player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Only reachable with the bar sitting there empty — the toggle that opens this
                // panel lives in it, so there is always a transport on screen to explain the
                // state, and this says what would fill the panel rather than what is missing.
                ContentUnavailableView(
                    "Nothing Playing",
                    systemImage: "text.quote",
                    description: Text("Play a song and its words show up here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Centred content still has a bottom half, and the panel runs to the window's
                // edge underneath the transport bar. `LyricsView` clears each of its own
                // branches, so this is only the one it cannot see — doubling it there would
                // leave a second bar's worth of empty space under the last line.
                .transportClearance()
            }
        }
        .frame(width: 320)
        .background(Theme.background)
    }

    private var header: some View {
        HStack {
            Text("Lyrics").font(.headline)
            Spacer()
            HoverButton(systemImage: "xmark", label: "Close lyrics") {
                withAnimation(.easeInOut(duration: 0.18)) { isShown = false }
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }
}
