import SwiftUI
import CoreImage

/// Approximates Spotify's now-playing background: the average color of the current
/// track's artwork, tinting the mini player and full-screen player.
@MainActor
final class ArtworkColorLoader: ObservableObject {
    static let shared = ArtworkColorLoader()

    @Published private(set) var colors: [String: Color] = [:]
    private var inFlight: Set<String> = []
    /// Keys that failed. Without this, a thumbnail that can't be fetched or decoded was
    /// retried on *every* call — and the call sites are inside view bodies that re-evaluate
    /// twice a second while playing, so one bad URL meant two full-size image downloads a
    /// second for as long as the mini player was on screen.
    private var failed: Set<String> = []
    /// Insertion order, so the cache can evict its oldest entry instead of emptying itself.
    private var insertionOrder: [String] = []
    /// Default working space, i.e. linear. Averaging gamma-encoded bytes (what
    /// `workingColorSpace: NSNull()` did) biases every result dark and desaturated, which
    /// is exactly what made the gradient muddy; the render below converts back to sRGB.
    private let context = CIContext()
    /// A 1×1 average doesn't need pixels. 64px is plenty and costs a fraction of the
    /// original, which was being downloaded in full and thrown away after one pass.
    private static let sampleSize = 64
    /// Bounded like every other cache here; this used to grow for the process lifetime.
    private static let limit = 200

    private init() {}

    /// Returns the cached colour, and — deliberately — does *not* start a fetch. Kicking
    /// off network work from inside a view body is a side effect during view evaluation;
    /// call `prepare(for:)` from a `.task` instead.
    ///
    /// A miss falls back to the page background, so a cold track fades in from black rather
    /// than flashing a grey slab first.
    func color(for track: Track?) -> Color {
        guard let key = track?.thumbnailUrl, let cached = colors[key] else { return Theme.background }
        return cached
    }

    /// Loads the average colour for a track if it isn't already known.
    func prepare(for track: Track?) async {
        guard let key = track?.thumbnailUrl else { return }
        guard colors[key] == nil, !failed.contains(key), !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        // Goes through the shared image session and disk cache like everything else, so
        // these bytes are counted in the Library screen's usage figures and are shared with
        // the artwork the UI is already showing, instead of being an invisible second
        // download of the full-resolution image.
        let request = RemoteImage.resizedThumbnailUrl(key, targetPixels: Self.sampleSize)
        var data = await DiskImageCache.shared.data(for: request)
        if data == nil, let url = URL(string: request),
           let (fetched, _) = try? await NetworkSessions.image.data(from: url) {
            await DiskImageCache.shared.store(fetched, for: request)
            data = fetched
        }
        // Straight from the bytes rather than via a platform bitmap: `CIImage(image:)` takes
        // a `UIImage` on the phone and an `NSImage` on the Mac, whereas `CIImage(data:)` is
        // the same call on both — and the intermediate image was never used for anything
        // else here.
        guard let data,
              let ciImage = CIImage(data: data),
              let averaged = averageColor(of: ciImage) else {
            failed.insert(key)
            return
        }
        // Oldest-first, not `removeAll()`: emptying the cache flushed the *currently
        // playing* track's colour along with everything else, and the gradient reverted
        // mid-song for no visible reason.
        while colors.count >= Self.limit, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            colors.removeValue(forKey: oldest)
        }
        colors[key] = averaged
        insertionOrder.append(key)
    }

    /// The average, forced into a range that a full-bleed gradient and a glass tint under
    /// white text can both survive. Clamping here rather than at the call sites is
    /// deliberate: a pale or washed-out cover makes Now Playing unreadable, and there is no
    /// call site that wants the raw value.
    /// Takes components rather than a platform colour: `UIColor.getHue` reports failure by
    /// returning false, while `NSColor`'s raises if the receiver isn't in an RGB space. The
    /// conversion is a dozen lines of arithmetic that cannot fail either way, and these
    /// components come straight from a `.RGBA8` render, so there is no colour object worth
    /// constructing in between.
    private func readable(red: Double, green: Double, blue: Double) -> Color {
        let highest = max(red, green, blue)
        let lowest = min(red, green, blue)
        let delta = highest - lowest

        var hue: Double = 0
        if delta > 0 {
            if highest == red {
                hue = (green - blue) / delta + (green < blue ? 6 : 0)
            } else if highest == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
        }

        return Color(
            hue: hue,
            saturation: min(max(highest == 0 ? 0 : delta / highest, 0.35), 0.80),
            brightness: min(highest, 0.42)
        )
    }

    private func averageColor(of image: CIImage) -> Color? {
        let extent = CIVector(cgRect: image.extent)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: extent,
        ]), let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            // Explicit, so the linear average lands back in sRGB rather than being handed
            // out as linear values interpreted as if they were gamma-encoded.
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return readable(
            red: Double(bitmap[0]) / 255,
            green: Double(bitmap[1]) / 255,
            blue: Double(bitmap[2]) / 255
        )
    }
}
