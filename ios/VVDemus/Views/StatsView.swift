import SwiftUI

struct StatsView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject private var stats = ListeningStatsStore.shared
    @State private var range: StatsRange = .week

    enum StatsRange: String, CaseIterable, Identifiable {
        case week = "1 Week"
        case month = "1 Month"
        case threeMonths = "3 Months"
        case year = "1 Year"

        var id: String { rawValue }

        var days: Int {
            switch self {
            case .week: return 7
            case .month: return 30
            case .threeMonths: return 90
            case .year: return 365
            }
        }
    }

    private struct ArtistStat: Identifiable {
        let name: String
        let count: Int
        var id: String { name }
    }

    private struct SongStat: Identifiable {
        let track: Track
        let count: Int
        var id: String { track.id }
    }

    private var since: Date {
        Calendar.current.date(byAdding: .day, value: -range.days, to: Date()) ?? .distantPast
    }

    private var eventsInRange: [PlayEvent] {
        stats.events(since: since)
    }

    private var topArtists: [ArtistStat] {
        var counts: [String: Int] = [:]
        for event in eventsInRange {
            counts[event.track.artist, default: 0] += 1
        }
        return counts.map { ArtistStat(name: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(10)
            .map { $0 }
    }

    private var topSongs: [SongStat] {
        var counts: [String: Int] = [:]
        var tracksByID: [String: Track] = [:]
        for event in eventsInRange {
            counts[event.track.id, default: 0] += 1
            tracksByID[event.track.id] = event.track
        }
        return counts.compactMap { id, count in tracksByID[id].map { SongStat(track: $0, count: count) } }
            .sorted { $0.count > $1.count }
            .prefix(10)
            .map { $0 }
    }

    private var totalListeningSeconds: Int {
        eventsInRange.reduce(0) { $0 + $1.secondsPlayed }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Picker("Range", selection: $range) {
                    ForEach(StatsRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if eventsInRange.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.bar")
                            .font(.largeTitle)
                            .foregroundStyle(Theme.textSecondary)
                        Text("No listening history in this range yet")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    summaryRow

                    if !topArtists.isEmpty {
                        sectionHeader("Top Artists")
                        VStack(spacing: 0) {
                            ForEach(Array(topArtists.enumerated()), id: \.element.id) { index, artist in
                                artistRow(rank: index + 1, artist: artist)
                                if artist.id != topArtists.last?.id {
                                    Divider().background(Theme.card)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }

                    if !topSongs.isEmpty {
                        sectionHeader("Top Songs")
                        VStack(spacing: 0) {
                            ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, song in
                                songRow(rank: index + 1, song: song)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        player.play(track: song.track, context: topSongs.map(\.track), contextTitle: "Top Songs")
                                    }
                                if song.id != topSongs.last?.id {
                                    Divider().background(Theme.card)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
            .padding(.bottom, 40)
        }
        .background(Theme.background)
        .navigationTitle("Your Stats")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.title3.bold())
            .foregroundStyle(.white)
            .padding(.horizontal)
    }

    private var summaryRow: some View {
        HStack(spacing: 12) {
            statCard(value: "\(eventsInRange.count)", label: "Plays")
            statCard(value: formattedDuration(totalListeningSeconds), label: "Listened")
            statCard(value: "\(topArtists.count)", label: "Artists")
        }
        .padding(.horizontal)
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Theme.cardLight)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func artistRow(rank: Int, artist: ArtistStat) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24, alignment: .leading)
            Text(artist.name)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            Text("\(artist.count) play\(artist.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 10)
    }

    private func songRow(rank: Int, song: SongStat) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24, alignment: .leading)
            RemoteImage(url: song.track.thumbnailUrl, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.track.title)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(song.track.artist)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(song.count)×")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 6)
    }

    private func formattedDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
