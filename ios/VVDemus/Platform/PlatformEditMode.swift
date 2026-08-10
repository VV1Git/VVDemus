import SwiftUI

#if os(iOS)
typealias PlatformEditMode = EditMode
#else
/// Stand-in for `EditMode`, which is iOS-only.
///
/// macOS needs no such mode: a `List` row with `.onMove` is draggable whenever the list is on
/// screen, so reordering is always available rather than something to switch into. This exists
/// only so the shared screens can keep one state property and one binding across both
/// platforms — on the Mac the value is written and read, and simply never gates anything.
enum PlatformEditMode {
    case inactive
    case active

    var isEditing: Bool { self == .active }
}
#endif

extension View {
    /// Publishes the edit-mode binding to the enclosing list. A no-op on macOS, which has no
    /// `\.editMode` environment value to publish it to.
    func platformEditMode(_ binding: Binding<PlatformEditMode>) -> some View {
        #if os(iOS)
        return environment(\.editMode, binding)
        #else
        return self
        #endif
    }
}
