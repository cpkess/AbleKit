import ApplicationServices
import CoreGraphics
import Foundation

/// A macOS permission AbleKit needs in order to do its job.
public enum PermissionKind: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
    /// Required to read the interface semantically and to send synthetic input.
    case accessibility
    /// Required to see the screen.
    case screenRecording

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        }
    }

    /// Why AbleKit needs it, in the user's terms.
    ///
    /// Onboarding shows this rather than a generic "grant permission" prompt: these are two of the
    /// most powerful permissions on the system, and a user who is not told what they buy is right
    /// to refuse them.
    public var rationale: String {
        switch self {
        case .accessibility:
            """
            Lets AbleKit read the controls in an app — the buttons, fields and menus by name — \
            and operate them directly. This is what makes AbleKit press the Save button rather \
            than clicking a position and hoping.
            """
        case .screenRecording:
            """
            Lets AbleKit see what is on screen when an app exposes nothing readable. \
            Screenshots are analysed on this Mac and are never saved to disk or uploaded.
            """
        }
    }

    /// What AbleKit can still do without it.
    public var degradedBehaviour: String {
        switch self {
        case .accessibility:
            "Without it, AbleKit can open apps and files but cannot operate any interface."
        case .screenRecording:
            "Without it, AbleKit works from Accessibility information alone and cannot read apps that expose none."
        }
    }

    /// Whether a grant only takes effect once AbleKit has been restarted.
    ///
    /// Screen Recording is resolved per process, so an app that is already running keeps being
    /// refused until it is relaunched. Without saying so, the honest status AbleKit reports looks
    /// exactly like the permission not having been granted at all.
    public var requiresRelaunchAfterGranting: Bool {
        self == .screenRecording
    }

    /// The System Settings pane that grants it.
    public var settingsURL: URL? {
        switch self {
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .screenRecording:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }
}

/// Whether a permission has been granted.
public enum PermissionStatus: String, Sendable, Equatable, Codable {
    case granted
    case denied
    /// Not yet asked for.
    case notDetermined

    public var isGranted: Bool { self == .granted }
}

/// Reads and requests the permissions AbleKit depends on.
///
/// Behind a protocol so the agent's behaviour under a missing permission can be tested without
/// touching the real TCC database.
public protocol PermissionChecking: Sendable {
    func status(of permission: PermissionKind) -> PermissionStatus
    /// Asks macOS to prompt for the permission. Returns the status immediately afterwards, which
    /// is usually still ungranted: the system prompt is asynchronous and often requires a relaunch.
    func requestAccess(to permission: PermissionKind) async -> PermissionStatus
}

/// The real implementation, backed by the system APIs.
public struct SystemPermissionChecker: PermissionChecking {

    public init() {}

    public func status(of permission: PermissionKind) -> PermissionStatus {
        switch permission {
        case .accessibility:
            // Queried with an explicit no-prompt dictionary rather than `AXIsProcessTrusted()`, so
            // the answer is re-read from the system each time instead of being answered from
            // whatever the process last observed.
            let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .granted : .denied
        case .screenRecording:
            // Preflight checks without triggering the prompt or the capture indicator.
            //
            // This keeps returning false until the app is relaunched after the grant: the capture
            // entitlement is resolved once per process. `requiresRelaunchAfterGranting` exists so
            // onboarding can say that, rather than leaving the user clicking Re-check forever.
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
    }

    public func requestAccess(to permission: PermissionKind) async -> PermissionStatus {
        switch permission {
        case .accessibility:
            // Passing the prompt option shows the system's "open System Settings" alert once.
            // The key is spelled out rather than read from `kAXTrustedCheckOptionPrompt`, which is
            // imported as a mutable global and so is not usable under strict concurrency.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            // Triggers the system prompt; the grant only takes effect for a fresh launch.
            _ = CGRequestScreenCaptureAccess()
        }
        return status(of: permission)
    }
}

/// Tracks the live status of every permission, for onboarding and Settings.
@MainActor
@Observable
public final class PermissionManager {
    public private(set) var statuses: [PermissionKind: PermissionStatus] = [:]
    private let checker: any PermissionChecking

    public init(checker: any PermissionChecking = SystemPermissionChecker()) {
        self.checker = checker
        refresh()
    }

    /// Re-reads every permission. Called when the app becomes active, because the user grants
    /// permissions in System Settings and then comes back.
    public func refresh() {
        for permission in PermissionKind.allCases {
            statuses[permission] = checker.status(of: permission)
        }
    }

    public func status(of permission: PermissionKind) -> PermissionStatus {
        statuses[permission] ?? .notDetermined
    }

    public func isGranted(_ permission: PermissionKind) -> Bool {
        status(of: permission).isGranted
    }

    /// Whether AbleKit can do anything useful at all.
    public var hasMinimumPermissions: Bool {
        isGranted(.accessibility)
    }

    /// Permissions that are still missing.
    public var missing: [PermissionKind] {
        PermissionKind.allCases.filter { !isGranted($0) }
    }

    @discardableResult
    public func request(_ permission: PermissionKind) async -> PermissionStatus {
        let status = await checker.requestAccess(to: permission)
        statuses[permission] = status
        return status
    }
}
