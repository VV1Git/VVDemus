import Foundation

/// Navigation targets reachable from both Home shortcuts and the Library tab.
enum LibraryDestination: Hashable {
    case liked
    case playlist(UUID)
    case radio(Track)
    case daylist
}
