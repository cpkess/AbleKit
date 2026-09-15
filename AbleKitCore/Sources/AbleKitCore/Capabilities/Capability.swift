import Foundation

/// The tiers of capability AbleKit can act through, most deterministic first.
///
/// The ordering is the whole point. `CapabilityRouter` always routes an action to the earliest
/// tier that can carry it out, which is how "prefer native over UI automation, and Accessibility
/// over coordinates" becomes a property of the system rather than a habit.
public enum CapabilityKind: String, Sendable, Equatable, Codable, CaseIterable, Comparable {
    /// Native macOS APIs — `NSWorkspace`, `FileManager`, URL handling. No interface is driven.
    case native
    /// Semantic interaction through the Accessibility APIs: `AXPress` on a named button.
    case accessibility
    /// Synthetic input at a screen position, driven by visual understanding. The last resort,
    /// used when an interface exposes nothing semantic to aim at.
    case visual
    /// Delegating a question to another AI application.
    case bridge
    /// Handing control back to the user for a confirmation or an answer.
    case user
    /// Agent bookkeeping that touches nothing: waiting, completing, failing.
    case control

    /// Lower is more deterministic, and therefore preferred.
    private var preferenceRank: Int {
        switch self {
        case .native: 0
        case .accessibility: 1
        case .visual: 2
        case .bridge: 3
        case .user: 4
        case .control: 5
        }
    }

    public static func < (lhs: CapabilityKind, rhs: CapabilityKind) -> Bool {
        lhs.preferenceRank < rhs.preferenceRank
    }

    public var displayName: String {
        switch self {
        case .native: "Native"
        case .accessibility: "Accessibility"
        case .visual: "Visual"
        case .bridge: "AI bridge"
        case .user: "You"
        case .control: "Agent"
        }
    }
}

/// What executing an action produced.
public struct CapabilityOutcome: Sendable, Equatable {
    /// Whether the capability believes the action was carried out.
    ///
    /// This is *not* verification: a click that dispatched successfully still says nothing about
    /// whether the interface did anything. `Verifier` answers that separately.
    public let succeeded: Bool
    /// Detail for the step history and debug interface.
    public let detail: String?
    /// Text the action produced, such as an AI bridge's answer, for later steps to use.
    public let producedText: String?

    public init(succeeded: Bool, detail: String? = nil, producedText: String? = nil) {
        self.succeeded = succeeded
        self.detail = detail
        self.producedText = producedText
    }

    public static let success = CapabilityOutcome(succeeded: true)

    public static func success(_ detail: String) -> CapabilityOutcome {
        CapabilityOutcome(succeeded: true, detail: detail)
    }
}

/// Something that can carry out desktop actions.
public protocol Capability: Sendable {
    /// Which tier this capability belongs to.
    var kind: CapabilityKind { get }

    /// Whether this capability can carry out the action *right now*.
    ///
    /// A capability may decline an action it normally handles — for example the Accessibility
    /// capability declines an element that does not advertise the action it would need.
    func canHandle(_ action: DesktopAction) -> Bool

    /// Carries out the action.
    func execute(_ action: DesktopAction, context: DesktopContext?) async throws -> CapabilityOutcome
}

/// Why an action could not be carried out.
public enum CapabilityError: Error, Equatable, Sendable {
    /// No capability accepted the action.
    case noCapability(String)
    /// The capability tried and the system refused.
    case executionFailed(String)
    /// A required macOS permission has not been granted.
    case permissionRequired(PermissionKind)
    /// The named application is not installed.
    case applicationNotFound(String)
    /// The user cancelled mid-action.
    case cancelled
}

extension CapabilityError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noCapability(let action): "Nothing in AbleKit can \(action)."
        case .executionFailed(let reason): reason
        case .permissionRequired(let permission):
            "\(permission.displayName) permission is needed for this."
        case .applicationNotFound(let name): "\(name) is not installed."
        case .cancelled: "Cancelled."
        }
    }
}
