import Foundation

/// Deterministic reading of the goal, done before the model is asked anything.
///
/// The on-device model is good at choosing a *kind* of step and poor at noticing that the goal
/// already names the thing to act on. In the first live evaluation it was told to "click Get
/// Started" and chose File › New; told to "create a new folder named Eval Folder" it chose
/// File › New Finder Window, and then named the folder "eval". In every case the answer was sitting
/// in the goal, word for word.
///
/// Finding those words is string matching, not reasoning — principle one of the brief — so it is
/// done here and handed to the planner as a hint, rather than hoped for.
public struct GoalAnalysis: Sendable, Equatable {
    /// Something on screen, or in the menus, whose name appears in the goal.
    public struct Mention: Sendable, Equatable {
        /// How the planner should refer to it: `e12`, `t3`, or a menu path.
        public let reference: String
        public let label: String
        public let kind: Kind

        public enum Kind: String, Sendable {
            case control
            case screenText = "screen text"
            case menuCommand = "menu command"
        }
    }

    public let mentions: [Mention]
    /// Text the goal asks to be typed or used as a name, exactly as written.
    public let literalTexts: [String]

    /// Shortest label worth matching. Shorter words ("OK", "New") appear in too many goals by
    /// accident to be evidence of anything.
    static let minimumLabelLength = 4
    static let maximumMentions = 6

    public init(goal: String, context: DesktopContext) {
        let normalizedGoal = Self.normalize(goal)
        var candidates: [Mention] = []

        for element in context.accessibility?.interactiveElements ?? [] where element.isEnabled {
            if let label = element.bestLabel {
                candidates.append(Mention(reference: element.id, label: label, kind: .control))
            }
        }
        for (id, region) in context.screen?.labeledTextRegions ?? [] {
            candidates.append(Mention(reference: id, label: region.string, kind: .screenText))
        }
        for item in context.accessibility?.menuItems ?? [] where item.isEnabled {
            guard let title = item.path.last else { continue }
            candidates.append(Mention(reference: item.displayPath, label: title, kind: .menuCommand))
        }

        var seen = Set<String>()
        mentions =
            candidates
            .filter { Self.goal(normalizedGoal, mentions: $0.label) }
            // Longer names are more specific: "New Folder" is better evidence than "Folder".
            .sorted { Self.normalize($0.label).count > Self.normalize($1.label).count }
            .filter { seen.insert($0.reference).inserted }
            .prefix(Self.maximumMentions)
            .map { $0 }

        literalTexts = Self.literalTexts(in: goal)
    }

    /// Whether a label appears in the goal as a whole phrase.
    static func goal(_ normalizedGoal: String, mentions label: String) -> Bool {
        let phrase = normalize(label)
        guard phrase.count >= minimumLabelLength else { return false }
        return " \(normalizedGoal) ".contains(" \(phrase) ")
    }

    /// Lowercased, ellipses and punctuation turned into spaces, whitespace collapsed.
    static func normalize(_ text: String) -> String {
        let mapped = text.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    // MARK: - Literal text

    /// Words that introduce text meant to be used exactly.
    private static let introducers = ["named", "called", "titled", "type", "typing", "write", "enter", "saying"]
    /// Words that end such a phrase when it is not quoted.
    private static let terminators: Set<String> = ["then", "and", "into", "in", "to", "on", "at", "with", "from"]

    /// Quoted strings, and phrases after "named", "type" and similar, in the order they appear.
    static func literalTexts(in goal: String) -> [String] {
        var results: [String] = []

        // Quoted text is unambiguous.
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'")]
        for (open, close) in quotePairs {
            var inside = false
            var current = ""
            for character in goal {
                if !inside, character == open {
                    inside = true
                    current = ""
                } else if inside, character == close {
                    inside = false
                    let text = current.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { results.append(text) }
                } else if inside {
                    current.append(character)
                }
            }
        }
        if !results.isEmpty { return unique(results) }

        // Otherwise: the words after an introducer, up to punctuation or a joining word.
        let words = goal.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < words.count {
            let word = words[index].lowercased().trimmingCharacters(in: .punctuationCharacters)
            index += 1
            guard introducers.contains(word) else { continue }
            var phrase: [String] = []
            while index < words.count {
                let raw = words[index]
                let bare = raw.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if terminators.contains(bare), !phrase.isEmpty { break }
                phrase.append(raw)
                index += 1
                if let last = raw.last, ",.;:!?".contains(last) { break }
            }
            let text = phrase.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!? "))
            if !text.isEmpty { results.append(text) }
        }
        return unique(results)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - Prompt text

    /// The hint section for the planning prompt, or `nil` when there is nothing to say.
    public var promptSection: String? {
        var lines: [String] = []
        if !mentions.isEmpty {
            lines.append("NAMED IN THE GOAL (the goal refers to these; prefer them):")
            for mention in mentions {
                let reference = mention.kind == .menuCommand ? mention.reference : "[\(mention.reference)]"
                lines.append("  \(reference) \(mention.kind.rawValue) \u{201C}\(mention.label)\u{201D}")
            }
        }
        if !literalTexts.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("EXACT TEXT FROM THE GOAL (type it exactly like this, in full):")
            for text in literalTexts {
                lines.append("  \u{201C}\(text)\u{201D}")
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
