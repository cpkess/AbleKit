import Foundation

/// Everything the planner is allowed to know when choosing the next step.
public struct AgentContext: Sendable {
    /// What the user asked for, verbatim.
    public let goal: String
    /// The desktop as it is right now.
    public let desktop: DesktopContext
    /// What has already been tried, and how it went.
    public let history: [StepRecord]
    /// The plan this task is working through, and where it has got to.
    public let plan: TaskPlan?
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
        plan: TaskPlan? = nil,
        gatheredInformation: [GatheredInformation] = [],
        stepIndex: Int = 0,
        stepLimit: Int = TaskLimits.default.maximumSteps
    ) {
        self.goal = goal
        self.desktop = desktop
        self.history = history
        self.plan = plan
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
    /// Whether the plan's current sub-goal is now satisfied.
    ///
    /// Answered here rather than by a separate question, because the verifier is already looking at
    /// the screen before and after: the checkpoint costs nothing extra.
    public let completedSubGoal: Bool

    public init(
        outcome: VerificationOutcome,
        reason: String,
        shouldRetry: Bool = false,
        completedSubGoal: Bool = false
    ) {
        self.outcome = outcome
        self.reason = reason
        self.shouldRetry = shouldRetry
        self.completedSubGoal = completedSubGoal
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

/// Whether the goal has been reached, and what to tell the user if so.
public struct GoalCheck: Sendable, Equatable {
    public let isAchieved: Bool
    /// One sentence for the user, when it is achieved.
    public let summary: String

    public init(isAchieved: Bool, summary: String = "Done.") {
        self.isAchieved = isAchieved
        self.summary = summary
    }

    public static let notYet = GoalCheck(isAchieved: false)
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

    /// Writes the ordered sub-goals for a task, by looking at the app before anything is touched.
    ///
    /// Planning one action at a time keeps every decision honest about the screen, but leaves the
    /// model with no sense of where it is in a task with several parts. Asked to "work out 12 times
    /// 7, then copy the result", it went straight to copying. The plan supplies that structure;
    /// `AgentSession` holds the position rather than asking the model to re-derive it.
    func makePlan(goal: String, context: DesktopContext) async throws -> [String]

    /// Rewrites what remains of a plan against the screen as it now is.
    ///
    /// Called at a checkpoint: when a sub-goal has taken too many actions, or the screen has gone
    /// somewhere the plan did not anticipate. Plans are guides, and a guide that no longer matches
    /// the ground is worse than none.
    func revisePlan(goal: String, plan: TaskPlan, context: DesktopContext, reason: String)
        async throws -> [String]

    /// Judges whether the goal has now been reached.
    ///
    /// Asked after each step that worked, separately from planning. Left to the planner, this
    /// decision was made badly in both directions: tasks that were finished carried on pressing
    /// buttons, and a task that had barely started was declared done. A yes/no question about a
    /// screen is a much smaller thing to ask of a small model than "what next?", and it is the
    /// question whose wrong answer costs the most.
    func isGoalAchieved(goal: String, context: DesktopContext, history: [StepRecord]) async throws
        -> GoalCheck

    /// Judges whether an action did what it was supposed to, and whether it finished the sub-goal.
    func verify(
        action: DesktopAction,
        subGoal: String?,
        before: DesktopContext,
        after: DesktopContext
    ) async throws -> VerificationResult
}
