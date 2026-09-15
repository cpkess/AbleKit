import Foundation

/// How much weight an action carries.
///
/// The three classes come straight from the brief (§18). The point of naming them explicitly —
/// rather than scattering `if` statements through the executor — is that the *reason* an action
/// needed confirmation can be shown to the user and written to the step history.
public enum ActionClassification: String, Sendable, Equatable, Codable, CaseIterable {
    /// Reversible, low-stakes, and safe to perform without interrupting the user.
    case routine
    /// Has an effect outside the machine, destroys data, or is otherwise hard to undo.
    case consequential
    /// AbleKit will not perform this autonomously at all.
    case restricted
}

/// What the policy decided to do with a proposed action.
public enum PolicyDecision: Sendable, Equatable {
    /// Execute it.
    case allow
    /// Ask the user first, showing this reason.
    case confirm(reason: String)
    /// Refuse, and tell the user why.
    case block(reason: String)

    public var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }
}

/// The result of classifying an action, including why.
public struct ClassificationResult: Sendable, Equatable {
    public let classification: ActionClassification
    /// A user-facing explanation, e.g. "This looks like it sends something."
    public let reason: String?

    public init(_ classification: ActionClassification, reason: String? = nil) {
        self.classification = classification
        self.reason = reason
    }

    public static let routine = ClassificationResult(.routine)
}
