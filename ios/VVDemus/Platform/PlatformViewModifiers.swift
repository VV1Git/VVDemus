import SwiftUI

/// The handful of SwiftUI modifiers the shared screens use that exist on only one platform.
///
/// Each is a named intent rather than a raw `#if` at the call site, so a screen reads the same
/// on both platforms and there is one place to change if a macOS equivalent ever arrives.
extension View {
    /// A title that stays small, so a detail screen doesn't give a third of the phone to its
    /// own name. macOS has no navigation bar to size — a window titles itself.
    func compactNavigationTitle() -> some View {
        #if os(iOS)
        return navigationBarTitleDisplayMode(.inline)
        #else
        return self
        #endif
    }

    /// The large, scroll-collapsing title used by top-level screens on the phone.
    func prominentNavigationTitle() -> some View {
        #if os(iOS)
        return navigationBarTitleDisplayMode(.large)
        #else
        return self
        #endif
    }

    /// Only meaningful against a software keyboard that covers the content. A Mac keyboard
    /// covers nothing, so there is nothing to dismiss.
    func dismissesKeyboardOnScroll() -> some View {
        #if os(iOS)
        return scrollDismissesKeyboard(.immediately)
        #else
        return self
        #endif
    }

    /// Settings-shaped list. `.insetGrouped` is iOS-only; `.inset` is what the same grouped
    /// look is called on macOS.
    func settingsListStyle() -> some View {
        #if os(iOS)
        return listStyle(.insetGrouped)
        #else
        return listStyle(.inset)
        #endif
    }
}

/// The `topBar*` placements name a navigation bar, which is an iOS control — they are
/// unavailable on macOS, where the same items belong in the window's toolbar.
///
/// Resolved per platform rather than by switching everything to the placements that happen to
/// exist on both: `.primaryAction` and `.navigation` are what a Mac toolbar wants, and keeping
/// iOS on its own names means the phone's toolbars are untouched by the port.
extension ToolbarItemPlacement {
    /// Actions at the trailing end — the usual home for a screen's own controls.
    static var trailingActions: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarTrailing
        #else
        return .primaryAction
        #endif
    }

    /// Actions at the leading end, alongside the back affordance.
    static var leadingActions: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarLeading
        #else
        return .navigation
        #endif
    }
}
