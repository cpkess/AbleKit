import Foundation

/// Notices when the agent has stopped making progress.
///
/// Two different kinds of stuck are worth catching, and they look nothing alike:
///
/// 1. **Repeating an action.** The planner proposes the same thing again and again, usually
///    because it cannot see that the last attempt failed.
/// 2. **A frozen screen.** Actions execute and appear to succeed, but the interface never changes
///    — a click landing on a dead pixel, or a button that silently does nothing.
///
/// Catching these is what keeps a bad plan from burning the entire step budget.
public struct LoopDetector: Sendable {
    private var actionCounts: [String: Int] = [:]
    private var recentFingerprints: [String] = []
    private let limits: TaskLimits

    public init(limits: TaskLimits = .default) {
        self.limits = limits
    }

    /// Records an action the agent is about to take, and the screen state it acted on.
    public mutating func record(action: DesktopAction, fingerprint: String?) {
        actionCounts[Self.signature(for: action), default: 0] += 1
        if let fingerprint {
            recentFingerprints.append(fingerprint)
            // Only the recent past matters: a screen legitimately revisited much later is not a loop.
            if recentFingerprints.count > limits.maximumRepeatedStates * 2 {
                recentFingerprints.removeFirst()
            }
        }
    }

    /// How many times this exact action has already been attempted.
    public func attemptCount(for action: DesktopAction) -> Int {
        actionCounts[Self.signature(for: action)] ?? 0
    }

    /// Whether proposing `action` again would just repeat work that is going nowhere.
    ///
    /// Terminal and user-facing actions are exempt: asking the user the same question twice is a
    /// legitimate thing to do, and completing is always allowed.
    public func wouldRepeat(_ action: DesktopAction) -> Bool {
        guard !action.isTerminal, !action.requiresUserResponse else { return false }
        return attemptCount(for: action) > limits.maximumRetriesPerAction
    }

    /// Whether the screen has come back identical too many times in a row.
    public var isScreenStuck: Bool {
        guard recentFingerprints.count >= limits.maximumRepeatedStates else { return false }
        let window = recentFingerprints.suffix(limits.maximumRepeatedStates)
        guard let first = window.first else { return false }
        return window.allSatisfy { $0 == first }
    }

    /// The limit that has been breached, if any.
    public func breachedLimit() -> TaskTermination.LimitKind? {
        if isScreenStuck { return .repeatedStates }
        return nil
    }

    /// A stable identity for an action, used to tell "the same thing again" from "something new".
    ///
    /// Element targets collapse to their *label and role* rather than their snapshot id, because
    /// ids are regenerated on every snapshot — without this, clicking the same button five times
    /// would look like five different actions.
    static func signature(for action: DesktopAction) -> String {
        switch action {
        case .click(let target): "click:\(signature(for: target))"
        case .doubleClick(let target): "doubleClick:\(signature(for: target))"
        case .rightClick(let target): "rightClick:\(signature(for: target))"
        case .movePointer(let target): "move:\(signature(for: target))"
        case .scroll(let target, let x, let y): "scroll:\(signature(for: target)):\(x),\(y)"
        case .drag(let from, let to): "drag:\(signature(for: from))->\(signature(for: to))"
        case .accessibilityAction(let element, let axAction):
            "ax:\(axAction):\(signature(for: .element(element)))"
        case .typeText(let text): "type:\(text)"
        case .pressKey(let key): "key:\(key.displayName)"
        case .hotkey(let key, let modifiers):
            "hotkey:\(modifiers.map(\.rawValue).sorted().joined(separator: "+"))+\(key.displayName)"
        case .openApplication(let app): "open:\(app.bundleIdentifier ?? app.name ?? "?")"
        case .activateApplication(let app): "activate:\(app.bundleIdentifier ?? app.name ?? "?")"
        case .nativeAction(let operation): "native:\(operation.summary)"
        case .askAIBridge(let bridge, let prompt): "bridge:\(bridge.rawValue):\(prompt)"
        case .wait(let seconds): "wait:\(seconds)"
        case .requestConfirmation(let prompt): "confirm:\(prompt)"
        case .requestUserInput(let prompt): "input:\(prompt)"
        case .complete(let summary): "complete:\(summary)"
        case .fail(let reason): "fail:\(reason)"
        }
    }

    private static func signature(for target: PointerTarget) -> String {
        switch target {
        case .point(let point): "pt(\(Int(point.x)),\(Int(point.y)))"
        case .element(let element): "el(\(element.role):\(element.bestLabel ?? "untitled"))"
        }
    }
}
