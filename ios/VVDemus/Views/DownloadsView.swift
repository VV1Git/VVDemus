import SwiftUI

struct DownloadsView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var isSelecting = false
    @State private var selectedIDs = Set<String>()

    private var allSelected: Bool {
        !downloads.downloadedTracks.isEmpty && selectedIDs.count == downloads.downloadedTracks.count
    }

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
                        HStack(spacing: 12) {
                            if isSelecting {
                                Image(systemName: selectedIDs.contains(track.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selectedIDs.contains(track.id) ? Theme.accent : Theme.textSecondary)
                            }
                            TrackRow(track: track, isActive: player.currentTrack?.id == track.id)
                        }
                        .listRowBackground(Theme.background)
                        .listRowSeparatorTint(Theme.card)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isSelecting {
                                toggleSelection(track.id)
                            } else {
                                player.play(track: track, context: downloads.downloadedTracks, contextTitle: "Downloads")
                            }
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
        .toolbar {
            if !downloads.downloadedTracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? "Cancel" : "Select") {
                        isSelecting.toggle()
                        if !isSelecting { selectedIDs.removeAll() }
                    }
                }
                if isSelecting {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button(allSelected ? "Deselect All" : "Select All") {
                            selectedIDs = allSelected ? [] : Set(downloads.downloadedTracks.map(\.id))
                        }
                        Spacer()
                        Button(role: .destructive) {
                            deleteSelected()
                        } label: {
                            Text(selectedIDs.isEmpty ? "Delete" : "Delete (\(selectedIDs.count))")
                        }
                        .disabled(selectedIDs.isEmpty)
                    }
                }
            }
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func deleteSelected() {
        let tracksToDelete = downloads.downloadedTracks.filter { selectedIDs.contains($0.id) }
        downloads.removeAll(tracksToDelete)
        selectedIDs.removeAll()
        isSelecting = false
    }
}
