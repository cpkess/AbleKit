import AbleKitCore
import AppKit
import SwiftUI

/// Owns the pieces of AbleKit that SwiftUI scenes cannot: the global shortcut, the floating
/// palette, the HUD panel, and the first-run onboarding window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let state = AppState()

    private var palette: PaletteWindowController?
    private var hud: HUDWindowController?
    private var onboarding: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerShortcut()

        Task {
            await state.refreshEnvironment()
            // Onboarding is shown only when something is actually missing. An app that greets a
            // returning user with a setup screen has stopped respecting their time.
            if !state.permissions.hasMinimumPermissions {
                showOnboarding()
            }
        }

        // Permissions are granted in System Settings, so the moment to re-read them is when the
        // user comes back to AbleKit.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in await self.state.refreshEnvironment() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A task left running with nothing watching it would keep operating the user's Mac after
        // they have quit the app that was doing it.
        state.cancel()
        HotKeyCenter.shared.unregister()
    }

    // MARK: - Windows

    func registerShortcut() {
        let registered = HotKeyCenter.shared.register(state.settings.shortcut) { [weak self] in
            self?.togglePalette()
        }
        state.shortcutRegistrationFailed = !registered
    }

    func togglePalette() {
        if palette?.isVisible == true {
            palette?.hide()
        } else {
            showPalette()
        }
    }

    func showPalette() {
        // Warmed now rather than when the task starts: by the time the user has finished typing,
        // the model is usually already resident.
        state.prewarmIntelligence()

        let controller = palette ?? PaletteWindowController(state: state, delegate: self)
        palette = controller
        controller.show()
    }

    func hidePalette() {
        palette?.hide()
    }

    func showHUD() {
        let controller = hud ?? HUDWindowController(state: state)
        hud = controller
        controller.show()
    }

    func showOnboarding() {
        if let onboarding {
            onboarding.showWindow(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to AbleKit"
        window.titlebarAppearsTransparent = true
        window.center()
        window.contentView = NSHostingView(
            rootView: OnboardingView().environment(state)
        )
        let controller = NSWindowController(window: window)
        onboarding = controller
        controller.showWindow(nil)
        NSApp.activate()
    }

    func showSettings() {
        NSApp.activate()
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}
