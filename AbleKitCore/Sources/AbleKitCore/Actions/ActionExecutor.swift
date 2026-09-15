import Foundation

/// What happened when an action was put through the pipeline.
public struct ExecutionReport: Sendable {
    public let action: DesktopAction
    public let classification: ActionClassification
    public let capability: CapabilityKind
    public let outcome: StepOutcome
    /// Text the action produced, such as an AI bridge's answer.
    public let producedText: String?
    /// Set when the router substituted a more deterministic action.
    public let refinement: String?

    public init(
        action: DesktopAction,
        classification: ActionClassification,
        capability: CapabilityKind,
        outcome: StepOutcome,
        producedText: String? = nil,
        refinement: String? = nil
    ) {
        self.action = action
        self.classification = classification
        self.capability = capability
        self.outcome = outcome
        self.producedText = producedText
        self.refinement = refinement
    }
}

/// Puts a single action through validation, safety, routing, and execution, in that order.
///
/// The order is the design. Validation first, because an action aimed at a control that has
/// scrolled away should be discarded before anyone is asked to approve it. Safety second, because
/// nothing should be executed that the policy has not seen. Routing third, because the capability
/// chosen is a consequence of the action, not of the plan. Nothing else in AbleKit calls a
/// capability's `execute` directly.
public struct Executor: Sendable {
    private let router: CapabilityRouter
    private let policy: ActionPolicy
    private let interaction: any UserInteracting

    public init(
        router: CapabilityRouter,
        policy: ActionPolicy,
        interaction: any UserInteracting = DecliningUserInteraction()
    ) {
        self.router = router
        self.policy = policy
        self.interaction = interaction
    }

    public func execute(_ action: DesktopAction, context: DesktopContext) async -> ExecutionReport {
        let classification = policy.classify(action, context: context).classification

        // 1. Does this action still make sense against the machine as it is now?
        let validator = ActionValidator(arrangement: context.arrangement)
        do {
            try validator.validate(action)
        } catch {
            return ExecutionReport(
                action: action,
                classification: classification,
                capability: .control,
                outcome: .failed(error.description)
            )
        }

        // 2. Is it allowed, and does the user need to see it first?
        switch policy.evaluate(action, context: context) {
        case .allow:
            break
        case .block(let reason):
            return ExecutionReport(
                action: action,
                classification: classification,
                capability: .control,
                outcome: .blocked(reason)
            )
        case .confirm(let reason):
            let prompt = UserPrompt(
                message: action.summary,
                style: .confirmation(action: action, reason: reason)
            )
            guard await interaction.confirm(prompt) else {
                return ExecutionReport(
                    action: action,
                    classification: classification,
                    capability: .user,
                    outcome: .declined
                )
            }
        }

        // 3. Which capability should carry it out, and is there a better form of it?
        let routed: RoutedAction
        do {
            routed = try router.route(action, context: context)
        } catch {
            return ExecutionReport(
                action: action,
                classification: classification,
                capability: .control,
                outcome: .failed(error.description)
            )
        }

        // 4. Do it.
        let decision = routed.decision
        do {
            let outcome = try await routed.capability.execute(decision.action, context: context)
            return ExecutionReport(
                action: decision.action,
                classification: classification,
                capability: decision.kind,
                outcome: outcome.succeeded
                    ? .succeeded
                    : .failed(outcome.detail ?? "The action did not go through."),
                producedText: outcome.producedText,
                refinement: decision.refinement
            )
        } catch let error as CapabilityError {
            return ExecutionReport(
                action: decision.action,
                classification: classification,
                capability: decision.kind,
                outcome: error == .cancelled ? .skipped("Cancelled.") : .failed(error.description),
                refinement: decision.refinement
            )
        } catch is CancellationError {
            return ExecutionReport(
                action: decision.action,
                classification: classification,
                capability: decision.kind,
                outcome: .skipped("Cancelled."),
                refinement: decision.refinement
            )
        } catch {
            return ExecutionReport(
                action: decision.action,
                classification: classification,
                capability: decision.kind,
                outcome: .failed(error.localizedDescription),
                refinement: decision.refinement
            )
        }
    }
}
