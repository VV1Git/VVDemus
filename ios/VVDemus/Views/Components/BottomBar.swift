import SwiftUI

/// The one place the floating bottom bar's geometry is decided.
///
/// Both the bar and every scrolling view that has to stay clear of it need these numbers,
/// and they used to be spread across `RootView` (a mini-player height plus a hardcoded
/// 49/32pt tab bar) and a couple of views with their own bottom padding that agreed with
/// neither. Floating the bar raises the stakes: nothing is pinned to the screen edge any
/// more, so this inset is the only thing keeping the last row of a list reachable.
enum BottomBar {
    /// Height of the tab bar slab itself, shadow excluded.
    static let tabBarHeight: CGFloat = 54
    static let miniPlayerHeight: CGFloat = 56
    /// Between the two stacked slabs, and between the bar and the safe-area edge.
    static let gap: CGFloat = 8
    /// Inset from the side edges — the gap that makes the bar read as floating rather than
    /// as a docked bar with rounded corners.
    static let horizontalInset: CGFloat = 14
    static let cornerRadius: CGFloat = 22

    /// Room a scrolling view must leave below its content.
    ///
    /// Counts the mini player whether or not anything is playing. An inset that appeared
    /// with playback would shove every list up under the user's finger the instant a track
    /// started — the reason the original was unconditional too.
    static var contentInset: CGFloat {
        miniPlayerHeight + gap + tabBarHeight + gap
    }
}

/// The app's own tab bar, floating clear of the bottom edge as a slab of glass.
///
/// Custom rather than the system bar: `TabView`'s is pinned edge to edge and its background
/// is not something you can inset, round or lift, so "floating" isn't reachable by styling
/// it. The system bar is hidden instead and this stands in for it, while selection still
/// drives the real `TabView` — so each tab keeps its own navigation stack and its scroll
/// position across switches, which a hand-rolled content switcher would have thrown away.
struct FloatingTabBar: View {
    @Binding var selection: Tab

    /// Drives the selected pill's slide from one item to the next.
    @Namespace private var indicator

    private struct Item: Identifiable {
        let tab: Tab
        let title: String
        let icon: String
        let selectedIcon: String
        var id: Tab { tab }
    }

    private static let items: [Item] = [
        .init(tab: .home, title: "Home", icon: "house", selectedIcon: "house.fill"),
        .init(tab: .search, title: "Search", icon: "magnifyingglass", selectedIcon: "magnifyingglass"),
        .init(tab: .library, title: "Library", icon: "books.vertical", selectedIcon: "books.vertical.fill"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.items) { item in
                button(for: item)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: BottomBar.tabBarHeight)
        .glassSurface(in: Capsule(style: .continuous), elevation: .floating)
        .animation(.spring(response: 0.34, dampingFraction: 0.74), value: selection)
    }

    private func button(for item: Item) -> some View {
        let isSelected = selection == item.tab
        return Button {
            // Re-tapping the current tab is a no-op rather than a re-selection: it would
            // otherwise fire the haptic and re-run the pill animation for nothing.
            guard !isSelected else { return }
            Haptics.impact(.light)
            selection = item.tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: isSelected ? item.selectedIcon : item.icon)
                    .font(.system(size: 17, weight: .semibold))
                Text(item.title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
            .frame(maxWidth: .infinity)
            // Kept clear of the bar's own rim — at 7 the pill all but touched it, which read
            // as a misaligned inner border rather than a selection.
            .padding(.vertical, 4)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(Theme.accent.opacity(0.16))
                        .matchedGeometryEffect(id: "selected-tab", in: indicator)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        // Spoken as "selected" rather than only shown in green: the pill and the tint are
        // both colour-only signals, which VoiceOver and anyone who can't distinguish the
        // green get nothing from.
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
