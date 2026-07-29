import SwiftUI
import UIKit
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
    private let context = CIContext(options: [.workingColorSpace: NSNull()])
    /// A 1×1 average doesn't need pixels. 64px is plenty and costs a fraction of the
    /// original, which was being downloaded in full and thrown away after one pass.
    private static let sampleSize = 64
    /// Bounded like every other cache here; this used to grow for the process lifetime.
    private static let limit = 200

    private init() {}

    /// Returns the cached colour, and — deliberately — does *not* start a fetch. Kicking
    /// off network work from inside a view body is a side effect during view evaluation;
    /// call `prepare(for:)` from a `.task` instead.
    func color(for track: Track?) -> Color {
        guard let key = track?.thumbnailUrl, let cached = colors[key] else { return Theme.cardLight }
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
        guard let data,
              let uiImage = UIImage(data: data),
              let ciImage = CIImage(image: uiImage),
              let averaged = averageColor(of: ciImage) else {
            failed.insert(key)
            return
        }
        if colors.count >= Self.limit { colors.removeAll() }
        colors[key] = averaged
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
            format: .RGBA8,
            colorSpace: nil
        )
        return Color(
            red: Double(bitmap[0]) / 255,
            green: Double(bitmap[1]) / 255,
            blue: Double(bitmap[2]) / 255
        )
    }
}
