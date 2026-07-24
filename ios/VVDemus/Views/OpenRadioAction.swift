import SwiftUI

/// Lets any track row push a RadioDetailView onto whichever NavigationStack it's
/// actually inside (Home's or Library's), without every nested view needing its own
/// copy of the navigation path.
private struct OpenRadioKey: EnvironmentKey {
    static let defaultValue: (Track) -> Void = { _ in }
}

extension EnvironmentValues {
    var openRadio: (Track) -> Void {
        get { self[OpenRadioKey.self] }
        set { self[OpenRadioKey.self] = newValue }
    }
}
