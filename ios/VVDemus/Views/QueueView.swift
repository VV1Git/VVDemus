import SwiftUI

struct QueueView: View {
    @ObservedObject var player: PlayerService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let current = player.currentTrack {
                    Section("Now Playing") {
                        TrackRow(track: current, isActive: true)
                            .listRowBackground(Theme.background)
                            .moveDisabled(true)
                            .deleteDisabled(true)
                    }
                }

                Section(player.queueContextTitle.map { "Next from: \($0)" } ?? "Next Up") {
                    if player.upNext.isEmpty {
                        Text("Queue is empty — autoplay will keep the music going.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .listRowBackground(Theme.background)
                    } else {
                        ForEach(player.upNext) { track in
                            TrackRow(track: track)
                                .listRowBackground(Theme.background)
                                .listRowSeparatorTint(Theme.card)
                                .contentShape(Rectangle())
                                .onTapGesture { player.skipTo(track) }
                        }
                        .onMove { player.moveInQueue(from: $0, to: $1) }
                        .onDelete { player.removeFromQueue(at: $0) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
