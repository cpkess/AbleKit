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
        case "test-cloud":
            // Sends a made-up request only; nothing from the screen.
            Task { await delegate.state.testCloudAccess() }
        case "reasoning":
            // Choosing the cloud changes what leaves the Mac, so from the terminal it is a
            // development convenience only. Release builds require the confirmation in Settings.
            #if DEBUG
                delegate.state.settings.reasoningLocation =
                    argument == "cloud" ? .privateCloudCompute : .onDevice
                log.notice("Reasoning set to \(delegate.state.settings.reasoningLocation.rawValue, privacy: .public)")
            #else
                log.error("reasoning can only be changed in Settings in release builds")
            #endif
        case "check-updates":
            delegate.state.updates.checkForUpdates()
        case "probe-control":
            // Whether a control or piece of text with this label is on screen, for checking a
            // task's result from outside it.
            Task { await delegate.state.logProbe(findingControl: argument) }
        case "probe":
            // What is in front right now, read independently of any task — used by the evaluation
            // suite to check what a task actually did rather than what it claimed.
            Task { await delegate.state.logProbe() }
        case "status":
            delegate.state.logStatus()
        case "diagnostics":
            // Only changes how much AbleKit writes about its own actions.
            delegate.state.settings.diagnosticLoggingEnabled = (argument == "on")
            log.notice("Diagnostic logging \(argument == "on" ? "on" : "off", privacy: .public)")
        case "stop":
            delegate.state.cancel()
            log.notice("Stopped by command")
        case "type":
            // Types into the palette without submitting, for reproducing layout problems.
            #if DEBUG
                Task { await delegate.simulateTypingInPalette(argument) }
            #else
                log.error("type is only available in Debug builds")
            #endif
        case "plan":
            // Plans one step for the current screen and logs it, without carrying it out.
            #if DEBUG
                Task { await delegate.state.logPlan(goal: argument) }
            #else
                log.error("plan is only available in Debug builds")
            #endif
        case "prompt":
            // Prints the planning prompt for the current screen, acting on nothing. The fastest way
            // to see what the model is actually being shown.
            #if DEBUG
                Task { await delegate.state.logPlanningPrompt(goal: argument) }
            #else
                log.error("prompt is only available in Debug builds")
            #endif
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
