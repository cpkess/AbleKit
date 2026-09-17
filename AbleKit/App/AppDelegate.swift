import AbleKitCore
import AppKit
import SwiftUI
import os

/// Owns the pieces of AbleKit that SwiftUI scenes cannot: the global shortcut, the floating
/// palette, the HUD panel, and the first-run onboarding window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The one instance, for views that need to open a window.
    ///
    /// `NSApplication.shared.delegate` cannot be used for this. Under `@NSApplicationDelegateAdaptor`
    /// it is SwiftUI's own forwarding object, not this class, so a cast to `AppDelegate` quietly
    /// yields `nil` — which is how every menu item in 0.1.0 ended up doing nothing at all.
    private(set) static weak var shared: AppDelegate?

    let state = AppState()

    private var palette: PaletteWindowController?
    private var hud: HUDWindowController?
    private var onboarding: NSWindow?
    private var settings: NSWindow?
    private let log = Logger(subsystem: "com.ablekit.AbleKit", category: "App")
    private lazy var commands = CommandListener(delegate: self)

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerShortcut()
        commands.start()

        Task {
            await state.refreshEnvironment()
            // Onboarding is shown only when something is actually missing. An app that greets a
            // returning user with a setup screen has stopped respecting their time.
            state.logStatus()
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
        let shortcut = state.settings.shortcut
        let registered = HotKeyCenter.shared.register(shortcut) { [weak self] in
            self?.log.info("Shortcut pressed")
            self?.togglePalette()
        }
        state.shortcutRegistrationFailed = !registered
        if registered {
            log.notice("Shortcut \(shortcut.displayString, privacy: .public) registered")
        } else {
            log.error("Shortcut \(shortcut.displayString, privacy: .public) is taken by another app")
        }
    }

    func togglePalette() {
        if palette?.isVisible == true {
            palette?.hide()
        } else {
            showPalette()
        }
    }

    /// Opens the palette with a Skill already chosen, so the user only has to fill in its values.
    func showPalette(preselecting skill: Skill) {
        state.pendingSkillLaunch = skill
        showPalette()
    }

    func showPalette() {
        // Warmed now rather than when the task starts: by the time the user has finished typing,
        // the model is usually already resident.
        state.prewarmIntelligence()

        let controller = palette ?? PaletteWindowController(state: state, delegate: self)
        palette = controller
        controller.show()
        log.info("Palette shown")
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
        let window = onboarding ?? makeWindow(
            title: "Welcome to AbleKit",
            size: NSSize(width: 560, height: 600),
            content: OnboardingView(onDone: { [weak self] in self?.onboarding?.close() })
        )
        onboarding = window
        present(window)
        log.info("Onboarding shown")
    }

    func showSettings() {
        let window = settings ?? makeWindow(
            title: "AbleKit Settings",
            size: NSSize(width: 560, height: 460),
            content: SettingsView()
        )
        settings = window
        present(window)
        log.info("Settings shown")
    }

    /// A window for SwiftUI content that survives being closed.
    ///
    /// Settings are hosted here rather than in a SwiftUI `Settings` scene because an accessory app
    /// has no reliable way to open that scene from AppKit: the old `showSettingsWindow:` action is
    /// ignored on current macOS, and `openSettings` is only reachable from inside a view.
    private func makeWindow(title: String, size: NSSize, content: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        // Without this, AppKit frees the window when it is closed, and the next attempt to show it
        // does nothing — the reason setup could not be reopened.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.environment(state))
        window.center()
        return window
    }

    /// Brings a window to the front of an app that has no Dock icon and is usually not active.
    private func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
