import CoreGraphics
import Foundation

/// Why an action cannot be executed as described.
public enum ActionValidationError: Error, Equatable, Sendable {
    /// The point does not land on any attached display.
    case pointOffScreen(CGPoint)
    /// The element has no area, so there is nothing to aim at.
    case elementHasNoArea(String)
    /// The element is present but disabled.
    case elementDisabled(String)
    /// The element does not advertise the requested Accessibility action.
    case unsupportedAccessibilityAction(element: String, action: String)
    /// A wait longer than any plausible UI transition, which is nearly always a planning mistake.
    case waitTooLong(Double)
    /// Text or a prompt was empty.
    case emptyPayload(String)
    /// An application was named with neither a bundle identifier nor a name.
    case applicationNotIdentified
}

extension ActionValidationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .pointOffScreen(let point):
            "(\(Int(point.x)), \(Int(point.y))) is not on any display."
        case .elementHasNoArea(let element):
            "\(element) has no area on screen."
        case .elementDisabled(let element):
            "\(element) is disabled."
        case .unsupportedAccessibilityAction(let element, let action):
            "\(element) does not support \(action)."
        case .waitTooLong(let seconds):
            "A \(Int(seconds))s wait is longer than AbleKit will pause for."
        case .emptyPayload(let what):
            "\(what) was empty."
        case .applicationNotIdentified:
            "No application was named."
        }
    }
}

/// Checks that an action makes sense against the current state of the machine.
///
/// This runs *after* planning and *before* the safety policy, and it exists because a plan is a
/// statement about a world that may already have moved on. Catching a stale element here turns a
/// misclick into a retry with fresh context.
public struct ActionValidator: Sendable {
    /// The longest single pause AbleKit will take. Beyond this the agent should be re-observing,
    /// not sleeping.
    public static let maximumWait: Double = 30

    private let arrangement: ScreenArrangement

    public init(arrangement: ScreenArrangement) {
        self.arrangement = arrangement
    }

    public func validate(_ action: DesktopAction) throws(ActionValidationError) {
        switch action {
        case .openApplication(let app), .activateApplication(let app):
            guard app.bundleIdentifier?.isEmpty == false || app.name?.isEmpty == false else {
                throw .applicationNotIdentified
            }

        case .click(let target), .doubleClick(let target), .rightClick(let target),
            .movePointer(let target), .scroll(let target, _, _):
            try validate(target: target)

        case .drag(let from, let to):
            try validate(target: from)
            try validate(target: to)

        case .typeText(let text):
            guard !text.isEmpty else { throw .emptyPayload("The text to type") }

        case .accessibilityAction(let element, let axAction):
            try validate(target: .element(element))
            guard element.actions.contains(axAction) else {
                throw .unsupportedAccessibilityAction(element: element.description, action: axAction)
            }

        case .wait(let seconds):
            guard seconds <= Self.maximumWait else { throw .waitTooLong(seconds) }

        case .askAIBridge(_, let prompt):
            guard !prompt.trimmed.isEmpty else { throw .emptyPayload("The prompt") }

        case .requestConfirmation(let prompt), .requestUserInput(let prompt):
            guard !prompt.trimmed.isEmpty else { throw .emptyPayload("The question") }

        case .nativeAction(let operation):
            try validate(operation)

        case .pressKey, .hotkey, .complete, .fail:
            break
        }
    }

    private func validate(target: PointerTarget) throws(ActionValidationError) {
        switch target {
        case .point(let point):
            guard arrangement.contains(point) else { throw .pointOffScreen(point) }
        case .element(let element):
            guard element.frame.width > 0, element.frame.height > 0 else {
                throw .elementHasNoArea(element.description)
            }
            guard element.isEnabled else { throw .elementDisabled(element.description) }
            // An element whose centre is off-screen is usually one that scrolled away between
            // the snapshot and now.
            guard arrangement.contains(element.frame.center) else {
                throw .pointOffScreen(element.frame.center)
            }
        }
    }

    private func validate(_ operation: NativeOperation) throws(ActionValidationError) {
        switch operation {
        case .revealInFinder(let path):
            guard !path.trimmed.isEmpty else { throw .emptyPayload("The path") }
        case .openURL(let url):
            guard !url.trimmed.isEmpty else { throw .emptyPayload("The URL") }
        case .setClipboard(let text):
            guard !text.isEmpty else { throw .emptyPayload("The clipboard text") }
        case .openSystemSettings:
            break
        }
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
