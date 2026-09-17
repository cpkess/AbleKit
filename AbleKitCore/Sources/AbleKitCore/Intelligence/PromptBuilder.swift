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
        /// Most characters of the menu listing.
        public var maximumMenuCharacters: Int

        public init(
            maximumElements: Int = 40,
            maximumScreenTextCharacters: Int = 2500,
            maximumHistoryEntries: Int = 8,
            maximumGatheredCharacters: Int = 2000,
            maximumSnippetCharacters: Int = 500,
            maximumMenuCharacters: Int = 1600
        ) {
            self.maximumElements = maximumElements
            self.maximumScreenTextCharacters = maximumScreenTextCharacters
            self.maximumHistoryEntries = maximumHistoryEntries
            self.maximumGatheredCharacters = maximumGatheredCharacters
            self.maximumSnippetCharacters = maximumSnippetCharacters
            self.maximumMenuCharacters = maximumMenuCharacters
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
        6. Otherwise, operate the interface. Prefer, in order: a command listed under MENUS; a \
        control listed under CONTROLS, by its id; a keyboard shortcut; and only then a screen position.

        Always:
        - Do exactly one step. You will see the result and be asked again.
        - If the controls and menus do not show what you need — a document's content, a list drawn \
        by the app — use readScreen, and the text on screen will be listed next time.
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

        Goal: "Start a new document", with File: New listed under MENUS.
          kind: chooseMenuItem, text: "File > New"
          A menu command is the most reliable way to do something an app offers.

        Goal: "Change the status to Amber", with [e2] text field "Status" listed.
          kind: typeText, elementID: "e2", text: "Amber"
          Name the field when typing; AbleKit puts the cursor there first. A listed control is \
        always named by its id, never by its position.
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

        if let menus = describeMenus(context.desktop) {
            sections.append(menus)
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

    /// The app's menu commands, grouped by menu and trimmed to the budget.
    ///
    /// Disabled commands are left out: they cannot be chosen, and every one listed is one fewer
    /// that fits. Shortcuts are left out too — choosing the command is more reliable than pressing
    /// its keys, so there is no reason to spend the space.
    private func describeMenus(_ context: DesktopContext) -> String? {
        guard let items = context.accessibility?.menuItems.filter(\.isEnabled), !items.isEmpty else {
            return nil
        }
        var order: [String] = []
        var grouped: [String: [String]] = [:]
        for item in items {
            guard let menu = item.path.first else { continue }
            if grouped[menu] == nil { order.append(menu) }
            grouped[menu, default: []].append(item.path.dropFirst().joined(separator: " > "))
        }

        var lines = ["MENUS (use chooseMenuItem with the full path, e.g. \"File > New\"):"]
        var used = lines[0].count
        for menu in order {
            let line = "  \(menu): " + (grouped[menu] ?? []).joined(separator: ", ")
            guard used + line.count <= budget.maximumMenuCharacters else {
                lines.append("  \u{2026} more menus not listed.")
                break
            }
            lines.append(line)
            used += line.count
        }
        return lines.joined(separator: "\n")
    }

    /// Text read from the pixels, each piece with an id the planner can click.
    ///
    /// Positions are given too: they let the planner reason about layout ("the button to the right
    /// of the name"), and they are what the decoder clicks when a `t` id is chosen.
    private func describeScreenText(_ context: DesktopContext) -> String? {
        guard let screen = context.screen, !screen.textRegions.isEmpty else { return nil }
        var lines = [
            "SCREEN TEXT (read from the pixels; click one with clickElement and its t id, only when no control or menu fits):"
        ]
        var used = 0
        for (id, region) in screen.labeledTextRegions {
            let line = "  [\(id)] \(region.string.truncated(to: 60).quoted) at (\(Int(region.frame.midX)), \(Int(region.frame.midY)))"
            guard used + line.count <= budget.maximumScreenTextCharacters else {
                lines.append("  \u{2026} more text not listed.")
                break
            }
            lines.append(line)
            used += line.count
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : nil
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
        // Headed as progress, not as "attempts": framed as things tried, the model read a verified
        // success as something still to be done, and kept doing it.
        var lines = ["STEPS ALREADY TAKEN (\u{2713} means it was checked and worked):"]
        if history.count > recent.count {
            lines.append("(\(history.count - recent.count) earlier steps omitted)")
        }
        for record in recent {
            let mark = record.outcome.isSuccess ? "\u{2713}" : "\u{2717}"
            lines.append("\(mark) \(record.action.summary) \u{2014} \(record.outcome.summary)")
        }
        if let last = recent.last {
            if case .skipped(let reason) = last.outcome {
                lines.append(reason)
            } else if last.outcome.isSuccess {
                lines.append(
                    "The last step worked. If the goal is now achieved, complete. Never repeat a step marked \u{2713}."
                )
            } else {
                lines.append("The last step did not work (\(last.outcome.summary)). Do not simply repeat it.")
            }
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
