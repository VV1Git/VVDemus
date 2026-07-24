import SwiftUI

struct DownloadsView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        Group {
            if downloads.downloadedTracks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.textSecondary)
                    Text("Downloaded songs play without using data")
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(downloads.downloadedTracks) { track in
                        TrackRow(track: track, isActive: player.currentTrack?.id == track.id)
                            .listRowBackground(Theme.background)
                            .listRowSeparatorTint(Theme.card)
                            .onTapGesture {
                                player.play(track: track, context: downloads.downloadedTracks, contextTitle: "Downloads")
                            }
                            .trackActions(track: track, player: player)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.background)
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
    }
}
