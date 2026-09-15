import AppKit
import Foundation

/// Carries out the things macOS can do directly, with no interface driven at all.
///
/// This tier exists because of the brief's first principle. Opening Safari is one `NSWorkspace`
/// call; done through the interface it would be a Dock screenshot, an element search, a click, and
/// a verification — four chances to be wrong, in service of something the system will simply do.
/// Anything that can land here should.
public struct NativeCapability: Capability {
    public let kind = CapabilityKind.native

    private let locator: ApplicationLocator

    public init(locator: ApplicationLocator = ApplicationLocator()) {
        self.locator = locator
    }

    /// `NSWorkspace` is not `Sendable`, so the shared instance is reached for at each call site
    /// rather than stored on this `Sendable` capability.
    private var workspace: NSWorkspace { .shared }

    public func canHandle(_ action: DesktopAction) -> Bool {
        switch action {
        case .openApplication, .activateApplication, .nativeAction:
            true
        default:
            false
        }
    }

    public func execute(_ action: DesktopAction, context: DesktopContext?) async throws
        -> CapabilityOutcome
    {
        switch action {
        case .openApplication(let reference), .activateApplication(let reference):
            return try await open(reference)

        case .nativeAction(let operation):
            return try perform(operation)

        default:
            throw CapabilityError.noCapability(action.summary)
        }
    }

    // MARK: - Applications

    private func open(_ reference: ApplicationReference) async throws -> CapabilityOutcome {
        // Already running and merely in the background? Bringing it forward is cheaper than
        // launching, and avoids opening a second untitled window in apps that do that.
        if let running = locator.runningApplication(matching: reference) {
            running.activate()
            return .success("\(running.localizedName ?? reference.displayName) is now frontmost.")
        }

        guard let url = locator.applicationURL(for: reference) else {
            throw CapabilityError.applicationNotFound(reference.displayName)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            let application = try await workspace.openApplication(at: url, configuration: configuration)
            return .success("Opened \(application.localizedName ?? reference.displayName).")
        } catch {
            throw CapabilityError.executionFailed(
                "Could not open \(reference.displayName): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Other native operations

    private func perform(_ operation: NativeOperation) throws -> CapabilityOutcome {
        switch operation {
        case .openURL(let string):
            guard let url = URL(string: string) else {
                throw CapabilityError.executionFailed("\(string) is not a valid address.")
            }
            workspace.open(url)
            return .success("Opened \(string).")

        case .revealInFinder(let path):
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CapabilityError.executionFailed("\(url.lastPathComponent) does not exist.")
            }
            workspace.activateFileViewerSelecting([url])
            return .success("Revealed \(url.lastPathComponent) in Finder.")

        case .openSystemSettings(let pane):
            let string = pane.map { "x-apple.systempreferences:\($0)" } ?? "x-apple.systempreferences:"
            guard let url = URL(string: string) else {
                throw CapabilityError.executionFailed("That is not a System Settings pane.")
            }
            workspace.open(url)
            return .success("Opened System Settings.")

        case .setClipboard(let text):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .success("Copied to the clipboard.")
        }
    }
}

/// Finds applications by bundle identifier or by the name a person would say.
///
/// A planner writes "System Settings" or "Copilot", not a bundle identifier, so name resolution is
/// not a nicety — it is the normal case.
public struct ApplicationLocator: Sendable {

    /// Names whose bundle identifier cannot be guessed from the name.
    ///
    /// System Settings is the one that matters most: its bundle is still called
    /// `com.apple.systempreferences`, a decade after the app stopped being called that.
    static let knownBundleIdentifiers: [String: String] = [
        "system settings": "com.apple.systempreferences",
        "system preferences": "com.apple.systempreferences",
        "finder": "com.apple.finder",
        "safari": "com.apple.Safari",
        "mail": "com.apple.mail",
        "calendar": "com.apple.iCal",
        "notes": "com.apple.Notes",
        "reminders": "com.apple.reminders",
        "messages": "com.apple.MobileSMS",
        "terminal": "com.apple.Terminal",
        "preview": "com.apple.Preview",
        "textedit": "com.apple.TextEdit",
        "copilot": "com.microsoft.copilot",
        "microsoft copilot": "com.microsoft.copilot",
    ]

    private static let searchDirectories = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    public init() {}

    /// The bundle identifier for a reference, resolving a name where possible.
    public func bundleIdentifier(for reference: ApplicationReference) -> String? {
        if let identifier = reference.bundleIdentifier, !identifier.isEmpty { return identifier }
        guard let name = reference.name?.lowercased().trimmed else { return nil }
        return Self.knownBundleIdentifiers[name]
    }

    /// The application bundle for a reference.
    public func applicationURL(for reference: ApplicationReference) -> URL? {
        if let identifier = bundleIdentifier(for: reference),
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        {
            return url
        }
        guard let name = reference.name?.trimmed, !name.isEmpty else { return nil }
        return Self.findByName(name)
    }

    /// A running instance matching the reference, if there is one.
    public func runningApplication(matching reference: ApplicationReference) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }

        if let identifier = bundleIdentifier(for: reference) {
            if let match = running.first(where: {
                $0.bundleIdentifier?.caseInsensitiveCompare(identifier) == .orderedSame
            }) {
                return match
            }
        }
        guard let name = reference.name?.lowercased().trimmed, !name.isEmpty else { return nil }
        return running.first { application in
            guard let localized = application.localizedName?.lowercased() else { return false }
            return localized == name || localized.contains(name)
        }
    }

    /// Searches the standard application directories for a bundle with this name.
    private static func findByName(_ name: String) -> URL? {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        let manager = FileManager.default

        for directory in searchDirectories {
            guard
                let entries = try? manager.contentsOfDirectory(
                    at: URL(fileURLWithPath: directory),
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            else { continue }

            // An exact name match is preferred over a prefix, so that "Mail" does not open
            // "Mailbox Utility" when both are installed.
            let applications = entries.filter { $0.pathExtension == "app" }
            if let exact = applications.first(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased() == wanted
            }) {
                return exact
            }
            if let partial = applications.first(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(wanted)
            }) {
                return partial
            }
        }
        return nil
    }
}
