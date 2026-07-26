import SwiftUI

enum Tab: Hashable {
    case home
    case search
    case library
}

/// Lets an action in one tab (e.g. "Go to Radio" from a Search result) switch to another
/// tab and push a destination onto that tab's own navigation stack.
@MainActor
final class NavigationCoordinator: ObservableObject {
    @Published var selectedTab: Tab = .home
    @Published var homePath = NavigationPath()
}
