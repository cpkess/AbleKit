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
            rationale: draft.rationale.trimmed.isEmpty ? action.summary : draft.rationale.trimmed
        )
    }

    /// The draft's subject, or `nil` when the model wrote nothing meaningful there.
    static func subject(of draft: PlannedStepDraft) -> String? {
        let value = draft.subject.trimmed
        let empty: Set<String> = ["", "none", "n/a", "na", "null", "nil", "nothing", "-"]
        return empty.contains(value.lowercased()) ? nil : value
    }

    private func action(for draft: PlannedStepDraft, context: DesktopContext, goal: String?)
        throws(IntelligenceError) -> DesktopAction
    {
        let subject = Self.subject(of: draft)

        switch draft.kind {
        case .openApplication:
            guard let name = subject else {
                throw .undecodableStep("openApplication needs the application's name as its subject.")
            }
            return .openApplication(ApplicationReference(name: name))

        case .chooseMenuItem:
            return .chooseMenuItem(path: try resolveMenuItem(subject, context: context))

        case .clickElement:
            let target = try resolveTarget(subject, kind: draft.kind, context: context)
            // Clicking a text field that already has the cursor does nothing useful, and can do
            // harm: in Finder's rename field it deselects the old name, so the new one is appended
            // to it. The model proposed exactly that once, in place of typing the name.
            if case .element(let field) = target, field.isFocused, field.isTextInput {
                let literals = goal.map(GoalAnalysis.literalTexts(in:)) ?? []
                if literals.count == 1 {
                    return .typeText(literals[0], into: field)
                }
                throw .undecodableStep(
                    "\(field.description) already has the cursor. Type into it with typeText instead of clicking it."
                )
            }
            return .click(target: target)

        case .doubleClickElement:
            return .doubleClick(target: try resolveTarget(subject, kind: draft.kind, context: context))

        case .rightClickElement:
            return .rightClick(target: try resolveTarget(subject, kind: draft.kind, context: context))

        case .clickPosition:
            guard let point = subject.flatMap(Self.parsePoint) else {
                throw .undecodableStep("clickPosition needs a position such as 400, 300 as its subject.")
            }
            return .click(target: .point(point))

        case .typeText:
            // The subject is the literal text, so it is not trimmed: leading and trailing spaces
            // can be meant.
            let literals = goal.map(GoalAnalysis.literalTexts(in:)) ?? []
            let text = try Self.reconcileTypedText(draft.subject, literals: literals)
            return .typeText(text, into: try typingDestination(draft, context: context))

        case .pressKey, .hotkey:
            guard let subject else {
                throw .undecodableStep("\(draft.kind.rawValue) needs the key as its subject.")
            }
            // Models write shortcuts every way there is: a key plus modifiers, or "cmd+s" in one.
            let (key, written) = try Self.parseShortcut(subject)
            let modifiers = Array(Set(written + (draft.modifiers ?? []).map(\.modifierKey)))
                .sorted { $0.rawValue < $1.rawValue }
            return modifiers.isEmpty ? .pressKey(key) : .hotkey(key: key, modifiers: modifiers)

        case .scroll:
            let amount = draft.scrollAmount ?? -3
            guard amount != 0 else {
                throw .undecodableStep("A scroll of zero would do nothing.")
            }
            let target = try scrollTarget(subject, context: context)
            return .scroll(target: target, deltaX: 0, deltaY: amount)

        case .openURL:
            guard let address = subject else {
                throw .undecodableStep("openURL needs the web address as its subject.")
            }
            return .nativeAction(.openURL(Self.normalizeURL(address)))

        case .askCopilot:
            // The on-device model reliably chooses askCopilot for a Copilot goal and then, just as
            // reliably, leaves the question out. The user's own goal is a fair question to send in
            // that case — and it is safe to, because a bridge handoff is always shown in full and
            // confirmed before anything leaves the machine.
            guard let prompt = subject ?? goal?.trimmed, !prompt.isEmpty else {
                throw .undecodableStep("askCopilot needs the question as its subject.")
            }
            return .askAIBridge(bridge: .copilot, prompt: prompt)

        case .wait:
            // Clamped rather than rejected: an over-long wait is a harmless misjudgement, and
            // failing the step would waste a planning turn on it.
            let seconds = subject.flatMap(Self.firstNumber) ?? 1
            return .wait(seconds: min(max(seconds, 0.1), 10))

        case .readScreen:
            return .readScreen

        case .askUser:
            guard let question = subject else {
                throw .undecodableStep("askUser needs the question as its subject.")
            }
            return .requestUserInput(prompt: question)

        case .complete:
            return .complete(summary: subject ?? "Done.")

        case .fail:
            return .fail(reason: subject ?? "AbleKit could not complete this.")
        }
    }

    // MARK: - Typed text

    /// Words a model writes in place of the text itself.
    private static let placeholderTexts: Set<String> =
        Set(PlannedActionKind.allCases.map { $0.rawValue.lowercased() })
        .union(["text", "subject", "the text", "name", "the name", "none"])

    /// Corrects the two ways the model gets typed text wrong, using only what the goal says.
    ///
    /// Asked to name a folder "Eval Folder", the model once typed `eval` and, on another run, the
    /// literal word `typeText`. Both are recoverable without guessing, because the right text is
    /// written in the goal:
    ///
    /// - a placeholder instead of content is replaced by the goal's text, when there is exactly one;
    /// - a clipped fragment of a phrase from the goal is replaced by the whole phrase.
    ///
    /// Anything else is typed as the model wrote it — including text the goal never mentions,
    /// which is often legitimate ("reply saying I'll be late").
    static func reconcileTypedText(_ typed: String, literals: [String]) throws(IntelligenceError) -> String {
        let trimmed = typed.trimmed
        if trimmed.isEmpty || placeholderTexts.contains(trimmed.lowercased()) {
            if literals.count == 1 { return literals[0] }
            throw .undecodableStep("typeText needs the exact text to type as its subject.")
        }
        let lowered = trimmed.lowercased()
        if let whole = literals.first(where: { literal in
            literal.count > trimmed.count && literal.lowercased().contains(lowered)
        }) {
            return whole
        }
        // Not trimmed: leading and trailing spaces can be meant.
        return typed
    }

    // MARK: - Resolving menu commands

    /// Turns `File > New` into the exact titles of a command the app actually has.
    ///
    /// The planner's spelling is checked against the menu bar rather than trusted, so a command
    /// that does not exist, or is greyed out, costs one re-plan instead of a failed action.
    private func resolveMenuItem(_ subject: String?, context: DesktopContext)
        throws(IntelligenceError) -> [String]
    {
        let requested = Self.parseMenuPath(subject ?? "")
        guard !requested.isEmpty else {
            throw .undecodableStep("chooseMenuItem needs the menu path, such as File > New, as its subject.")
        }
        guard let menus = context.accessibility, !menus.menuItems.isEmpty else {
            throw .undecodableStep("This app's menus could not be read; use a control or a shortcut instead.")
        }
        guard let item = menus.menuItem(matching: requested) else {
            let app = context.frontmostApplication?.localizedName ?? "the app in front"
            throw .undecodableStep(
                "\(app) has no menu command \(requested.joined(separator: " > ").quoted). The menus listed are \(app)'s; to use another app's menus, open that app first."
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

    // MARK: - Resolving targets

    /// What a click should aim at: a control, or a piece of recognised screen text.
    ///
    /// Text ids (`t4`) resolve to the centre of that text on screen. The router may still upgrade the
    /// click to an Accessibility press if a control turns out to sit at that position.
    private func resolveTarget(_ subject: String?, kind: PlannedActionKind, context: DesktopContext)
        throws(IntelligenceError) -> PointerTarget
    {
        guard let raw = subject.map(Self.stripBrackets), !raw.isEmpty else {
            throw .undecodableStep("\(kind.rawValue) needs the id of a control, such as e12, as its subject.")
        }
        if raw.hasPrefix("t"), Int(raw.dropFirst()) != nil {
            guard let region = context.screen?.textRegion(withID: raw) else {
                throw .undecodableStep(
                    "There is no screen text \(raw.quoted) now. Look at the current list and pick another."
                )
            }
            return .point(region.frame.center)
        }
        return .element(try resolveElement(raw, context: context))
    }

    /// Finds the element an id refers to.
    ///
    /// Models name things inconsistently: sometimes the id `e12`, sometimes `[e12]`, and often the
    /// label `"Save"` instead. All three are accepted, because the alternative is failing a step
    /// over a formatting detail when the intent is unambiguous.
    private func resolveElement(_ raw: String, context: DesktopContext) throws(IntelligenceError)
        -> ElementReference
    {
        guard let snapshot = context.accessibility else {
            throw .undecodableStep("There are no readable controls in this app to act on.")
        }
        let identifier = Self.stripBrackets(raw)
        if let element = snapshot.element(withID: identifier) {
            return element
        }
        // The model may have quoted the label instead of the id.
        if let element = snapshot.bestMatch(forLabel: identifier.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D}"))) {
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
    ///
    /// A "field" that is not a text input is ignored rather than used. The model once named
    /// Calculator's = button as the place to type; focusing it would have meant clicking it, so the
    /// text goes to the app instead, which is what typing into Calculator means anyway.
    private func typingDestination(_ draft: PlannedStepDraft, context: DesktopContext)
        throws(IntelligenceError) -> ElementReference?
    {
        if let raw = draft.field?.trimmed, !raw.isEmpty, Self.stripBrackets(raw).lowercased() != "none" {
            let element = try resolveElement(raw, context: context)
            if element.isTextInput || element.role == "AXWebArea" {
                return element
            }
        }
        let elements = context.accessibility?.elements ?? []
        let hasFocusedInput = elements.contains { $0.isFocused && $0.isTextInput }
        let hasInputs = elements.contains { $0.isTextInput && $0.isEnabled }
        if hasInputs && !hasFocusedInput {
            throw .undecodableStep(
                "No field has focus, so the text would go nowhere useful. Put the id of the field to type into in field."
            )
        }
        return nil
    }

    /// Where to aim a scroll.
    ///
    /// Scrolling needs a position because macOS delivers the event to whatever is under the
    /// pointer. Falling back to the focused window's centre is what a person would do.
    private func scrollTarget(_ subject: String?, context: DesktopContext)
        throws(IntelligenceError) -> PointerTarget
    {
        if let subject, let target = try? resolveTarget(subject, kind: .scroll, context: context) {
            return target
        }
        if let window = context.focusedWindow, window.frame.width > 0 {
            return .point(window.frame.center)
        }
        if let display = context.arrangement.primary {
            return .point(display.bounds.center)
        }
        throw .undecodableStep("There is nowhere to scroll: no window or display was found.")
    }

    static func stripBrackets(_ raw: String) -> String {
        raw.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
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

    /// Reads a shortcut written as `cmd+s`, `⌘S`, `shift+command+z`, or just a key.
    static func parseShortcut(_ text: String) throws(IntelligenceError) -> (Key, [ModifierKey]) {
        let names: [String: ModifierKey] = [
            "cmd": .command, "command": .command, "\u{2318}": .command,
            "shift": .shift, "\u{21E7}": .shift,
            "opt": .option, "option": .option, "alt": .option, "\u{2325}": .option,
            "ctrl": .control, "control": .control, "\u{2303}": .control,
        ]
        var remainder = text.trimmed
        var modifiers: [ModifierKey] = []

        // Symbol prefixes, as menus show them: ⇧⌘S.
        while let first = remainder.first, let modifier = names[String(first)] {
            modifiers.append(modifier)
            remainder.removeFirst()
        }

        let parts = remainder.split(separator: "+").map { String($0).trimmed }.filter { !$0.isEmpty }
        guard let last = parts.last else {
            throw .undecodableStep("\(text.quoted) does not name a key.")
        }
        for part in parts.dropLast() {
            guard let modifier = names[part.lowercased()] else {
                throw .undecodableStep("\(part.quoted) is not a modifier key.")
            }
            modifiers.append(modifier)
        }
        return (try parseKey(last), modifiers)
    }

    /// Reads a position written as `400, 300`, `(400,300)` or `x=400 y=300`.
    static func parsePoint(_ text: String) -> CGPoint? {
        let numbers = numbers(in: text)
        guard numbers.count == 2 else { return nil }
        return CGPoint(x: numbers[0], y: numbers[1])
    }

    static func firstNumber(_ text: String) -> Double? {
        numbers(in: text).first
    }

    private static func numbers(in text: String) -> [Double] {
        var results: [Double] = []
        var current = ""
        for character in text + " " {
            if character.isNumber || (character == "." && !current.isEmpty) || (character == "-" && current.isEmpty) {
                current.append(character)
            } else {
                if let value = Double(current) { results.append(value) }
                current = ""
            }
        }
        return results
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
