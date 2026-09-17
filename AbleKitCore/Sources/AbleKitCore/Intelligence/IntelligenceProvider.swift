import Foundation

/// Everything the planner is allowed to know when choosing the next step.
public struct AgentContext: Sendable {
    /// What the user asked for, verbatim.
    public let goal: String
    /// The desktop as it is right now.
    public let desktop: DesktopContext
    /// What has already been tried, and how it went.
    public let history: [StepRecord]
    /// Text produced by earlier steps — most importantly an AI bridge's answer — which later steps
    /// act on. This is how a Copilot response becomes input to an application.
    public let gatheredInformation: [GatheredInformation]
    /// Which step this is, and how many are left.
    public let stepIndex: Int
    public let stepLimit: Int

    public init(
        goal: String,
        desktop: DesktopContext,
        history: [StepRecord] = [],
        gatheredInformation: [GatheredInformation] = [],
        stepIndex: Int = 0,
        stepLimit: Int = TaskLimits.default.maximumSteps
    ) {
        self.goal = goal
        self.desktop = desktop
        self.history = history
        self.gatheredInformation = gatheredInformation
        self.stepIndex = stepIndex
        self.stepLimit = stepLimit
    }
}

/// A piece of information an earlier step produced.
public struct GatheredInformation: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Where it came from, e.g. "Copilot".
    public let source: String
    public let text: String
    public let collectedAt: Date

    public init(id: UUID = UUID(), source: String, text: String, collectedAt: Date = Date()) {
        self.id = id
        self.source = source
        self.text = text
        self.collectedAt = collectedAt
    }
}

/// The planner's decision about what to do next.
public struct PlannedStep: Sendable, Equatable {
    public let action: DesktopAction
    /// Why, in one sentence. Shown in the HUD and kept in the step history.
    public let rationale: String
    /// How sure the planner is, `0...1`. Low confidence on a consequential action is a reason to
    /// ask the user rather than to proceed.
    public let confidence: Double
    /// Where the step was actually reasoned — which may be this Mac even when Private Cloud Compute
    /// was requested, if the cloud could not be used.
    public let reasonedBy: ReasoningLocation

    public init(
        action: DesktopAction,
        rationale: String,
        confidence: Double = 1,
        reasonedBy: ReasoningLocation = .onDevice
    ) {
        self.action = action
        self.rationale = rationale
        self.confidence = min(max(confidence, 0), 1)
        self.reasonedBy = reasonedBy
    }
}

/// Whether an action achieved anything.
public enum VerificationOutcome: String, Sendable, Equatable, Codable {
    case succeeded
    case failed
    /// It genuinely cannot be told from what is observable.
    ///
    /// This is a real answer, not a hedge: reporting "I could not tell" and moving on is better
    /// than claiming a success that did not happen (brief §40.7).
    case inconclusive
}

public struct VerificationResult: Sendable, Equatable {
    public let outcome: VerificationOutcome
    /// What was observed that led to this conclusion.
    public let reason: String
    /// Whether retrying the same action is worth a step.
    public let shouldRetry: Bool

    public init(outcome: VerificationOutcome, reason: String, shouldRetry: Bool = false) {
        self.outcome = outcome
        self.reason = reason
        self.shouldRetry = shouldRetry
    }

    public static func succeeded(_ reason: String) -> VerificationResult {
        VerificationResult(outcome: .succeeded, reason: reason)
    }

    public static func failed(_ reason: String, shouldRetry: Bool = false) -> VerificationResult {
        VerificationResult(outcome: .failed, reason: reason, shouldRetry: shouldRetry)
    }

    public static func inconclusive(_ reason: String) -> VerificationResult {
        VerificationResult(outcome: .inconclusive, reason: reason)
    }
}

/// Why the planner could not produce a step.
public enum IntelligenceError: Error, Equatable, Sendable {
    /// Apple Intelligence is not available on this Mac, or is switched off.
    case unavailable(String)
    /// The model produced something that does not describe a usable action.
    case undecodableStep(String)
    /// The model's context window was exceeded even after trimming.
    case contextTooLarge
    case cancelled
    case underlying(String)
}

extension IntelligenceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unavailable(let detail): detail
        case .undecodableStep(let detail): "AbleKit could not turn that into an action: \(detail)"
        case .contextTooLarge: "There was too much on screen to reason about."
        case .cancelled: "Cancelled."
        case .underlying(let detail): detail
        }
    }
}

/// Whether local reasoning is usable, and why not when it is not.
public enum IntelligenceAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String, recoverySuggestion: String?)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// The reasoning layer, behind a protocol.
///
/// Nothing outside `Intelligence/` references a Foundation Models type. That boundary is what lets
/// the automation engine be tested against a scripted planner, and what would let a different
/// provider be added without touching the agent loop (brief §7).
public protocol IntelligenceProvider: Sendable {
    /// A short name for the debug interface and Settings.
    var name: String { get }

    /// Whether this provider can be used right now.
    var availability: IntelligenceAvailability { get async }

    /// Decides the single next step.
    ///
    /// Single-step by design: the desktop can change after every action, so a long speculative
    /// plan is mostly fiction by its third entry (brief §16).
    func planNextStep(goal: String, context: AgentContext) async throws -> PlannedStep

    /// Judges whether an action did what it was supposed to.
    func verify(
        action: DesktopAction,
        before: DesktopContext,
        after: DesktopContext
    ) async throws -> VerificationResult
}
