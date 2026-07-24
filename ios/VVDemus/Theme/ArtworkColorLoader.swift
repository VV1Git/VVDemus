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
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    private init() {}

    func color(for track: Track?) -> Color {
        guard let key = track?.thumbnailUrl else { return Theme.cardLight }
        if let cached = colors[key] { return cached }
        load(urlString: key)
        return Theme.cardLight
    }

    private func load(urlString: String) {
        guard !inFlight.contains(urlString), let url = URL(string: urlString) else { return }
        inFlight.insert(urlString)
        Task {
            defer { inFlight.remove(urlString) }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let uiImage = UIImage(data: data),
                  let ciImage = CIImage(image: uiImage) else { return }
            guard let averaged = averageColor(of: ciImage) else { return }
            colors[urlString] = averaged
        }
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
