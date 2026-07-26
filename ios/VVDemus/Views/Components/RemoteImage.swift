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
    @Environment(\.displayScale) private var displayScale
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
        let targetPixels = RemoteImage.targetPixelSize(for: size, displayScale: displayScale)
        let requestURLString = RemoteImage.resizedThumbnailUrl(url, targetPixels: targetPixels)
        let cacheKey = "\(requestURLString)"

        if let cached = ImageCache.shared.image(for: cacheKey) {
            uiImage = cached
            return
        }
        if let diskData = await DiskImageCache.shared.data(for: cacheKey), let image = UIImage(data: diskData) {
            guard !Task.isCancelled else { return }
            ImageCache.shared.store(image, for: cacheKey)
            uiImage = image
            return
        }
        guard let requestURL = URL(string: requestURLString),
              let (data, _) = try? await NetworkSessions.image.data(from: requestURL),
              let image = UIImage(data: data) else { return }
        guard !Task.isCancelled else { return }
        ImageCache.shared.store(image, for: cacheKey)
        await DiskImageCache.shared.store(data, for: cacheKey)
        uiImage = image
    }

    /// The pixel size to actually request — the on-screen point size scaled for the
    /// device's display scale, shrunk further under Data Saver. Avoids paying for (and
    /// caching) full-resolution bytes for a 48pt row thumbnail.
    static func targetPixelSize(for pointSize: CGFloat, displayScale: CGFloat) -> Int {
        let dataSaver = UserDefaults.standard.bool(forKey: InnerTubeClient.dataSaverDefaultsKey)
        let multiplier = dataSaver ? 0.75 : 1.0
        return max(1, Int((pointSize * displayScale * multiplier).rounded(.up)))
    }

    /// YouTube's `yt3.googleusercontent.com` thumbnail URLs encode the requested pixel
    /// size as a `=w{N}-h{N}-...` suffix that can be rewritten to any size — confirmed
    /// empirically (a 544px source URL rewritten to `w48-h48` returns ~1.8KB instead of
    /// ~83KB, the same image data just resized server-side). Falls back to the original
    /// URL unchanged if it doesn't match the expected shape.
    ///
    /// The requested size is clamped to what the URL already advertises. Different
    /// endpoints hand back very different sizes — search results arrive as 120px, radio
    /// items as 544px — so a 300pt hero image on a 3x screen would otherwise ask a 120px
    /// source for 900px and be served a blurry upscale at roughly six times the bytes of
    /// the original.
    static func resizedThumbnailUrl(_ url: String, targetPixels: Int) -> String {
        guard let range = url.range(of: #"=w\d+-h\d+"#, options: .regularExpression) else { return url }
        let sourceWidth = url[range]
            .dropFirst(2)                                    // "=w"
            .prefix { $0.isNumber }
        let target = min(targetPixels, Int(sourceWidth) ?? targetPixels)
        return url.replacingCharacters(in: range, with: "=w\(target)-h\(target)")
    }
}
