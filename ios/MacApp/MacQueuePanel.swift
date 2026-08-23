import SwiftUI

/// The queue, as a panel beside the content rather than a sheet over it.
///
/// A sheet is the phone's answer, where there is no room for two things at once. On a Mac the
/// queue is something you keep open while you carry on browsing — so it sits alongside, and the
/// content simply narrows.
///
/// This is the desktop's only queue screen, so it owes the user everything `QueueView` gives the
/// phone: the two queues as separate sections, rows addressed by the position they were drawn at,
/// and reordering.
///
/// (`QueueView` itself does compile into the Mac target — it is not on project.yml's exclude list
/// — but it is only ever presented from `NowPlayingView`, which is only ever presented from
/// `RootView`, and *that* is excluded. So it is unreachable here by route, not by build.)
struct MacQueuePanel: View {
    @ObservedObject private var peer = PeerPlayback.shared
    @ObservedObject private var player = PlayerService.shared
    @Binding var isShown: Bool

    private var isQueueEmpty: Bool {
        peer.displayedManualQueue.isEmpty && peer.displayedContextQueue.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            List {
                if let track = peer.displayedTrack {
                    // Named after the device while the session is elsewhere: the rows below are
                    // the phone's queue, and a header that says so is the smallest thing that
                    // explains why the Mac is listing songs it isn't playing.
                    Section(peer.owningDeviceName.map { "Now Playing on \($0)" } ?? "Now Playing") {
                        QueueRow(track: track, isCurrent: true)
                            // Its section carries no `.onMove`, so nothing can move into or out of
                            // it today — but the track that is playing is the one row on this
                            // panel a drag must never reach, and `QueueView` pins the same thing
                            // on the phone rather than leaving it to the section boundary.
                            .moveDisabled(true)
                    }
                }

                // Stands in for the up-next rows only. The guard used to wrap the whole `List`,
                // so the track that was playing vanished from the panel the moment nothing was
                // queued behind it.
                if isQueueEmpty {
                    ContentUnavailableView(
                        "Nothing queued",
                        systemImage: "list.bullet",
                        description: Text("Songs you add with “Play Next” or “Add to Queue” show up here.")
                    )
                    .listRowSeparator(.hidden)
                }

                // Two sections rather than one flat list, and every row addressed by its index:
                // `skipTo(track)` and `removeFromQueue(track)` can only ever find the *first*
                // entry carrying a videoId, and a radio or a shelf may repeat one. Clicking the
                // second copy played the first and silently discarded every row in between. An
                // index only means something inside one of the two queues, hence the split.
                if !peer.displayedManualQueue.isEmpty {
                    let queue = peer.displayedManualQueue
                    let move: (IndexSet, Int) -> Void = { player.moveInManualQueue(from: $0, to: $1) }
                    Section("Next in Queue") {
                        ForEach(Array(queue.enumerated()), id: \.offset) { index, track in
                            row(
                                track,
                                skip: { player.skipToManualQueueEntry(at: index, expecting: track) },
                                remove: { player.removeFromManualQueue(at: index, expecting: track) },
                                moveUp: shift(index, by: -1, in: queue.count, move: move),
                                moveDown: shift(index, by: 1, in: queue.count, move: move)
                            )
                        }
                        // No Edit button gating this, unlike the phone: on macOS a row carrying
                        // `.onMove` reorders by being dragged, with no mode to switch into first.
                        // The drag starts from `QueueRow`'s grip and nowhere else — the rest of
                        // the row is a `Button`, and a press inside one never reaches the list.
                        // `player` relays the move to the paired device when that one owns the
                        // queue.
                        .onMove(perform: move)
                    }
                }

                if !peer.displayedContextQueue.isEmpty {
                    let queue = peer.displayedContextQueue
                    let move: (IndexSet, Int) -> Void = { player.moveInContextQueue(from: $0, to: $1) }
                    Section(peer.displayedContextTitle.map { "Next from: \($0)" } ?? "Next Up") {
                        ForEach(Array(queue.enumerated()), id: \.offset) { index, track in
                            row(
                                track,
                                skip: { player.skipToContextQueueEntry(at: index, expecting: track) },
                                remove: { player.removeFromContextQueue(at: index, expecting: track) },
                                moveUp: shift(index, by: -1, in: queue.count, move: move),
                                moveDown: shift(index, by: 1, in: queue.count, move: move)
                            )
                        }
                        .onMove(perform: move)
                    }
                }

                // The panel is a sibling of the detail column, not inside it, so it never saw
                // the clearance the detail column used to get from the split view — its last
                // queued track sat under the transport bar from the day the panel landed.
                TransportClearanceRow()
            }
            .listStyle(.inset)
        }
        .frame(width: 320)
        // The window's own ground, painted here rather than inherited.
        //
        // A panel is attached to the split view with `safeAreaInset`, which puts it OUTSIDE
        // the split view rather than inside a column — so there is no material behind it to
        // show through, and a panel that paints nothing is transparent, not system-coloured.
        // It looked correct in the queue only because a `List` paints its own background; the
        // header above it, and the whole of the lyrics panel, came out clear.
        //
        // `.windowBackground`, not `Theme.background`: the Mac is system-coloured throughout
        // now. See `Theme.screenBackground`.
        .background(.windowBackground)
    }

    /// Every action goes straight to `PlayerService`, which sends it to the paired device when
    /// that is the one holding the queue — see `SessionOwning`. The view never has to know which
    /// case it is in.
    private func row(
        _ track: Track,
        skip: @escaping () -> Void,
        remove: @escaping () -> Void,
        moveUp: (() -> Void)?,
        moveDown: (() -> Void)?
    ) -> some View {
        QueueRow(track: track, isCurrent: false, action: skip)
            .contextMenu {
                Button("Play Now", action: skip)
                // The keyboard and VoiceOver route to the reorder the grip offers a mouse. A drag
                // is pointer-only and the grip is `.accessibilityHidden`, so without these the
                // desktop's queue could only be rearranged by someone holding one.
                if let moveUp { Button("Move Up", action: moveUp) }
                if let moveDown { Button("Move Down", action: moveDown) }
                Button("Remove from Queue", role: .destructive, action: remove)
                Divider()
                DownloadToPhoneButton(tracks: [track])
            }
    }

    /// `move(fromOffsets:toOffset:)` takes a *pre-removal* offset, which is the trap here: moving
    /// down by one is `index + 2`, because `index + 1` is where the row already sits once it has
    /// been lifted out, and asking for it is a no-op.
    private func shift(_ index: Int, by places: Int, in count: Int, move: @escaping (IndexSet, Int) -> Void) -> (() -> Void)? {
        let target = index + places
        guard target >= 0, target < count else { return nil }
        return { move(IndexSet(integer: index), places < 0 ? target : target + 1) }
    }

    private var header: some View {
        HStack {
            Text("Queue").font(.headline)
            Spacer()
            HoverButton(systemImage: "xmark", label: "Close queue") {
                withAnimation(.easeInOut(duration: 0.18)) { isShown = false }
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }
}

private struct QueueRow: View {
    let track: Track
    let isCurrent: Bool
    /// `nil` on the now-playing row: it reports what is playing rather than offering to change it.
    var action: (() -> Void)? = nil
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            if let action {
                // A real `Button`, where this used to be a bare `.onTapGesture`: a gesture draws
                // no press feedback and carries no `.isButton` trait, so the panel clicked like
                // static text and VoiceOver announced it as static text too.
                Button(action: action) { content }
                    .buttonStyle(.pressableRow)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                // Beside the `Button` rather than inside it, and that placement is the whole
                // reason it exists. `.onMove` reorders a row on macOS by the list seeing a press
                // land on the row and turning it into a drag — but this `Button` covers the row's
                // full width (`content` ends in a `Spacer` and a `contentShape`), so every press
                // was the Button's, the list saw none of them, and nothing could be dragged
                // anywhere. `TrackRow` keeps its trailing controls out of its tappable region the
                // same way and for the same structural reason.
                grip
            } else {
                content
            }
        }
        .padding(.vertical, Theme.Metrics.rowVertical)
        .listRowBackground(isHovering && !isCurrent ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { isHovering = $0 }
    }

    /// Deliberately not a `Button`. It is the one part of the row the list gets to see a press
    /// on, which is what lets a drag begin at all; making it a control would put it straight back
    /// where the rest of the row already is.
    ///
    /// Revealed on hover rather than drawn always, and sized like every other trailing control in
    /// the app so the title column is the same width either way. `opacity`, not an `if`: removing
    /// it to hide it reflowed every title the moment the pointer crossed a row.
    ///
    /// Hidden from VoiceOver because a drag is pointer-only — the reorder it offers a mouse is
    /// offered to everyone else by Move Up / Move Down in the row's menu.
    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.trailingGlyph)
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0)
            .frame(width: Theme.Metrics.trailingControl, height: Theme.Metrics.hitTarget)
            .contentShape(Rectangle())
            .help("Drag to reorder")
            .accessibilityHidden(true)
    }

    private var content: some View {
        HStack(spacing: Theme.Space.md) {
            RemoteImage(url: track.thumbnailUrl, size: Theme.ArtSize.row)
            VStack(alignment: .leading, spacing: Theme.Metrics.labelSpacing) {
                Text(track.title)
                    .font(.miniTitle)
                    .foregroundStyle(isCurrent ? Theme.accent : .primary)
                    .lineLimit(1)
                Text(track.artist).font(.miniSubtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            // The speaker glyph rather than a colour change alone: colour is the only cue the
            // list otherwise gives, and it disappears entirely for anyone who can't see it.
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
        // A `Button`'s hit region is its label's content shape, and the trailing `Spacer` draws
        // nothing — without this the width beside a short title is dead to clicks, which on a
        // 320pt panel is most of the row.
        .contentShape(Rectangle())
    }
}
