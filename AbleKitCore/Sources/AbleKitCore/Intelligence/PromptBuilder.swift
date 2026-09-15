import Foundation

/// Turns a `DesktopContext` into the text a model actually reads.
///
/// This is where AbleKit decides what the model gets to know, and it matters more than it looks.
/// An on-device model has a small context window, so the job is not "describe the screen" but
/// "describe the few things that could plausibly be acted on next". Three rules follow from that:
///
/// - **Semantic before pixels.** Accessibility elements come first and carry stable ids, so the
///   model can name a target instead of guessing a coordinate.
/// - **OCR is a fallback, and is labelled as one.** Screen text is included only when it adds
///   something the element list does not, so the model is not tempted to aim at a word.
/// - **Failures are stated plainly.** The history says what did not work, because the single
///   biggest failure mode of a single-step planner is cheerfully retrying the same broken idea.
///
/// It is a pure function of its inputs, so what the model saw is reproducible in the debug
/// interface and testable without a model.
public struct PromptBuilder: Sendable {

    /// Caps that keep a prompt inside the model's context window.
    public struct Budget: Sendable, Equatable {
        /// Most Accessibility elements to list.
        public var maximumElements: Int
        /// Most characters of OCR text to include.
        public var maximumScreenTextCharacters: Int
        /// Most history entries to include, counting back from the most recent.
        public var maximumHistoryEntries: Int
        /// Most characters of any single gathered value, such as a Copilot answer.
        public var maximumGatheredCharacters: Int
        /// Most characters of selected text or clipboard content.
        public var maximumSnippetCharacters: Int

        public init(
            maximumElements: Int = 40,
            maximumScreenTextCharacters: Int = 1500,
            maximumHistoryEntries: Int = 8,
            maximumGatheredCharacters: Int = 2000,
            maximumSnippetCharacters: Int = 500
        ) {
            self.maximumElements = maximumElements
            self.maximumScreenTextCharacters = maximumScreenTextCharacters
            self.maximumHistoryEntries = maximumHistoryEntries
            self.maximumGatheredCharacters = maximumGatheredCharacters
            self.maximumSnippetCharacters = maximumSnippetCharacters
        }

        public static let `default` = Budget()
    }

    private let budget: Budget

    public init(budget: Budget = .default) {
        self.budget = budget
    }

    // MARK: - Planning

    /// The standing instructions given to the planner once per session.
    ///
    /// The ordering here was arrived at by watching the on-device model fail. Given a list of
    /// controls and a goal, its first instinct is to click one of them — so when the goal was
    /// "ask Copilot about this", it reached for the nearest button instead. The fix is to make
    /// *whether the interface is needed at all* the first question asked, before the controls are
    /// ever considered. Launching an app, opening an address and asking another assistant are all
    /// things done directly, and a planner that starts from the control list will not see that.
    public static let planningInstructions = """
        You decide the single next step for AbleKit, a macOS automation agent.

        Ask these in order, and stop at the first that applies:

        1. Is the goal already achieved? Then complete. Never act merely to confirm what is \
        already true.
        2. Does the goal involve Copilot? Then use askCopilot, with the question in the text. \
        AbleKit opens and operates Copilot itself: never open Copilot yourself, and never type the \
        question into the app you are looking at.
        3. Can the goal be reached without touching the interface? Launching an application or \
        opening a web address are done directly. Do not click a control merely because one is listed.
        4. Does it need something only the user knows? Then ask them.
        5. Is it impossible? Then fail, and say why.
        6. Otherwise, operate the interface: act on a listed control by its id, and use a screen \
        position only when no listed control fits.

        Always:
        - Do exactly one step. You will see the result and be asked again.
        - Fill in every field your step needs: typeText needs the text, askCopilot and askUser need \
        the question, openApplication needs the name.
        - Prefer the least risky action that makes progress. Never guess at a destructive step.
        - Never repeat a step the history shows already failed; find a different route.

        Be brief. The rationale is one short sentence a person will read while waiting.

        Worked examples.

        Goal: "Make sure Mail is frontmost" when Mail is already frontmost.
          kind: complete, text: "Mail is already frontmost."
          Not a click. Nothing is needed, so nothing is done.

        Goal: "Ask Copilot what the risks are here."
          kind: askCopilot, text: "What are the risks for this programme?"
          Not openApplication. AbleKit opens and operates Copilot itself.

        Goal: "Open Safari."
          kind: openApplication, applicationName: "Safari"
          The name is always filled in.

        Goal: "Change the status to Amber", with [e2] text field "Status" listed.
          kind: clickElement, elementID: "e2"
          A listed control is named by its id, never by its position.
        """

    /// The standing instructions given to the verifier.
    public static let verificationInstructions = """
        You judge whether a macOS action did what it was meant to do, by comparing the screen \
        before and after.

        Answer succeeded, failed, or inconclusive. Choose inconclusive honestly when the \
        observable difference does not settle it — a wrong confident answer is worse than \
        admitting the screen does not say.
        """

    /// Builds the planning prompt.
    public func planningPrompt(goal: String, context: AgentContext) -> String {
        var sections: [String] = []

        sections.append("GOAL: \(goal)")
        sections.append("STEP \(context.stepIndex + 1) of at most \(context.stepLimit)")

        sections.append(describeDesktop(context.desktop))

        if let elements = describeElements(context.desktop) {
            sections.append(elements)
        }

        if let screenText = describeScreenText(context.desktop) {
            sections.append(screenText)
        }

        if let gathered = describeGathered(context.gatheredInformation) {
            sections.append(gathered)
        }

        if let history = describeHistory(context.history) {
            sections.append(history)
        }

        sections.append("What is the single next step?")
        return sections.joined(separator: "\n\n")
    }

    /// Builds the verification prompt.
    public func verificationPrompt(
        action: DesktopAction,
        before: DesktopContext,
        after: DesktopContext
    ) -> String {
        var sections: [String] = []
        sections.append("ACTION TAKEN: \(action.summary)")
        sections.append("BEFORE:\n\(describeDesktop(before, heading: false))")
        sections.append("AFTER:\n\(describeDesktop(after, heading: false))")

        if before.stateFingerprint == after.stateFingerprint {
            // Stated explicitly because it is the single most informative signal available, and a
            // small model will not reliably notice it by diffing two descriptions itself.
            sections.append("NOTE: The screen appears unchanged.")
        }

        if let changes = describeChanges(from: before, to: after) {
            sections.append(changes)
        }

        sections.append("Did the action do what it was meant to?")
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Sections

    private func describeDesktop(_ context: DesktopContext, heading: Bool = true) -> String {
        var lines: [String] = []
        if heading { lines.append("CURRENT DESKTOP:") }

        if let app = context.frontmostApplication {
            let bundle = app.bundleIdentifier.map { " (\($0))" } ?? ""
            lines.append("Frontmost app: \(app.localizedName)\(bundle)")
        } else {
            lines.append("Frontmost app: unknown")
        }

        if let window = context.focusedWindow {
            lines.append("Window: \(window.title?.quoted ?? "untitled")")
        }

        if let selected = context.selectedText?.trimmed, !selected.isEmpty {
            lines.append("Selected text: \(selected.truncated(to: budget.maximumSnippetCharacters).quoted)")
        }

        if let clipboard = context.clipboard?.text?.trimmed, !clipboard.isEmpty {
            lines.append("Clipboard: \(clipboard.truncated(to: budget.maximumSnippetCharacters).quoted)")
        }

        if !context.finderSelection.isEmpty {
            let names = context.finderSelection
                .prefix(5)
                .map { ($0 as NSString).lastPathComponent }
                .joined(separator: ", ")
            lines.append("Selected in Finder: \(names)")
        }

        let otherApps = context.visibleWindows
            .compactMap(\.owningApplication)
            .filter { $0 != context.frontmostApplication?.localizedName }
        if !otherApps.isEmpty {
            let unique = Array(Set(otherApps)).sorted().prefix(8)
            lines.append("Also open: \(unique.joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }

    private func describeElements(_ context: DesktopContext) -> String? {
        guard let snapshot = context.accessibility else { return nil }
        let elements = snapshot.interactiveElements
        guard !elements.isEmpty else {
            return "CONTROLS: none readable. This app exposes nothing semantic; work from the screen text."
        }

        let shown = rank(elements).prefix(budget.maximumElements)
        var lines = ["CONTROLS (available if this step needs the interface; act on them by id):"]
        lines.append(contentsOf: shown.map(describe))

        if elements.count > shown.count {
            lines.append("\u{2026} and \(elements.count - shown.count) more not listed.")
        }
        if snapshot.wasTruncated {
            lines.append("(The control list was cut short, so something you want may exist but not be listed.)")
        }
        return lines.joined(separator: "\n")
    }

    /// Orders elements so that the most actionable ones survive the budget.
    ///
    /// Enabled controls that advertise actions come first, then text inputs, then everything else.
    /// Ties keep their original depth-first order, which tends to track reading order on screen.
    private func rank(_ elements: [ElementReference]) -> [ElementReference] {
        func priority(_ element: ElementReference) -> Int {
            if !element.isEnabled { return 3 }
            if element.isPressable { return 0 }
            if element.isTextInput { return 1 }
            return 2
        }
        return elements.enumerated()
            .sorted { lhs, rhs in
                let (leftPriority, rightPriority) = (priority(lhs.element), priority(rhs.element))
                return leftPriority != rightPriority
                    ? leftPriority < rightPriority
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func describe(_ element: ElementReference) -> String {
        var parts = ["[\(element.id)] \(element.role.friendlyRoleName)"]
        if let label = element.bestLabel {
            parts.append(label.truncated(to: 60).quoted)
        }
        if element.isTextInput, let value = element.value, !value.isEmpty {
            parts.append("containing \(value.truncated(to: 60).quoted)")
        }
        if !element.isEnabled { parts.append("(disabled)") }
        if element.isFocused { parts.append("(focused)") }
        return "  " + parts.joined(separator: " ")
    }

    private func describeScreenText(_ context: DesktopContext) -> String? {
        guard let screen = context.screen, !screen.textRegions.isEmpty else { return nil }
        let text = screen.readableText.truncated(to: budget.maximumScreenTextCharacters)
        guard !text.trimmed.isEmpty else { return nil }
        return """
            SCREEN TEXT (read from the pixels; use only when no control above fits):
            \(text)
            """
    }

    private func describeGathered(_ information: [GatheredInformation]) -> String? {
        guard !information.isEmpty else { return nil }
        var lines = ["INFORMATION GATHERED SO FAR:"]
        for item in information {
            lines.append("From \(item.source):")
            lines.append(item.text.truncated(to: budget.maximumGatheredCharacters))
        }
        return lines.joined(separator: "\n")
    }

    private func describeHistory(_ history: [StepRecord]) -> String? {
        guard !history.isEmpty else { return nil }
        let recent = history.suffix(budget.maximumHistoryEntries)
        var lines = ["WHAT HAS BEEN TRIED:"]
        if history.count > recent.count {
            lines.append("(\(history.count - recent.count) earlier steps omitted)")
        }
        for record in recent {
            lines.append("\(record.index + 1). \(record.action.summary) \u{2014} \(record.outcome.summary)")
        }
        if let lastFailure = recent.last(where: { !$0.outcome.isSuccess }) {
            lines.append("The last problem was: \(lastFailure.outcome.summary). Do not simply repeat it.")
        }
        return lines.joined(separator: "\n")
    }

    /// Names the concrete differences between two observations.
    ///
    /// Small models are poor at diffing two prose descriptions, so the diff is computed here and
    /// handed over as a fact.
    private func describeChanges(from before: DesktopContext, to after: DesktopContext) -> String? {
        var changes: [String] = []

        let beforeApp = before.frontmostApplication?.bundleIdentifier
        let afterApp = after.frontmostApplication?.bundleIdentifier
        if beforeApp != afterApp {
            let from = before.frontmostApplication?.localizedName ?? "nothing"
            let to = after.frontmostApplication?.localizedName ?? "nothing"
            changes.append("The frontmost app changed from \(from) to \(to).")
        }

        if before.focusedWindow?.title != after.focusedWindow?.title {
            changes.append(
                "The window changed from \(before.focusedWindow?.title?.quoted ?? "none") "
                    + "to \(after.focusedWindow?.title?.quoted ?? "none")."
            )
        }

        let beforeLabels = Set((before.accessibility?.interactiveElements ?? []).compactMap(\.bestLabel))
        let afterLabels = Set((after.accessibility?.interactiveElements ?? []).compactMap(\.bestLabel))
        let appeared = afterLabels.subtracting(beforeLabels).sorted().prefix(8)
        let disappeared = beforeLabels.subtracting(afterLabels).sorted().prefix(8)
        if !appeared.isEmpty {
            changes.append("New controls appeared: \(appeared.map(\.quoted).joined(separator: ", ")).")
        }
        if !disappeared.isEmpty {
            changes.append("Controls disappeared: \(disappeared.map(\.quoted).joined(separator: ", ")).")
        }

        guard !changes.isEmpty else { return nil }
        return "OBSERVED CHANGES:\n" + changes.map { "- \($0)" }.joined(separator: "\n")
    }
}
