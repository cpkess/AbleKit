import Foundation

/// The capability chosen for an action, and the action as it will actually be carried out.
public struct RoutingDecision: Sendable, Equatable {
    /// The action to execute, which may have been refined from the one that was planned.
    public let action: DesktopAction
    public let kind: CapabilityKind
    /// Set when the router changed the action, explaining why. Surfaced in the debug interface.
    public let refinement: String?

    public init(action: DesktopAction, kind: CapabilityKind, refinement: String? = nil) {
        self.action = action
        self.kind = kind
        self.refinement = refinement
    }
}

/// A routed action together with the capability that will carry it out.
public struct RoutedAction: Sendable {
    public let decision: RoutingDecision
    public let capability: any Capability

    public init(decision: RoutingDecision, capability: any Capability) {
        self.decision = decision
        self.capability = capability
    }
}

/// Chooses how each action should be carried out.
///
/// The router does two things, and the second is the interesting one:
///
/// 1. It finds a capability that accepts the action.
/// 2. It **refines** the action first, replacing a less deterministic form with a more
///    deterministic one wherever the context allows. A planned click on a button that advertises
///    `AXPress` becomes an Accessibility press — no coordinates, no pointer movement, and
///    unaffected by the window moving between planning and execution.
///
/// Doing this here rather than in the planner means the improvement applies no matter which model
/// proposed the action, and it is testable without running a model at all.
public struct CapabilityRouter: Sendable {
    private let capabilities: [any Capability]

    /// - Parameter capabilities: The available capabilities. Order does not matter; the router
    ///   sorts by `CapabilityKind`'s preference ranking.
    public init(capabilities: [any Capability]) {
        self.capabilities = capabilities.sorted { $0.kind < $1.kind }
    }

    /// Picks the capability for an action, refining the action where a better path exists.
    public func route(_ action: DesktopAction, context: DesktopContext? = nil) throws(CapabilityError)
        -> RoutedAction
    {
        let (refined, refinement) = Self.refine(action, context: context)

        if let capability = capabilities.first(where: { $0.canHandle(refined) }) {
            return RoutedAction(
                decision: RoutingDecision(
                    action: refined, kind: capability.kind, refinement: refinement
                ),
                capability: capability
            )
        }

        // The refinement may have produced something no capability accepts — for example an
        // Accessibility press when the Accessibility capability is unavailable because permission
        // was not granted. Falling back to the original keeps the task alive.
        if refined != action, let capability = capabilities.first(where: { $0.canHandle(action) }) {
            return RoutedAction(
                decision: RoutingDecision(
                    action: action,
                    kind: capability.kind,
                    refinement: "Fell back to \(capability.kind.displayName.lowercased()) interaction."
                ),
                capability: capability
            )
        }

        throw .noCapability(action.summary.lowercased())
    }

    /// Rewrites an action into a more deterministic equivalent where one exists.
    ///
    /// Exposed for testing, and kept static so it is obviously free of hidden state.
    static func refine(_ action: DesktopAction, context: DesktopContext?)
        -> (action: DesktopAction, refinement: String?)
    {
        switch action {
        case .click(.element(let element)) where element.isPressable:
            return (
                .accessibilityAction(element: element, action: "AXPress"),
                "Pressed \(element.description) through Accessibility instead of clicking its position."
            )

        case .rightClick(.element(let element)) where element.actions.contains("AXShowMenu"):
            return (
                .accessibilityAction(element: element, action: "AXShowMenu"),
                "Opened the menu through Accessibility instead of right-clicking."
            )

        case .click(.point(let point)), .doubleClick(.point(let point)):
            // A planner working from a screenshot may name a position where a perfectly good
            // semantic element happens to live. Prefer the element.
            guard let element = Self.element(at: point, in: context), element.isPressable else {
                return (action, nil)
            }
            return (
                .accessibilityAction(element: element, action: "AXPress"),
                "That position is \(element.description); pressed it through Accessibility instead."
            )

        default:
            return (action, nil)
        }
    }

    /// The smallest interactive element containing a point.
    ///
    /// Smallest wins because Accessibility trees nest: a point inside a button is also inside its
    /// toolbar, its window, and the application. The innermost element is the one meant.
    private static func element(at point: CGPoint, in context: DesktopContext?) -> ElementReference? {
        context?.accessibility?.interactiveElements
            .filter { $0.frame.contains(point) && $0.isEnabled }
            .min { lhs, rhs in
                lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
            }
    }
}
