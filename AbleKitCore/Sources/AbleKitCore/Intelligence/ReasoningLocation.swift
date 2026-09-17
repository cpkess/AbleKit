import Foundation
import Synchronization

/// Where AbleKit's reasoning runs.
///
/// On-device is the default and the brief's requirement: nothing about the desktop leaves the Mac.
/// Private Cloud Compute is Apple's larger model running on Apple's privacy-hardened servers, and
/// is strictly opt-in, because using it means a text description of the screen is sent off the
/// machine to be reasoned over.
public enum ReasoningLocation: String, Sendable, Codable, CaseIterable {
    case onDevice
    case privateCloudCompute

    public var displayName: String {
        switch self {
        case .onDevice: "On this Mac"
        case .privateCloudCompute: "Private Cloud Compute"
        }
    }
}

/// Whether Private Cloud Compute can be used right now, and why not when it cannot.
public enum CloudReasoningStatus: Sendable, Equatable {
    case available
    /// This version of macOS has no Private Cloud Compute model.
    case unsupportedSystem
    case deviceNotEligible
    case systemNotReady
    /// The usage quota is used up until the given date.
    case quotaReached(resetDate: Date?)
    /// Apple has not granted this app access.
    ///
    /// Private Cloud Compute requires a managed entitlement that each developer applies for. Without
    /// it the service refuses every request. There is no way to ask in advance, so this is learned
    /// from the first refusal and remembered for the rest of the session.
    case accessNotGranted

    public var isAvailable: Bool { self == .available }

    public var explanation: String {
        switch self {
        case .available:
            "Ready."
        case .unsupportedSystem:
            "Requires macOS 27 or later."
        case .deviceNotEligible:
            "This Mac is not eligible for Private Cloud Compute."
        case .systemNotReady:
            "Private Cloud Compute is not ready yet. Check that Apple Intelligence is on and you are online."
        case .quotaReached(let resetDate):
            if let resetDate {
                "The usage limit is reached until \(resetDate.formatted(date: .abbreviated, time: .shortened))."
            } else {
                "The usage limit is reached for now."
            }
        case .accessNotGranted:
            "Private Cloud Compute refused this app. Apple requires each developer to be approved before an app can use it."
        }
    }
}

/// Remembers, for the life of the process, that Private Cloud Compute refused this app.
///
/// Without this every step would first try the cloud, wait for the refusal, and only then fall back —
/// doubling the time of every step for a user who opted in before access was granted.
public enum CloudAccessMemory {
    private static let denied = Mutex(false)

    public static var isDenied: Bool {
        denied.withLock { $0 }
    }

    public static func recordDenied() {
        denied.withLock { $0 = true }
    }

    /// Forgets a refusal, so the next request tries again — used by the Settings test button.
    public static func reset() {
        denied.withLock { $0 = false }
    }

    /// Whether an error is the refusal an app without the entitlement receives.
    ///
    /// Observed on macOS 27 as a `LanguageModelError` wrapping ModelManagerServices error 1046. The
    /// match is deliberately this narrow: treating ordinary failures as "no access" would switch
    /// cloud reasoning off for a whole session over a network hiccup.
    public static func isAccessDenied(_ error: any Error) -> Bool {
        var pending: [NSError] = [error as NSError]
        while let current = pending.popLast() {
            if current.domain.hasSuffix("ModelManagerError"), current.code == 1046 { return true }
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                pending.append(underlying)
            }
            if let multiple = current.userInfo["NSMultipleUnderlyingErrorsKey"] as? [NSError] {
                pending.append(contentsOf: multiple)
            }
        }
        return false
    }
}
