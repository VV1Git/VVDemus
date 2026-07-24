import SwiftUI

struct QueueView: View {
    @ObservedObject var player: PlayerService

    var body: some View {
        List {
            header
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 16, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Theme.background)

            if let current = player.currentTrack {
                nowPlayingRow(current)
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
                    .moveDisabled(true)
            }

            if player.manualQueue.isEmpty && player.contextQueue.isEmpty {
                Text("Queue is empty — autoplay will keep the music going.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
            }

            if !player.manualQueue.isEmpty {
                Section("Next in Queue") {
                    ForEach(player.manualQueue) { track in
                        queueRow(track)
                    }
                    .onMove { player.moveInManualQueue(from: $0, to: $1) }
                }
            }

            if !player.contextQueue.isEmpty {
                Section(player.queueContextTitle.map { "Next from: \($0)" } ?? "Next Up") {
                    ForEach(player.contextQueue) { track in
                        queueRow(track)
                    }
                    .onMove { player.moveInContextQueue(from: $0, to: $1) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .environment(\.editMode, .constant(.active))
    }

    private func queueRow(_ track: Track) -> some View {
        TrackRow(track: track)
            .listRowBackground(Theme.background)
            .listRowSeparatorTint(Theme.card)
            .contentShape(Rectangle())
            .onTapGesture { player.skipTo(track) }
            // Swipe left (trailing edge) to remove — matches Spotify's convention.
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    player.removeFromQueue(track)
                } label: {
                    Label("Remove", systemImage: "minus.circle.fill")
                }
            }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Queue")
                .font(.title.bold())
                .foregroundStyle(.white)
            if let context = player.queueContextTitle {
                Text("Playing \(context)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func nowPlayingRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: track.thumbnailUrl, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle().fill(Color.white).frame(width: 36, height: 36)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.footnote)
                        .foregroundStyle(.black)
                }
            }
            .buttonStyle(.plain)
        }
    }
}
