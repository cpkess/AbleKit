import Foundation

/// The ordered work a task is trying to get through, and where it has got to.
///
/// AbleKit plans at two levels, and the split matters. This is the *what*: a short list of
/// sub-goals written by looking at the app before anything is touched — "clear the display",
/// "enter 12", "press equals", "copy the result". The *how* is decided one action at a time against
/// the live screen, as it always was.
///
/// Without this, the model had to work out where it was in a task from a list of past steps on
/// every turn. It is poor at that: asked to work something out and then copy it, it copied first;
/// asked to press a sequence of buttons, it pressed the same one repeatedly. Holding the position
/// here, rather than asking the model to re-derive it, is what makes multi-part tasks work.
///
/// A plan is a guide, never a script. Every action is still chosen against what is on screen, and
/// the plan is rewritten whenever reality stops matching it.
public struct TaskPlan: Sendable, Equatable {

    /// One piece of work, in the user's terms rather than in clicks.
    public struct Step: Sendable, Equatable, Identifiable {
        public let id: UUID
        /// What this step is trying to achieve, e.g. "Enter 12".
        public var intent: String
        public var isDone: Bool
        /// How many actions have been spent on it, which is what triggers a rethink.
        public var attempts: Int

        public init(id: UUID = UUID(), intent: String, isDone: Bool = false, attempts: Int = 0) {
            self.id = id
            self.intent = intent
            self.isDone = isDone
            self.attempts = attempts
        }
    }

    public private(set) var steps: [Step]
    /// How many times the plan has been rewritten, so that rewriting cannot itself become a loop.
    public private(set) var revisions: Int

    public init(intents: [String], revisions: Int = 0) {
        self.steps = Self.tidy(intents).map { Step(intent: $0) }
        self.revisions = revisions
    }

    /// Cleans up what the model wrote: blank steps, steps repeated back to back, and steps that
    /// only open an app the agent is already in.
    ///
    /// The model produced all three in one live plan — "enter 12" twice, and two steps for opening
    /// the app it was already looking at.
    static func tidy(_ intents: [String]) -> [String] {
        var result: [String] = []
        for raw in intents {
            let intent = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !intent.isEmpty, !isOpeningAnApp(intent) else { continue }
            if let last = result.last,
                last.compare(intent, options: .caseInsensitive) == .orderedSame
            {
                continue
            }
            result.append(intent)
        }
        return result
    }

    /// Whether a step only opens an application — which the agent handles itself.
    ///
    /// Narrow on purpose: "open the file" and "open the entry for Atlas" are real work, and an
    /// earlier, looser rule threw them away. Only an installed application's name, or an explicit
    /// "app", counts.
    static func isOpeningAnApp(
        _ intent: String,
        applications: [String] = ApplicationLocator.installedApplicationNames
    ) -> Bool {
        let words = intent.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard let first = words.first, ["open", "launch", "start"].contains(first) else {
            return false
        }
        let rest = words.dropFirst().filter { $0 != "the" && $0 != "a" }
        if rest.contains("app") || rest.contains("application") { return true }
        let remainder = rest.joined(separator: " ")
        guard !remainder.isEmpty else { return false }
        return applications.contains { $0.lowercased() == remainder }
    }

    public var isEmpty: Bool { steps.isEmpty }

    /// The step being worked on: the first one not yet done.
    public var current: Step? {
        steps.first { !$0.isDone }
    }

    /// Whether every step is done.
    public var isComplete: Bool {
        !steps.isEmpty && steps.allSatisfy(\.isDone)
    }

    public var completedCount: Int {
        steps.filter(\.isDone).count
    }

    /// Human-readable position, for the task window: "Step 2 of 5".
    public var positionDescription: String? {
        guard let current, let index = steps.firstIndex(where: { $0.id == current.id }) else {
            return nil
        }
        return "Step \(index + 1) of \(steps.count)"
    }

    /// Marks the current step done and moves to the next.
    public mutating func completeCurrent() {
        guard let index = steps.firstIndex(where: { !$0.isDone }) else { return }
        steps[index].isDone = true
    }

    /// Records that an action was spent on the current step.
    public mutating func recordAttempt() {
        guard let index = steps.firstIndex(where: { !$0.isDone }) else { return }
        steps[index].attempts += 1
    }

    /// Whether the current step has been worked at for long enough to suspect the plan is wrong.
    public func currentStepIsStuck(afterAttempts limit: Int) -> Bool {
        (current?.attempts ?? 0) >= limit
    }

    /// Replaces the remaining steps, keeping what has already been done.
    ///
    /// Completed steps are kept deliberately: they are the record of what the screen has already
    /// been through, and a rewrite that forgot them would repeat work.
    public mutating func replaceRemaining(with intents: [String]) {
        let done = steps.filter(\.isDone)
        let fresh = intents
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { Step(intent: $0) }
        steps = done + fresh
        revisions += 1
    }

    /// The plan as the planner sees it, with the current step marked.
    public func description(markingCurrent: Bool = true) -> String {
        steps.enumerated()
            .map { index, step in
                let isCurrent = markingCurrent && !step.isDone && step.id == current?.id
                let mark = step.isDone ? "\u{2713}" : (isCurrent ? "\u{2192}" : " ")
                return "  \(mark) \(index + 1). \(step.intent)"
            }
            .joined(separator: "\n")
    }
}
