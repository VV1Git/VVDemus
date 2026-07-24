import SwiftUI

/// Hero section for a radio/playlist detail screen: big art with a badge, title,
/// byline, song/duration stats, and shuffle + play buttons — mirrors Spotify's layout.
struct MixDetailHeader: View {
    let title: String
    let subtitle: String
    let badge: String?
    let imageURL: String?
    let trackCount: Int
    let totalDuration: TimeInterval
    let onPlay: () -> Void
    let onShuffle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .topTrailing) {
                RemoteImage(url: imageURL, size: 260, cornerRadius: 8)
                if let badge {
                    Text(badge.uppercased())
                        .font(.caption.weight(.heavy))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55))
                        .clipShape(Capsule())
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title.bold())
                    .foregroundStyle(.white)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(statsLine)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal)

            HStack(spacing: 24) {
                Button(action: onShuffle) {
                    Image(systemName: "shuffle")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onPlay) {
                    ZStack {
                        Circle().fill(Theme.accent).frame(width: 56, height: 56)
                        Image(systemName: "play.fill")
                            .font(.title3)
                            .foregroundStyle(.black)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
        }
        .padding(.top, 8)
    }

    private var statsLine: String {
        let songs = trackCount == 1 ? "1 song" : "\(trackCount) songs"
        guard totalDuration > 0 else { return songs }
        let hours = Int(totalDuration) / 3600
        let minutes = (Int(totalDuration) % 3600) / 60
        let durationText = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
        return "\(songs) • \(durationText)"
    }
}
