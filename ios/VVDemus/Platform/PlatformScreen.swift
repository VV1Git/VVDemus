import CoreGraphics

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum PlatformScreen {
    /// Pixels per point on the main display, used to size thumbnail requests so the app
    /// fetches artwork at the resolution it will actually draw.
    ///
    /// A Mac's main display is whichever one holds the menu bar, which need not be the one
    /// this window is on — a Retina laptop driving a 1x external monitor reports 2 here
    /// either way. That only costs some wasted pixels in a cache key, and it keeps this
    /// callable from anywhere, so it is not worth resolving per-window.
    static var scale: CGFloat {
        #if os(iOS)
        return UIScreen.main.scale
        #elseif os(macOS)
        // No main screen at all when every display is asleep. 2 matches every Mac Apple
        // currently ships, and is the safer guess: too high wastes bytes, too low is visibly
        // soft artwork that the cache then keeps.
        return NSScreen.main?.backingScaleFactor ?? 2
        #endif
    }
}
