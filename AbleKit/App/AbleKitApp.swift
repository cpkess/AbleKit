import AbleKitCore
import AppKit
import SwiftUI

/// AbleKit: a small macOS utility that can see the desktop and operate it on your behalf.
///
/// The app is a menu-bar extra with no Dock icon and no main window (`LSUIElement`). What the user
/// interacts with is a Spotlight-style palette summoned by a shortcut, and a HUD while a task runs.
/// That shape is a deliberate answer to the brief's §21: AbleKit should feel like a utility that is
/// occasionally summoned, not an application that is opened and sat in front of.
@main
struct AbleKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra(isInserted: menuBarBinding) {
            MenuBarMenu()
                .environment(appDelegate.state)
        } label: {
            Image(systemName: appDelegate.state.isRunning ? "wand.and.sparkles" : "wand.and.rays")
        }

        Settings {
            SettingsView()
                .environment(appDelegate.state)
        }
    }

    /// The menu-bar icon can be hidden, but hiding it while a task is running would leave the user
    /// with no way to stop it — so the setting is overridden for as long as one is.
    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { appDelegate.state.settings.showsMenuBarIcon || appDelegate.state.isRunning },
            set: { appDelegate.state.settings.showsMenuBarIcon = $0 }
        )
    }
}
