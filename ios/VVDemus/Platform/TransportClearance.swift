import SwiftUI

/// How tall the Mac's pinned transport bar currently is, so content can keep out from under it.
///
/// A singleton rather than an `EnvironmentValue`, which is the obvious choice and the wrong one
/// here. An environment value has to be *placed*: `MacRootView` already carries a note on
/// `openRadio` explaining that it only reaches pushed screens because it is attached after the
/// `navigationDestination` on the same view. There are four stacks in this app, and clearance
/// that silently stops at a stack boundary is the exact bug this file exists to end. A value
/// every screen can read directly cannot be positioned wrongly.
///
/// Nothing sets this on iOS, so it stays `0` there and every helper below renders nothing —
/// the phone's mini player is the system's `tabViewBottomAccessory`, which insets scroll content
/// on its own.
@MainActor
final class TransportMetrics: ObservableObject {
    static let shared = TransportMetrics()

    /// Measured by `MacRootView`, not guessed: the bar is three stacked children, two of which
    /// come and go, so a constant would be wrong exactly when an error is showing.
    @Published var height: CGFloat = 0

    private init() {}
}

/// Empty space the height of the transport bar, as a `List`'s last row.
///
/// A row rather than `safeAreaInset` or `contentMargins(for: .scrollContent)` on a container
/// further out, both of which have now been found — separately — to be dropped before they reach
/// a screen. `contentMargins` is silently ignored by the table-backed sidebar `List` on macOS.
/// `safeAreaInset` applied outside a `NavigationStack` reaches the stack's *root* and not what is
/// pushed onto it, which is why every screen you land on from the sidebar looked correct while
/// every screen you navigated *into* — a radio from Go to Radio, a playlist from Library — kept
/// its last row under the bar for good. Scrolling cannot move content the container does not
/// know is inset.
///
/// A row is laid out by definition. No scroll container can decline it.
///
/// Stripped of everything that would make it read as a row: no insets, no separator, no
/// background, and hidden from accessibility so VoiceOver doesn't announce a blank final item.
struct TransportClearanceRow: View {
    @ObservedObject private var metrics = TransportMetrics.shared

    var body: some View {
        if metrics.height > 0 {
            Color.clear
                .frame(height: metrics.height)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .selectionDisabled()
                .accessibilityHidden(true)
        }
    }
}

/// The same clearance for a `ScrollView`'s content — real padding on the content itself, for the
/// same reason the row above is a row.
private struct TransportClearancePadding: ViewModifier {
    @ObservedObject private var metrics = TransportMetrics.shared

    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.padding(.bottom, isEnabled ? metrics.height : 0)
    }
}

extension View {
    /// Keeps this scrolling content out from under the Mac transport bar. A no-op on iOS.
    ///
    /// Applied to the content *inside* a `ScrollView`, never to the `ScrollView` itself —
    /// padding on the container moves the whole viewport and leaves the content scrolling
    /// under the bar exactly as before.
    ///
    /// `isEnabled: false` is for content in a window that has no transport bar under it. The
    /// height above is a single app-wide figure measured by `MacRootView` — deliberately, so it
    /// cannot be positioned wrongly — which means a second window inherits the *main* window's
    /// bar height and reserves empty space for a bar that is not there. The miniplayer is the
    /// case: it shows `LyricsView`, whose every branch clears itself, in a panel shorter than the
    /// clearance it would apply.
    func transportClearance(_ isEnabled: Bool = true) -> some View {
        modifier(TransportClearancePadding(isEnabled: isEnabled))
    }
}
