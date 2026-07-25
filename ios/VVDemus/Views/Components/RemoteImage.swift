import SwiftUI
import UIKit

/// Bounded in-memory bitmap cache shared by every `RemoteImage`. Plain `AsyncImage` has no
/// decoded-image cache of its own — scrolling a list back and forth re-downloads and
/// re-decodes the same thumbnail every time it re-enters the view hierarchy. Most track art
/// is reused constantly (same song in Home, a shelf, the queue, and the now-playing bar all
/// at once), so caching the decoded `UIImage` turns that into a one-time cost.
@MainActor
private final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 300 // plenty for anything this app shows at once; NSCache also
        // evicts under memory pressure on its own, so this is a soft ceiling, not a hard cap.
    }

    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    func store(_ image: UIImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
}

struct RemoteImage: View {
    let url: String?
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 4
    @State private var uiImage: UIImage?

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage).resizable().scaledToFill()
            } else {
                Rectangle()
                    .fill(Theme.card)
                    .overlay(
                        Image(systemName: "music.note")
                            .foregroundStyle(Theme.textSecondary)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        uiImage = nil
        guard let url else { return }
        if let cached = ImageCache.shared.image(for: url) {
            uiImage = cached
            return
        }
        guard let requestURL = URL(string: url),
              let (data, _) = try? await URLSession.shared.data(from: requestURL),
              let image = UIImage(data: data) else { return }
        guard !Task.isCancelled else { return }
        ImageCache.shared.store(image, for: url)
        uiImage = image
    }
}
