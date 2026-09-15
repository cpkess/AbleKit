import Foundation

/// The gate every proposed action passes through before it can touch the desktop.
///
/// `ActionPolicy` is intentionally the *only* place that can authorise an action, and `Executor`
/// refuses to run anything that has not been through it. Keeping the gate narrow is what makes
/// "AbleKit never sent that email on its own" a property of the architecture rather than of
/// careful coding.
public struct ActionPolicy: Sendable {
    /// Whether consequential actions pause for confirmation. Exposed in Settings; defaults to on.
    public var confirmsConsequentialActions: Bool
    private let detector: SensitiveActionDetector

    public init(
        confirmsConsequentialActions: Bool = true,
        detector: SensitiveActionDetector = SensitiveActionDetector()
    ) {
        self.confirmsConsequentialActions = confirmsConsequentialActions
        self.detector = detector
    }

    /// Classifies an action and decides what should happen to it.
    public func evaluate(_ action: DesktopAction, context: DesktopContext? = nil) -> PolicyDecision {
        let result = detector.classify(action, context: context)
        switch result.classification {
        case .routine:
            return .allow
        case .consequential:
            guard confirmsConsequentialActions else { return .allow }
            return .confirm(reason: result.reason ?? "This action has effects that are hard to undo.")
        case .restricted:
            return .block(
                reason: result.reason
                    ?? "AbleKit does not perform this kind of action on its own."
            )
        }
    }

    /// The classification alone, for the debug interface and step history.
    public func classify(_ action: DesktopAction, context: DesktopContext? = nil) -> ClassificationResult {
        detector.classify(action, context: context)
    }
}
