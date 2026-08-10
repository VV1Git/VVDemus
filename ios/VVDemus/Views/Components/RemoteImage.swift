import SwiftUI

/// Bounded in-memory bitmap cache shared by every `RemoteImage`. Plain `AsyncImage` has no
/// decoded-image cache of its own — scrolling a list back and forth re-downloads and
/// re-decodes the same thumbnail every time it re-enters the view hierarchy. Most track art
/// is reused constantly (same song in Home, a shelf, the queue, and the now-playing bar all
/// at once), so caching the decoded bitmap turns that into a one-time cost.
@MainActor
private final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, PlatformImage>()

    private init() {
        cache.countLimit = 300 // plenty for anything this app shows at once; NSCache also
        // evicts under memory pressure on its own, so this is a soft ceiling, not a hard cap.
    }

    func image(for key: String) -> PlatformImage? { cache.object(forKey: key as NSString) }
    func store(_ image: PlatformImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
}

struct RemoteImage: View {
    let url: String?
    var size: CGFloat = 48
    /// `nil` means "the radius that matches this artwork size" (`Theme.Radius.art(for:)`).
    /// Only pass a value when the container supplies its own clip — e.g. artwork bled into
    /// a tile's leading edge, which needs `0` so the tile's corners win.
    var cornerRadius: CGFloat? = nil
    @Environment(\.displayScale) private var displayScale
    /// Set once the bitmap has been loaded, together with the key it was loaded for. The key
    /// is what makes a recycled cell correct: state survives reuse, so a stale image must not
    /// be shown for a new URL.
    @State private var loadedImage: PlatformImage?
    @State private var loadedKey: String?

    private var radius: CGFloat { cornerRadius ?? Theme.Radius.art(for: size) }

    /// The exact URL string this view will request at this size — also the cache key.
    private var cacheKey: String? {
        guard let url else { return nil }
        let targetPixels = RemoteImage.targetPixelSize(for: size, displayScale: displayScale)
        return RemoteImage.resizedThumbnailUrl(url, targetPixels: targetPixels)
    }

    /// Resolved during `body`, not in `.task`: the task only runs after the first frame, so
    /// consulting the memory cache there made every recycled cell flash the gray placeholder
    /// even though its bitmap was already in memory. A hit here draws on frame one.
    @MainActor private var image: PlatformImage? {
        guard let cacheKey else { return nil }
        if let loadedImage, loadedKey == cacheKey { return loadedImage }
        return ImageCache.shared.image(for: cacheKey)
    }

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    // Scales with the frame: a fixed glyph is body-sized in a 48pt thumb and
                    // a speck in the 280pt hero.
                    .font(.system(size: max(12, size * 0.32)))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        // Behind the image too, so 16:9 letterboxing blends instead of reading as broken art.
        .background(Theme.card)
        .clipShape(Theme.Radius.rect(radius))
        .animation(.easeIn(duration: 0.15), value: image != nil)
        .task(id: url) {
            await load()
        }
        .accessibilityHidden(true)
    }

    private func load() async {
        guard let cacheKey else { return }
        // Already resolved for this exact key (including via the synchronous body lookup).
        if loadedKey == cacheKey, loadedImage != nil { return }

        if let cached = ImageCache.shared.image(for: cacheKey) {
            set(cached, for: cacheKey)
            return
        }
        // Genuinely uncached: only now is it right to drop whatever a recycled cell was showing.
        loadedImage = nil
        loadedKey = cacheKey

        if let diskData = await DiskImageCache.shared.data(for: cacheKey), let image = PlatformImage(data: diskData) {
            guard !Task.isCancelled else { return }
            ImageCache.shared.store(image, for: cacheKey)
            set(image, for: cacheKey)
            return
        }
        guard let requestURL = URL(string: cacheKey),
              let (data, _) = try? await NetworkSessions.image.data(from: requestURL),
              let image = PlatformImage(data: data) else { return }
        guard !Task.isCancelled else { return }
        ImageCache.shared.store(image, for: cacheKey)
        await DiskImageCache.shared.store(data, for: cacheKey)
        set(image, for: cacheKey)
    }

    private func set(_ image: PlatformImage, for key: String) {
        loadedImage = image
        loadedKey = key
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
        if let sized = ytimgVariant(url, targetPixels: targetPixels) { return sized }
        guard let range = url.range(of: #"=w\d+-h\d+"#, options: .regularExpression) else { return url }
        let sourceWidth = url[range]
            .dropFirst(2)                                    // "=w"
            .prefix { $0.isNumber }
        let target = min(targetPixels, Int(sourceWidth) ?? targetPixels)
        return url.replacingCharacters(in: range, with: "=w\(target)-h\(target)")
    }

    /// Radio and watch endpoints hand back `i.ytimg.com/vi/{id}/hq720.jpg?sqp=…` instead of
    /// the `yt3.googleusercontent.com` form, and the `=w{N}-h{N}` rewrite above doesn't
    /// match it at all — so every one of those was fetched at full size. Measured: 49.7 KB
    /// each, against 11.5 KB for the same image at row size. A radio screen shows dozens.
    ///
    /// These URLs expose fixed-size variants by filename. The signature parameters belong
    /// to the specific filename, so they're dropped — the unsigned variants are served
    /// happily (verified against all six).
    ///
    /// Large targets deliberately keep the original URL: `sddefault`/`maxresdefault` are
    /// the two variants that genuinely can 404 for some videos, and a missing hero image is
    /// a worse outcome than a few saved kilobytes on the one image the user is looking at.
    private static func ytimgVariant(_ url: String, targetPixels: Int) -> String? {
        guard let components = URLComponents(string: url),
              components.host?.hasSuffix("ytimg.com") == true else { return nil }
        let path = components.path
        guard let range = path.range(of: #"/vi/[^/]+/"#, options: .regularExpression) else { return nil }
        let base = String(path[..<range.upperBound])

        let variant: String
        switch targetPixels {
        case ..<200: variant = "mqdefault"   // 320×180, ~11.5 KB
        case ..<400: variant = "hqdefault"   // 480×360, ~21.4 KB
        default: return nil                  // hero images keep whatever they were given
        }
        return "https://i.ytimg.com\(base)\(variant).jpg"
    }
}
