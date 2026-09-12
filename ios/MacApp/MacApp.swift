import AVFoundation
import SwiftUI

@main
struct MacApp: App {
    init() {
        // No `AVAudioSession` here, and nothing standing in for it: a Mac app does not
        // negotiate for the output route, so there is no category to set and no session to
        // activate. `SystemAudioSession` is a no-op on this platform for the same reason.
        //
        // No `beginReceivingRemoteControlEvents` either — that is a `UIApplication` call.
        // `MPRemoteCommandCenter` alone is what puts this app in Now Playing and wires the
        // keyboard's media keys to it, and `PlayerService` already registers its handlers
        // through `SystemRemoteCommandCenter`.
        UserDefaults.standard.register(defaults: [LocalControlServer.defaultsKey: true])
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1100, height: 720)
        .commands { MiniPlayerCommands() }

        // A `Window` rather than a `WindowGroup`: there is one session, so there is one corner
        // player, and a group would open a second empty copy on every ⌘M.
        //
        // `.hiddenTitleBar` is what leaves the close button and the resize grip without a title
        // bar above them. Everything else the window needs — floating level, Spaces behaviour,
        // remembered frame — is `NSWindow`, and lives in `MiniPlayerWindowConfigurator`.
        Window("Miniplayer", id: MiniPlayerPresence.windowId) {
            // No `preferredColorScheme(.dark)`, unlike the main window, and that is the entire
            // mechanism behind black text on a white desktop. Glass and label colours resolve
            // from the appearance; a window pinned dark stays a dark sheet with white labels no
            // matter how bright the screen behind it is. The cost is honest: in Light Mode this
            // panel is light while the main window stays dark.
            MacMiniPlayerView(player: PlayerService.shared)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 300, height: 372)
    }
}

/// Window ▸ Miniplayer.
///
/// Its own `Commands` type rather than an inline closure so it can hold the presence object:
/// the item has to say *Hide* once the window is up, and a menu that offers to open what is
/// already open is how you end up with someone pressing ⌘M twice to no effect.
private struct MiniPlayerCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var presence = MiniPlayerPresence.shared

    var body: some Commands {
        CommandGroup(after: .windowList) {
            Button(presence.isOpen ? "Hide Miniplayer" : "Miniplayer") {
                if presence.isOpen {
                    dismissWindow(id: MiniPlayerPresence.windowId)
                } else {
                    openWindow(id: MiniPlayerPresence.windowId)
                }
            }
            // ⇧⌘M rather than ⌘M: AppKit adds Minimize to this menu itself and gives it ⌘M,
            // and two items in one menu claiming the same shortcut is resolved by whichever the
            // menu happens to find first — so taking it would have made Minimize unreliable
            // rather than merely unavailable.
            .keyboardShortcut("m", modifiers: [.command, .shift])
        }
    }
}
