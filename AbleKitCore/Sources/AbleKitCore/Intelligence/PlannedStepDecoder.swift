import CoreGraphics
import Foundation

/// Turns what a model produced into an action the system will accept.
///
/// Guided generation guarantees the *shape* of a step but not its *meaning*: the model can name an
/// element that has scrolled away, or a key that does not exist. Every such mistake is caught here
/// and reported as a sentence that can be fed back into the next planning turn, so a bad step costs
/// one retry instead of a misclick.
///
/// It runs without a model, so every rule below is directly testable.
public struct PlannedStepDecoder: Sendable {

    public init() {}

    /// Decodes a draft against the desktop it was planned for.
    public func decode(_ draft: PlannedStepDraft, context: DesktopContext) throws(IntelligenceError)
        -> PlannedStep
    {
        let action = try self.action(for: draft, context: context)
        return PlannedStep(
            action: action,
            rationale: draft.rationale.trimmed.isEmpty ? action.summary : draft.rationale.trimmed,
            confidence: draft.confidence
        )
    }

    private func action(for draft: PlannedStepDraft, context: DesktopContext) throws(IntelligenceError)
        -> DesktopAction
    {
        switch draft.kind {
        case .openApplication:
            guard let name = draft.applicationName?.trimmed, !name.isEmpty else {
                throw .undecodableStep("openApplication needs an application name.")
            }
            return .openApplication(ApplicationReference(name: name))

        case .clickElement:
            return .click(target: .element(try resolveElement(draft, context: context)))

        case .doubleClickElement:
            return .doubleClick(target: .element(try resolveElement(draft, context: context)))

        case .rightClickElement:
            return .rightClick(target: .element(try resolveElement(draft, context: context)))

        case .clickPosition:
            guard let x = draft.x, let y = draft.y else {
                throw .undecodableStep("clickPosition needs both x and y.")
            }
            return .click(target: .point(CGPoint(x: x, y: y)))

        case .typeText:
            guard let text = draft.text, !text.isEmpty else {
                throw .undecodableStep("typeText needs the text to type.")
            }
            return .typeText(text)

        case .pressKey:
            guard let name = draft.keyName else {
                throw .undecodableStep("pressKey needs a key name.")
            }
            return .pressKey(try Self.parseKey(name))

        case .hotkey:
            guard let name = draft.keyName else {
                throw .undecodableStep("hotkey needs a key name.")
            }
            let modifiers = (draft.modifiers ?? []).map(\.modifierKey)
            guard !modifiers.isEmpty else {
                // A "shortcut" with no modifier is just a keypress; accept it rather than failing
                // the step over a naming quibble.
                return .pressKey(try Self.parseKey(name))
            }
            return .hotkey(key: try Self.parseKey(name), modifiers: modifiers)

        case .scroll:
            let amount = draft.scrollAmount ?? -3
            guard amount != 0 else {
                throw .undecodableStep("A scroll of zero would do nothing.")
            }
            let target = try scrollTarget(draft, context: context)
            return .scroll(target: target, deltaX: 0, deltaY: amount)

        case .openURL:
            guard let text = draft.text?.trimmed, !text.isEmpty else {
                throw .undecodableStep("openURL needs a web address.")
            }
            return .nativeAction(.openURL(Self.normalizeURL(text)))

        case .askCopilot:
            guard let prompt = draft.text?.trimmed, !prompt.isEmpty else {
                throw .undecodableStep("askCopilot needs a question.")
            }
            return .askAIBridge(bridge: .copilot, prompt: prompt)

        case .wait:
            // Clamped rather than rejected: an over-long wait is a harmless misjudgement, and
            // failing the step would waste a planning turn on it.
            let seconds = min(max(draft.waitSeconds ?? 1, 0.1), 10)
            return .wait(seconds: seconds)

        case .askUser:
            guard let question = draft.text?.trimmed, !question.isEmpty else {
                throw .undecodableStep("askUser needs a question.")
            }
            return .requestUserInput(prompt: question)

        case .complete:
            let summary = draft.text?.trimmed
            return .complete(summary: summary?.isEmpty == false ? summary! : "Done.")

        case .fail:
            let reason = draft.text?.trimmed
            return .fail(reason: reason?.isEmpty == false ? reason! : "AbleKit could not complete this.")
        }
    }

    // MARK: - Resolving elements

    /// Finds the element a draft refers to.
    ///
    /// Models name things inconsistently: sometimes the id `e12`, sometimes `[e12]`, and often the
    /// label `"Save"` instead. All three are accepted, because the alternative is failing a step
    /// over a formatting detail when the intent is unambiguous.
    private func resolveElement(_ draft: PlannedStepDraft, context: DesktopContext)
        throws(IntelligenceError) -> ElementReference
    {
        guard let snapshot = context.accessibility else {
            throw .undecodableStep("There are no readable controls in this app to act on.")
        }
        guard let raw = draft.elementID?.trimmed, !raw.isEmpty else {
            throw .undecodableStep("\(draft.kind.rawValue) needs the id of a control.")
        }

        let identifier = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let element = snapshot.element(withID: identifier) {
            return element
        }
        // The model may have quoted the label instead of the id.
        if let element = snapshot.bestMatch(forLabel: identifier) {
            return element
        }
        throw .undecodableStep(
            "There is no control \(identifier.quoted) on screen now. Look at the current list and pick another."
        )
    }

    /// Where to aim a scroll.
    ///
    /// Scrolling needs a position because macOS delivers the event to whatever is under the
    /// pointer. Falling back to the focused window's centre is what a person would do.
    private func scrollTarget(_ draft: PlannedStepDraft, context: DesktopContext)
        throws(IntelligenceError) -> PointerTarget
    {
        if draft.elementID?.trimmed.isEmpty == false,
            let element = try? resolveElement(draft, context: context)
        {
            return .element(element)
        }
        if let window = context.focusedWindow, window.frame.width > 0 {
            return .point(window.frame.center)
        }
        if let display = context.arrangement.primary {
            return .point(display.bounds.center)
        }
        throw .undecodableStep("There is nowhere to scroll: no window or display was found.")
    }

    // MARK: - Parsing

    /// Interprets a key name the way a person would write it.
    static func parseKey(_ name: String) throws(IntelligenceError) -> Key {
        let normalized =
            name
            .trimmed
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")

        switch normalized {
        case "return", "enter\u{21A9}", "\u{21A9}": return .returnKey
        case "enter", "numpadenter": return .enterKey
        case "tab": return .tab
        case "space", "spacebar": return .space
        case "delete", "backspace": return .delete
        case "forwarddelete", "del": return .forwardDelete
        case "escape", "esc": return .escape
        case "up", "uparrow", "arrowup": return .arrowUp
        case "down", "downarrow", "arrowdown": return .arrowDown
        case "left", "leftarrow", "arrowleft": return .arrowLeft
        case "right", "rightarrow", "arrowright": return .arrowRight
        case "home": return .home
        case "end": return .end
        case "pageup", "pgup": return .pageUp
        case "pagedown", "pgdn": return .pageDown
        default:
            break
        }

        if normalized.hasPrefix("f"), let number = Int(normalized.dropFirst()), (1...20).contains(number) {
            return .function(number)
        }
        // A single character is the common case for shortcuts: Command-S, Command-comma.
        if normalized.count == 1 {
            return .character(normalized)
        }
        throw .undecodableStep("\(name.quoted) is not a key AbleKit knows how to press.")
    }

    /// Makes a bare host name into something `NSWorkspace` will open.
    static func normalizeURL(_ string: String) -> String {
        let trimmed = string.trimmed
        guard let url = URL(string: trimmed), url.scheme != nil else {
            return "https://\(trimmed)"
        }
        return trimmed
    }
}

extension PlannedModifier {
    var modifierKey: ModifierKey {
        switch self {
        case .command: .command
        case .shift: .shift
        case .option: .option
        case .control: .control
        }
    }
}
