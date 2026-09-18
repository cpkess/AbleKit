import Foundation

/// Checks a claim that the goal is finished against what is actually observable.
///
/// The on-device model, asked whether a goal was reached, will echo the goal back as though it had
/// happened: it reported "a new folder named Eval Folder was created" while the screen showed
/// *untitled folder*, and "calculated 12 times 7 and copied the result" with an untouched
/// Calculator. A false "finished" is the most costly mistake the agent can make — it stops with the
/// work undone and says it succeeded — so the claim is tested before it is believed.
///
/// Only claims that *can* be checked are checked. Where the goal gives nothing observable to look
/// for, the model's judgement stands.
public enum GoalEvidence {

    /// Words that ask for something to end up on the clipboard.
    private static let copyWords: Set<String> = ["copy", "copied", "copying"]

    /// Why a claim of completion cannot be believed, or `nil` if there is no contradiction.
    public static func contradiction(ofCompletedGoal goal: String, in context: DesktopContext)
        -> String?
    {
        if let missing = missingLiteralText(goal: goal, context: context) {
            return "the goal's text \(missing.quoted) is nowhere on screen"
        }
        if asksToCopy(goal), context.clipboard?.text?.trimmed.isEmpty != false {
            return "the goal asks for something to be copied and the clipboard is empty"
        }
        return nil
    }

    /// Text the goal asked to be typed or used as a name, which is nowhere to be found.
    ///
    /// Searched for in the controls, the text read from the screen, and the clipboard — the three
    /// places the result of typing something can show up.
    static func missingLiteralText(goal: String, context: DesktopContext) -> String? {
        let literals = GoalAnalysis.literalTexts(in: goal)
        guard !literals.isEmpty else { return nil }

        var haystack: [String] = []
        for element in context.accessibility?.elements ?? [] {
            haystack.append(contentsOf: [element.title, element.value, element.elementDescription].compactMap { $0 })
        }
        haystack.append(contentsOf: (context.screen?.textRegions ?? []).map(\.string))
        if let clipboard = context.clipboard?.text { haystack.append(clipboard) }
        if let window = context.focusedWindow?.title { haystack.append(window) }
        let combined = haystack.joined(separator: "\n").lowercased()

        return literals.first { !combined.contains($0.lowercased()) }
    }

    static func asksToCopy(_ goal: String) -> Bool {
        let words = goal.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.contains { copyWords.contains($0) }
    }
}
