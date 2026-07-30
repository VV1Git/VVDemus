import SwiftUI

/// Named `AppTab` rather than `Tab` because SwiftUI's own `Tab` is what builds each item of
/// the native tab bar. A module-local `Tab` shadows the imported one, so `Tab("Home", …)` in
/// `RootView` would resolve to this enum and fail to compile.
enum AppTab: Hashable {
    case home
    case search
    case library
}

/// Lets an action in one tab (e.g. "Go to Radio" from a Search result) switch to another
/// tab and push a destination onto that tab's own navigation stack.
@MainActor
final class NavigationCoordinator: ObservableObject {
    @Published var selectedTab: AppTab = .home
    @Published var homePath = NavigationPath()
}
