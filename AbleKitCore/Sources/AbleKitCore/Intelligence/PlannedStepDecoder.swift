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
    ///
    /// - Parameter goal: The user's goal, used where the model left out text the step needs and the
    ///   goal itself is a reasonable stand-in.
    public func decode(_ draft: PlannedStepDraft, context: DesktopContext, goal: String? = nil)
        throws(IntelligenceError) -> PlannedStep
    {
        let action = try self.action(for: draft, context: context, goal: goal)
        return PlannedStep(
            action: action,
            rationale: draft.rationale.trimmed.isEmpty ? action.summary : draft.rationale.trimmed,
            confidence: draft.confidence
        )
    }

    private func action(for draft: PlannedStepDraft, context: DesktopContext, goal: String?)
        throws(IntelligenceError) -> DesktopAction
    {
        switch draft.kind {
        case .openApplication:
            guard let name = draft.applicationName?.trimmed, !name.isEmpty else {
                throw .undecodableStep("openApplication needs an application name.")
            }
            return .openApplication(ApplicationReference(name: name))

        case .chooseMenuItem:
            return .chooseMenuItem(path: try resolveMenuItem(draft, context: context))

        case .clickElement:
            return .click(target: try resolveTarget(draft, context: context))

        case .doubleClickElement:
            return .doubleClick(target: try resolveTarget(draft, context: context))

        case .rightClickElement:
            return .rightClick(target: try resolveTarget(draft, context: context))

        case .clickPosition:
            guard let x = draft.x, let y = draft.y else {
                throw .undecodableStep("clickPosition needs both x and y.")
            }
            return .click(target: .point(CGPoint(x: x, y: y)))

        case .typeText:
            guard let text = draft.text, !text.isEmpty else {
                throw .undecodableStep("typeText needs the text to type.")
            }
            return .typeText(text, into: try typingDestination(draft, context: context))

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
            // The on-device model reliably chooses askCopilot for a Copilot goal and then, just as
            // reliably, leaves the question out. The user's own goal is a fair question to send in
            // that case — and it is safe to, because a bridge handoff is always shown in full and
            // confirmed before anything leaves the machine.
            let prompt = (draft.text?.trimmed).flatMap { $0.isEmpty ? nil : $0 } ?? goal?.trimmed
            guard let prompt, !prompt.isEmpty else {
                throw .undecodableStep("askCopilot needs a question.")
            }
            return .askAIBridge(bridge: .copilot, prompt: prompt)

        case .wait:
            // Clamped rather than rejected: an over-long wait is a harmless misjudgement, and
            // failing the step would waste a planning turn on it.
            let seconds = min(max(draft.waitSeconds ?? 1, 0.1), 10)
            return .wait(seconds: seconds)

        case .readScreen:
            return .readScreen

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

    // MARK: - Resolving menu commands

    /// Turns `File > New` into the exact titles of a command the app actually has.
    ///
    /// The planner's spelling is checked against the menu bar rather than trusted, so a command
    /// that does not exist, or is greyed out, costs one re-plan instead of a failed action.
    private func resolveMenuItem(_ draft: PlannedStepDraft, context: DesktopContext)
        throws(IntelligenceError) -> [String]
    {
        // Models put the path in whichever field feels natural; both are accepted.
        let raw = (draft.text?.trimmed).flatMap { $0.isEmpty ? nil : $0 } ?? draft.elementID?.trimmed ?? ""
        let requested = Self.parseMenuPath(raw)
        guard !requested.isEmpty else {
            throw .undecodableStep("chooseMenuItem needs the command, such as File > New, in the text.")
        }
        guard let menus = context.accessibility, !menus.menuItems.isEmpty else {
            throw .undecodableStep("This app's menus could not be read; use a control or a shortcut instead.")
        }
        guard let item = menus.menuItem(matching: requested) else {
            throw .undecodableStep(
                "There is no menu command \(requested.joined(separator: " > ").quoted). Pick one listed under MENUS."
            )
        }
        guard item.isEnabled else {
            throw .undecodableStep("\(item.displayPath.quoted) is greyed out right now.")
        }
        return item.path
    }

    /// Splits a menu path written any of the ways a person might: `File > New`, `File › New`,
    /// `File/New`, `File -> New`.
    static func parseMenuPath(_ raw: String) -> [String] {
        var text = raw
        for separator in ["->", "\u{203A}", "\u{2192}", " / "] {
            text = text.replacingOccurrences(of: separator, with: ">")
        }
        return text.split(separator: ">")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Resolving elements

    /// What a click should aim at: a control, or a piece of recognised screen text.
    ///
    /// Text ids (`t4`) resolve to the centre of that text on screen. The router may still upgrade the
    /// click to an Accessibility press if a control turns out to sit at that position.
    private func resolveTarget(_ draft: PlannedStepDraft, context: DesktopContext)
        throws(IntelligenceError) -> PointerTarget
    {
        let raw = draft.elementID?.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? ""
        if raw.hasPrefix("t"), Int(raw.dropFirst()) != nil {
            guard let region = context.screen?.textRegion(withID: raw) else {
                throw .undecodableStep(
                    "There is no screen text \(raw.quoted) now. Look at the current list and pick another."
                )
            }
            return .point(region.frame.center)
        }
        return .element(try resolveElement(draft, context: context))
    }

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

    /// The field a typeText step names, if it names one.
    ///
    /// Typing without one is refused when the window has text fields but none of them has focus:
    /// the text would land wherever the cursor happened to be, which on the real model's first try
    /// was exactly what it planned. Windows with no readable fields — a canvas, a terminal — are
    /// allowed through, since there is no field to name.
    private func typingDestination(_ draft: PlannedStepDraft, context: DesktopContext)
        throws(IntelligenceError) -> ElementReference?
    {
        if draft.elementID?.trimmed.isEmpty == false {
            return try resolveElement(draft, context: context)
        }
        let elements = context.accessibility?.elements ?? []
        let hasFocusedInput = elements.contains { $0.isFocused && $0.isTextInput }
        let hasInputs = elements.contains { $0.isTextInput && $0.isEnabled }
        if hasInputs && !hasFocusedInput {
            throw .undecodableStep(
                "No field has focus, so the text would go nowhere useful. Put the id of the field to type into in elementID."
            )
        }
        return nil
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
