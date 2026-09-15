import Foundation
import ServiceManagement
import os

/// Registers AbleKit to start when the user logs in.
///
/// `SMAppService.mainApp` is the modern replacement for the old login-items API: the registration
/// belongs to the app bundle itself, so it survives being moved and disappears when the app is
/// deleted, rather than leaving an orphaned entry behind in System Settings.
enum LoginItem {
    private static let log = Logger(subsystem: "com.ablekit.AbleKit", category: "LoginItem")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration fails for an app that is not in /Applications, which is the normal case
            // while developing. Worth noting, not worth interrupting anyone over.
            log.notice("Could not change the login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
