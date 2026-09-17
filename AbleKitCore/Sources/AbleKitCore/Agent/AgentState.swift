import Foundation

/// Where a task currently is in its lifecycle.
///
/// Phases are explicit (brief §17) so the HUD, the debug interface, and the step history all
/// describe the same thing, and so "can the user stop right now?" has a definite answer.
public enum AgentPhase: String, Sendable, Equatable, Codable, CaseIterable {
    case idle
    case collectingContext
    case planning
    case acting
    case waiting
    case verifying
    case paused
    case waitingForUser
    case completed
    case failed
    case cancelled

    /// Whether the task has stopped for good.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }

    /// Whether the agent is doing something the user might want to interrupt.
    public var isRunning: Bool {
        switch self {
        case .collectingContext, .planning, .acting, .waiting, .verifying: true
        default: false
        }
    }

    /// Text for the HUD.
    public var displayName: String {
        switch self {
        case .idle: "Ready"
        case .collectingContext: "Looking at the screen"
        case .planning: "Deciding what to do"
        case .acting: "Working"
        case .waiting: "Waiting for the interface"
        case .verifying: "Checking the result"
        case .paused: "Paused"
        case .waitingForUser: "Waiting for you"
        case .completed: "Done"
        case .failed: "Stopped"
        case .cancelled: "Cancelled"
        }
    }
}

/// How a single executed step turned out.
public enum StepOutcome: Sendable, Equatable, Codable {
    case succeeded
    case failed(String)
    /// The action ran, but AbleKit could not tell whether it worked.
    case inconclusive(String)
    /// The policy refused the action.
    case blocked(String)
    /// The user declined to confirm.
    case declined
    case skipped(String)

    public var isSuccess: Bool {
        if case .succeeded = self { return true }
        return false
    }

    public var summary: String {
        switch self {
        case .succeeded: "succeeded"
        case .failed(let reason): "failed: \(reason)"
        case .inconclusive(let reason): "unverified: \(reason)"
        case .blocked(let reason): "blocked: \(reason)"
        case .declined: "you declined it"
        case .skipped(let reason): "skipped: \(reason)"
        }
    }
}

/// One entry in a task's history.
///
/// The record keeps the planner's reasoning next to what actually happened, which is what lets the
/// next planning turn learn from a failure instead of repeating it.
public struct StepRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let index: Int
    public let action: DesktopAction
    public let rationale: String
    public let classification: ActionClassification
    public let capability: CapabilityKind
    public let outcome: StepOutcome
    public let startedAt: Date
    public let duration: TimeInterval
    /// Fingerprint of the screen after the step, used for loop detection.
    public let resultingFingerprint: String?
    /// True when no action was taken because the planner's proposal could not be used.
    ///
    /// Such a record still carries an `action` for uniformity, but it was never executed, and it is
    /// shown to the model and the log as a planning problem — displaying it as the placeholder
    /// action told both of them AbleKit had spent a step "waiting 0.0s".
    public let isPlanningFailure: Bool
    /// Where the step was reasoned, when a model chose it.
    public let reasonedBy: ReasoningLocation?

    public init(
        id: UUID = UUID(),
        index: Int,
        action: DesktopAction,
        rationale: String,
        classification: ActionClassification,
        capability: CapabilityKind,
        outcome: StepOutcome,
        startedAt: Date = Date(),
        duration: TimeInterval = 0,
        resultingFingerprint: String? = nil,
        isPlanningFailure: Bool = false,
        reasonedBy: ReasoningLocation? = nil
    ) {
        self.id = id
        self.index = index
        self.action = action
        self.rationale = rationale
        self.classification = classification
        self.capability = capability
        self.outcome = outcome
        self.startedAt = startedAt
        self.duration = duration
        self.resultingFingerprint = resultingFingerprint
        self.isPlanningFailure = isPlanningFailure
        self.reasonedBy = reasonedBy
    }
}

/// The bounds a task runs inside.
///
/// Limits are what stand between "the agent is working" and "the agent is stuck in a loop burning
/// the user's battery". Every one of them is enforced in `AgentSession.run`.
public struct TaskLimits: Sendable, Equatable, Codable {
    /// Hard cap on executed steps.
    public var maximumSteps: Int
    /// Wall-clock budget for the whole task.
    public var maximumDuration: TimeInterval
    /// How many times the same action may be retried after failing.
    public var maximumRetriesPerAction: Int
    /// How many consecutive failures end the task.
    public var maximumConsecutiveFailures: Int
    /// How many times the screen may come back unchanged before we conclude we are stuck.
    public var maximumRepeatedStates: Int
    /// Pause inserted after each action, letting the interface settle before we observe again.
    public var actionDelay: TimeInterval

    public init(
        maximumSteps: Int = 25,
        maximumDuration: TimeInterval = 300,
        maximumRetriesPerAction: Int = 2,
        maximumConsecutiveFailures: Int = 3,
        maximumRepeatedStates: Int = 3,
        actionDelay: TimeInterval = 0.4
    ) {
        self.maximumSteps = maximumSteps
        self.maximumDuration = maximumDuration
        self.maximumRetriesPerAction = maximumRetriesPerAction
        self.maximumConsecutiveFailures = maximumConsecutiveFailures
        self.maximumRepeatedStates = maximumRepeatedStates
        self.actionDelay = actionDelay
    }

    public static let `default` = TaskLimits()
}

/// Why a task stopped.
public enum TaskTermination: Sendable, Equatable {
    case completed(String)
    case failed(String)
    case cancelled
    case limitReached(LimitKind)

    public enum LimitKind: String, Sendable, Equatable, Codable {
        case steps
        case duration
        case consecutiveFailures
        case repeatedStates
        case repeatedActions

        public var explanation: String {
            switch self {
            case .steps: "AbleKit reached its step limit for this task."
            case .duration: "AbleKit ran out of time for this task."
            case .consecutiveFailures: "Too many steps failed in a row."
            case .repeatedStates: "The screen stopped changing, so AbleKit was making no progress."
            case .repeatedActions: "AbleKit was about to repeat itself without getting anywhere."
            }
        }
    }

    public var userMessage: String {
        switch self {
        case .completed(let summary): summary
        case .failed(let reason): reason
        case .cancelled: "Cancelled."
        case .limitReached(let kind): kind.explanation
        }
    }
}
