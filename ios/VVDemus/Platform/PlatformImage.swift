import ImageIO
import SwiftUI

#if os(iOS)
import UIKit

/// The platform's bitmap type. `UIImage` on the phone, `NSImage` on the Mac.
///
/// Both apps compile the same sources, and the handful of places that touch a decoded
/// bitmap — lock-screen artwork, the thumbnail cache, the downloaded-artwork check — are
/// otherwise identical on the two platforms. This spares them all a `#if`.
typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit

typealias PlatformImage = NSImage
#endif

extension Image {
    /// `Image(uiImage:)` and `Image(nsImage:)` are the same initializer under two names.
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #elseif os(macOS)
        self.init(nsImage: platformImage)
        #endif
    }
}

enum ImageData {
    /// Whether `data` really is a decodable image.
    ///
    /// Deliberately ImageIO rather than `PlatformImage(data:)`: this is asked of bytes that
    /// arrived over the network and may be a captive-portal page or a 404 body, and the two
    /// platforms' image types disagree about what they will accept — `NSImage` in particular
    /// will happily wrap data it cannot draw. `CGImageSourceCreateImageAtIndex` returning a
    /// frame is the same answer on both.
    static func isDecodable(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
}
