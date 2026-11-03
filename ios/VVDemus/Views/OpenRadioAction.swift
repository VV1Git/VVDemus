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

/// The same trick for the lyrics screen, and it lives beside `openRadio` rather than in a file
/// of its own so the two stay installed together: every place that writes one has to write the
/// other, and a missing pair is easier to spot on one screen than across two.
private struct OpenLyricsKey: EnvironmentKey {
    static let defaultValue: (Track) -> Void = { _ in }
}

extension EnvironmentValues {
    var openLyrics: (Track) -> Void {
        get { self[OpenLyricsKey.self] }
        set { self[OpenLyricsKey.self] = newValue }
    }
}
