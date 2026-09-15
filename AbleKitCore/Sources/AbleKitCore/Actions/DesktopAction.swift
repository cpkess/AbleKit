import CoreGraphics
import Foundation

/// A mouse button.
public enum MouseButton: String, Sendable, Codable, CaseIterable {
    case left
    case right
    case center
}

/// A keyboard modifier.
public enum ModifierKey: String, Sendable, Codable, CaseIterable {
    case command
    case shift
    case option
    case control
    case function
}

/// A key that can be pressed on its own or as the base of a shortcut.
///
/// Keys are symbolic rather than numeric so that the core stays free of keyboard-layout concerns;
/// `KeyboardController` resolves them against the user's *current* layout at execution time.
public enum Key: Sendable, Equatable, Codable {
    case character(String)
    case returnKey
    case enterKey
    case tab
    case space
    case delete
    case forwardDelete
    case escape
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case home
    case end
    case pageUp
    case pageDown
    case function(Int)
}

/// Where a pointer action should happen.
///
/// Preferring `.element` over `.point` wherever possible is the heart of the brief's reliability
/// model: an element survives the window moving, the layout reflowing, or the display changing,
/// and a raw point does not.
public enum PointerTarget: Sendable, Equatable, Codable {
    /// A point in canonical space (global, top-left origin, points).
    case point(CGPoint)
    /// A semantic element discovered through the Accessibility tree.
    case element(ElementReference)

    /// The canonical point this target resolves to.
    public var resolvedPoint: CGPoint {
        switch self {
        case .point(let point): point
        case .element(let element): element.frame.center
        }
    }
}

/// Which application an action refers to.
public struct ApplicationReference: Sendable, Equatable, Codable {
    public let bundleIdentifier: String?
    public let name: String?

    public init(bundleIdentifier: String? = nil, name: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }

    public var displayName: String {
        name ?? bundleIdentifier ?? "an application"
    }
}

/// A native macOS operation that needs no UI interaction at all.
///
/// These exist so the planner has a first-class way to express "this does not require driving the
/// interface", which is the brief's top engineering principle.
public enum NativeOperation: Sendable, Equatable, Codable {
    case revealInFinder(path: String)
    case openURL(String)
    case openSystemSettings(paneIdentifier: String?)
    case setClipboard(String)
}

/// Every action AbleKit can take on the desktop.
///
/// The payload of each case carries only the parameters that case needs, so an action that has
/// been constructed is already structurally meaningful. Semantic validity — does this point land
/// on a display, is this element still enabled — is `ActionValidator`'s job.
public enum DesktopAction: Sendable, Equatable, Codable {
    case openApplication(ApplicationReference)
    case activateApplication(ApplicationReference)
    case click(target: PointerTarget)
    case doubleClick(target: PointerTarget)
    case rightClick(target: PointerTarget)
    case movePointer(to: PointerTarget)
    case typeText(String)
    case pressKey(Key)
    case hotkey(key: Key, modifiers: [ModifierKey])
    case scroll(target: PointerTarget, deltaX: Int, deltaY: Int)
    case drag(from: PointerTarget, to: PointerTarget)
    case wait(seconds: Double)
    case accessibilityAction(element: ElementReference, action: String)
    case nativeAction(NativeOperation)
    case askAIBridge(bridge: AIBridgeIdentifier, prompt: String)
    case requestConfirmation(prompt: String)
    case requestUserInput(prompt: String)
    case complete(summary: String)
    case fail(reason: String)
}

extension DesktopAction {
    /// A short, human-readable description, shown in the HUD while the agent is working.
    ///
    /// This is the user's only window into what the agent is about to do, so it names concrete
    /// targets rather than action types.
    public var summary: String {
        switch self {
        case .openApplication(let app): "Opening \(app.displayName)"
        case .activateApplication(let app): "Switching to \(app.displayName)"
        case .click(let target): "Clicking \(target.description)"
        case .doubleClick(let target): "Double-clicking \(target.description)"
        case .rightClick(let target): "Right-clicking \(target.description)"
        case .movePointer(let target): "Moving pointer to \(target.description)"
        case .typeText(let text): "Typing \(text.truncated(to: 40).quoted)"
        case .pressKey(let key): "Pressing \(key.displayName)"
        case .hotkey(let key, let modifiers):
            "Pressing \((modifiers.map(\.symbol) + [key.displayName]).joined())"
        case .scroll(_, let x, let y): "Scrolling \(Self.scrollDescription(deltaX: x, deltaY: y))"
        case .drag(let from, let to): "Dragging \(from.description) to \(to.description)"
        case .wait(let seconds): "Waiting \(String(format: "%.1f", seconds))s"
        case .accessibilityAction(let element, let action):
            "\(Self.friendlyAccessibilityAction(action)) \(element.description)"
        case .nativeAction(let operation): operation.summary
        case .askAIBridge(let bridge, _): "Asking \(bridge.displayName)"
        case .requestConfirmation: "Waiting for your confirmation"
        case .requestUserInput: "Waiting for your input"
        case .complete(let summary): summary
        case .fail(let reason): "Stopped: \(reason)"
        }
    }

    /// Whether this action ends the task.
    public var isTerminal: Bool {
        switch self {
        case .complete, .fail: true
        default: false
        }
    }

    /// Whether this action hands control back to the user rather than touching the desktop.
    public var requiresUserResponse: Bool {
        switch self {
        case .requestConfirmation, .requestUserInput: true
        default: false
        }
    }

    /// The pointer target this action acts on, if any. Used by the overlay to highlight what is
    /// about to be touched, and by loop detection to notice repeated targets.
    public var pointerTarget: PointerTarget? {
        switch self {
        case .click(let target), .doubleClick(let target), .rightClick(let target),
            .movePointer(let target), .scroll(let target, _, _):
            target
        case .drag(let from, _):
            from
        case .accessibilityAction(let element, _):
            .element(element)
        default:
            nil
        }
    }

    private static func scrollDescription(deltaX: Int, deltaY: Int) -> String {
        if deltaY != 0 { return deltaY > 0 ? "up" : "down" }
        if deltaX != 0 { return deltaX > 0 ? "right" : "left" }
        return "nowhere"
    }

    private static func friendlyAccessibilityAction(_ action: String) -> String {
        switch action {
        case "AXPress": "Pressing"
        case "AXConfirm": "Confirming"
        case "AXCancel": "Cancelling"
        case "AXShowMenu": "Opening the menu of"
        case "AXIncrement": "Increasing"
        case "AXDecrement": "Decreasing"
        case "AXPick": "Selecting"
        default: "Performing \(action) on"
        }
    }
}

extension NativeOperation {
    public var summary: String {
        switch self {
        case .revealInFinder(let path):
            "Revealing \((path as NSString).lastPathComponent) in Finder"
        case .openURL(let url): "Opening \(url)"
        case .openSystemSettings: "Opening System Settings"
        case .setClipboard: "Copying to the clipboard"
        }
    }
}

extension PointerTarget: CustomStringConvertible {
    public var description: String {
        switch self {
        case .point(let point): "(\(Int(point.x)), \(Int(point.y)))"
        case .element(let element): element.description
        }
    }
}

extension Key {
    public var displayName: String {
        switch self {
        case .character(let character): character.uppercased()
        case .returnKey: "Return"
        case .enterKey: "Enter"
        case .tab: "Tab"
        case .space: "Space"
        case .delete: "Delete"
        case .forwardDelete: "Forward Delete"
        case .escape: "Escape"
        case .arrowUp: "Up"
        case .arrowDown: "Down"
        case .arrowLeft: "Left"
        case .arrowRight: "Right"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        case .function(let number): "F\(number)"
        }
    }
}

extension ModifierKey {
    public var symbol: String {
        switch self {
        case .command: "\u{2318}"
        case .shift: "\u{21E7}"
        case .option: "\u{2325}"
        case .control: "\u{2303}"
        case .function: "fn"
        }
    }
}

extension String {
    func truncated(to limit: Int) -> String {
        count <= limit ? self : String(prefix(limit)) + "\u{2026}"
    }

    var quoted: String { "\u{201C}\(self)\u{201D}" }
}
