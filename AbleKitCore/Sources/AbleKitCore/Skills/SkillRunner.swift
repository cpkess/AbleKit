import Foundation

/// Turns a saved Skill into a goal the agent can pursue.
///
/// The agent loop is unchanged by Skills: a Skill becomes a well-structured goal, and every step is
/// still planned against what is actually on screen at the time. That is the whole point — a Skill
/// describes the *procedure*, and the agent works out how to carry it out in the interface it finds
/// today, rather than replaying what worked last month.
public struct SkillRunner: Sendable {

    public init() {}

    /// Why a Skill cannot be run as asked.
    public enum PreparationError: Error, Equatable, Sendable {
        /// A placeholder used in the steps has no value.
        case missingParameters([String])
        /// The Skill has nothing to do.
        case noSteps
    }

    /// Renders a Skill and its parameter values into a goal.
    public func goal(for skill: Skill, parameters values: [String: String] = [:])
        throws(PreparationError) -> String
    {
        guard !skill.steps.isEmpty else { throw .noSteps }

        let resolved = resolvedValues(for: skill, provided: values)
        let missing = skill.referencedPlaceholders.filter { placeholder in
            resolved[placeholder]?.trimmed.isEmpty != false
        }
        guard missing.isEmpty else { throw .missingParameters(missing) }

        let steps = skill.steps.enumerated().map { index, step in
            var line = "\(index + 1). \(Self.substitute(step.intent, with: resolved))"
            if let criterion = step.successCriterion?.trimmed, !criterion.isEmpty {
                line += " (done when: \(Self.substitute(criterion, with: resolved)))"
            }
            return line
        }

        return """
            \(Self.substitute(skill.summary, with: resolved))

            Work through these in order, checking each one before moving on:
            \(steps.joined(separator: "\n"))
            """
    }

    /// Parameter values, with the Skill's defaults filling in anything not supplied.
    public func resolvedValues(for skill: Skill, provided: [String: String]) -> [String: String] {
        var resolved: [String: String] = [:]
        for parameter in skill.parameters {
            if let value = provided[parameter.name]?.trimmed, !value.isEmpty {
                resolved[parameter.name] = value
            } else if let fallback = parameter.defaultValue?.trimmed, !fallback.isEmpty {
                resolved[parameter.name] = fallback
            }
        }
        // A value may be supplied for a placeholder that was never declared as a parameter, which
        // is a reasonable thing for a caller to do and should not be silently dropped.
        for (name, value) in provided where resolved[name] == nil {
            let trimmed = value.trimmed
            if !trimmed.isEmpty { resolved[name] = trimmed }
        }
        return resolved
    }

    /// The `{placeholder}` names in a piece of text, in order.
    static func placeholders(in text: String) -> [String] {
        var names: [String] = []
        var current: String?
        for character in text {
            switch character {
            case "{":
                current = ""
            case "}":
                if let name = current?.trimmed, !name.isEmpty { names.append(name) }
                current = nil
            default:
                current?.append(character)
            }
        }
        return names
    }

    /// Replaces `{name}` with its value, leaving unknown placeholders in place so that a missing
    /// value is visible in the goal rather than silently becoming an empty string.
    static func substitute(_ text: String, with values: [String: String]) -> String {
        var result = text
        for (name, value) in values {
            result = result.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return result
    }
}
