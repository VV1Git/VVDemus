import SwiftUI

/// Reserves room at the bottom of a scrollable view for the floating bottom bar.
///
/// The bar is drawn as an overlay in `RootView`, which means it covers whatever is beneath
/// it — the last row of every list was ~93% hidden and effectively untappable. Two screens
/// had hand-tuned `.padding(.bottom, 110)` / `40` constants that disagreed with each other
/// and with the real height; everything else had nothing at all.
///
/// Now covers the tab bar as well as the mini player. The system tab bar used to inset tab
/// content by itself, for free; a floating bar is just an overlay and insets nothing, so
/// every pixel it occupies has to be accounted for here (see `BottomBar.contentInset`).
struct MiniPlayerInset: ViewModifier {
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: BottomBar.contentInset)
        }
    }
}

extension View {
    func miniPlayerInset() -> some View { modifier(MiniPlayerInset()) }
}
