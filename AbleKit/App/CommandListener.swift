import AbleKitCore
import AppKit
import Foundation
import os

/// Lets AbleKit be driven from a terminal: `make palette`, `make settings`, `make ask GOAL=...`.
///
/// Commands arrive as distributed notifications, which a web page cannot send — unlike a URL
/// scheme, where any link could start a task.
///
/// Any *local* process can post one, though, and that matters more than it looks: a program without
/// Accessibility permission could ask AbleKit, which has it, to act on its behalf. So the commands
/// that only open AbleKit's own windows are always accepted, while `ask` — the one that operates
/// other applications — exists only in Debug builds, and still goes through the full safety policy,
/// including confirmation in the task window for anything consequential.
@MainActor
final class CommandListener {
    static let notificationName = Notification.Name("com.ablekit.AbleKit.command")

    private weak var delegate: AppDelegate?
    private let log = Logger(subsystem: "com.ablekit.AbleKit", category: "Command")
    private var observer: NSObjectProtocol?

    init(delegate: AppDelegate) {
        self.delegate = delegate
    }

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let command = notification.object as? String ?? ""
            MainActor.assumeIsolated { self?.handle(command) }
        }
    }

    private func handle(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let (verb, argument) = Self.split(trimmed)
        guard let delegate else { return }

        switch verb {
        case "palette":
            delegate.showPalette()
        case "settings":
            delegate.showSettings()
        case "setup":
            delegate.showOnboarding()
        case "status":
            delegate.state.logStatus()
        case "diagnostics":
            // Only changes how much AbleKit writes about its own actions.
            delegate.state.settings.diagnosticLoggingEnabled = (argument == "on")
            log.notice("Diagnostic logging \(argument == "on" ? "on" : "off", privacy: .public)")
        case "stop":
            delegate.state.cancel()
            log.notice("Stopped by command")
        case "ask":
            #if DEBUG
                guard !argument.isEmpty else {
                    log.error("ask needs a goal")
                    return
                }
                delegate.state.start(goal: argument)
                delegate.showHUD()
            #else
                log.error("ask is only available in Debug builds")
            #endif
        default:
            log.error("Unknown command \(verb, privacy: .public)")
        }
    }

    static func split(_ command: String) -> (verb: String, argument: String) {
        guard let space = command.firstIndex(of: " ") else { return (command.lowercased(), "") }
        return (
            String(command[..<space]).lowercased(),
            String(command[command.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        )
    }
}
