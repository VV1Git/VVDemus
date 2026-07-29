import SwiftUI

/// Reserves room at the bottom of a scrollable view for the mini player.
///
/// The mini player is drawn as an overlay in `RootView`, which means it covers whatever is
/// beneath it — the last row of every list was ~93% hidden and effectively untappable.
/// Two screens had hand-tuned `.padding(.bottom, 110)` / `40` constants that disagreed with
/// each other and with the real height; everything else had nothing at all.
///
/// Applied unconditionally rather than only while something is playing: the inset appearing
/// and disappearing would make lists jump under the user's finger the moment playback
/// starts.
struct MiniPlayerInset: ViewModifier {
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: RootView.miniPlayerHeight)
        }
    }
}

extension View {
    func miniPlayerInset() -> some View { modifier(MiniPlayerInset()) }
}
