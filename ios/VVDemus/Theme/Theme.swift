import SwiftUI
import UIKit

enum Theme {
    static let background = Color.black
    static let card = Color(white: 0.12)
    static let cardLight = Color(white: 0.18)
    static let accent = Color(red: 0.11, green: 0.73, blue: 0.33)
    static let textSecondary = Color(white: 0.62)
}

/// Gives a button a small amount of "give" when pressed.
///
/// Almost every control in the app uses `.buttonStyle(.plain)` to avoid SwiftUI tinting
/// its label blue — but that also throws away the default press highlight, leaving taps
/// with no acknowledgement at all. This restores a deliberate one: a slight shrink and
/// dim, springing back on release.
struct PressableButtonStyle: ButtonStyle {
    /// Large controls need proportionally less shrink to read as the same gesture.
    var scale: CGFloat = 0.92
    var pressedOpacity: Double = 0.65

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Default press feedback, for icon-sized controls.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }

    /// For big targets — artwork cards, the main play button — where a 0.92 shrink is too
    /// much movement.
    static var pressableCard: PressableButtonStyle {
        PressableButtonStyle(scale: 0.97, pressedOpacity: 0.85)
    }
}

/// Haptics for actions triggered by a swipe rather than a tap: with no button to watch
/// depress, a small tap through the case is the only confirmation the gesture registered.
enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
