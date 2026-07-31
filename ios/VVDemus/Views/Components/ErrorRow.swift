import SwiftUI

/// The failure state for a whole screen's content: a search that never landed, a shelf
/// that couldn't load. `ContentUnavailableView` is the system's own treatment, so it
/// stays centred, scales with Dynamic Type and reads as part of iOS rather than as a
/// green banner we drew ourselves.
struct ErrorRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't Load", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}
