import SwiftUI

struct StatsView: View {
    @ObservedObject var player: PlayerService
    @ObservedObject private var stats = ListeningStatsStore.shared
    @State private var range: StatsRange = .week

    enum StatsRange: String, CaseIterable, Identifiable {
        case week = "Week"
        case month = "Month"
        case threeMonths = "3 Mo"
        case year = "Year"

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

    /// The rank column, and the two divider insets derived from it: a hairline must start at
    /// the leading edge of the *text*, never under the rank or the artwork.
    private static let rankWidth = Theme.Space.xl                                    // 24
    private static let artistTextLeading = rankWidth + Theme.Space.md                // 36
    private static let songTextLeading =
        rankWidth + Theme.Space.md + Theme.ArtSize.row + Theme.Space.md              // 96

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

    /// Every distinct artist in range — *not* `topArtists.count`, which is capped at 10 and so
    /// reported a permanent, wrong "10" next to two correct numbers.
    private var distinctArtistCount: Int {
        Set(eventsInRange.map(\.track.artist)).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                if eventsInRange.isEmpty {
                    ContentUnavailableView(
                        "No Listening History",
                        systemImage: "chart.bar",
                        description: Text("Play something and this range will fill up.")
                    )
                    .padding(.top, Theme.Space.xxl)
                } else {
                    summaryRow

                    if !topArtists.isEmpty {
                        section("Top Artists") {
                            ForEach(Array(topArtists.enumerated()), id: \.element.id) { index, artist in
                                artistRow(rank: index + 1, artist: artist)
                                if artist.id != topArtists.last?.id {
                                    hairline(leading: Self.artistTextLeading)
                                }
                            }
                        }
                    }

                    if !topSongs.isEmpty {
                        section("Top Songs") {
                            ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, song in
                                songRow(rank: index + 1, song: song)
                                if song.id != topSongs.last?.id {
                                    hairline(leading: Self.songTextLeading)
                                }
                            }
                        }
                    }
                }
            }
            // R1: the screen's one gutter, declared once on the outermost content container.
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.vertical, Theme.Space.lg)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .top) { rangePicker }
        .navigationTitle("Your Stats")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Pinned rather than scrolled: it is the only control on the screen, and it used to
    /// disappear above the numbers it changes.
    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(StatsRange.allCases) { r in
                Text(r.rawValue).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.vertical, Theme.Space.sm)
        .background(.bar)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title)
                .font(.shelfHeader)
                .foregroundStyle(.primary)
            VStack(spacing: 0) { content() }
        }
    }

    private var summaryRow: some View {
        HStack(spacing: Theme.Space.md) {
            statCard(value: "\(eventsInRange.count)", label: "Plays")
            statCard(value: formattedDuration(totalListeningSeconds), label: "Listened")
            statCard(value: "\(distinctArtistCount)", label: "Artists")
        }
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: Theme.Space.xs) {
            Text(value)
                .font(.statValue)
                .foregroundStyle(.primary)
                // "127h 45m" used to wrap and inflate all three equal-height cards.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.meta)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.lg)
        // R5: this sits directly on the background inside a scroll, where glass renders as a
        // flat gray box and costs a render pass.
        .background(Theme.card, in: Theme.Radius.rect(Theme.Radius.card))
    }

    private func artistRow(rank: Int, artist: ArtistStat) -> some View {
        HStack(spacing: Theme.Space.md) {
            rankLabel(rank)
            Text(artist.name)
                .font(.rowTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.md)
            playCount(artist.count)
        }
        .padding(.vertical, Theme.Metrics.rowVertical)
    }

    private func songRow(rank: Int, song: SongStat) -> some View {
        HStack(spacing: Theme.Space.md) {
            rankLabel(rank)
            // TrackRow owns the artwork, the type, the now-playing state and its own trailing
            // controls, so this row matches every other song row in the app. The play count is
            // the only thing this screen adds, and it sits outside TrackRow.
            TrackRow(
                track: song.track,
                isActive: player.currentTrack?.id == song.track.id,
                onTap: {
                    player.play(track: song.track, context: topSongs.map(\.track), contextTitle: "Top Songs")
                }
            )
            playCount(song.count)
        }
        .padding(.vertical, Theme.Metrics.rowVertical)
        .trackActions(track: song.track, player: player)
    }

    private func rankLabel(_ rank: Int) -> some View {
        Text("\(rank)")
            .font(.meta)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: Self.rankWidth, alignment: .leading)
    }

    /// One wording for both tables — artists said "3 plays" while songs three lines below said
    /// "3×". The long form stays for VoiceOver.
    private func playCount(_ count: Int) -> some View {
        Text("\(count)×")
            .font(.meta)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("^[\(count) play](inflect: true)"))
    }

    /// `Divider().background(_:)` does not tint a divider, so the intended color never
    /// rendered here. A hairline rectangle does — and it starts at the text leading edge so it
    /// never runs under the rank or the artwork.
    private func hairline(leading: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 0.5)
            .padding(.leading, leading)
    }

    private func formattedDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
