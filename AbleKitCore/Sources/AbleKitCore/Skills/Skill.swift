import Foundation

/// One step of a reusable procedure, expressed as an intention.
///
/// The intention is written the way a person would describe it to a colleague — "open the
/// programme's marketing status" — and deliberately **not** as a coordinate or a recorded event.
/// Interfaces move; intentions survive. Replaying "click (673, 482)" against next quarter's
/// layout produces a confident, wrong click, which is exactly the failure a Skill is supposed to
/// be immune to (brief §23).
public struct SkillStep: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    /// What this step is meant to achieve.
    public var intent: String
    /// How to tell it worked, when that is not obvious.
    public var successCriterion: String?

    public init(id: UUID = UUID(), intent: String, successCriterion: String? = nil) {
        self.id = id
        self.intent = intent
        self.successCriterion = successCriterion
    }
}

/// A value the user supplies when running a Skill.
///
/// Parameters are what make a Skill worth saving: "Update the status of {programme}" is reusable
/// in a way that "Update the status of Atlas" is not.
public struct SkillParameter: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    /// The placeholder name, without braces.
    public var name: String
    /// What to ask the user for.
    public var prompt: String
    public var defaultValue: String?

    public init(id: UUID = UUID(), name: String, prompt: String, defaultValue: String? = nil) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.defaultValue = defaultValue
    }
}

/// A saved, reusable procedure.
public struct Skill: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    /// One line describing what it does, shown in the command palette.
    public var summary: String
    public var parameters: [SkillParameter]
    public var steps: [SkillStep]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String,
        parameters: [SkillParameter] = [],
        steps: [SkillStep],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.parameters = parameters
        self.steps = steps
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Placeholders that appear in the steps, in the order they are first used.
    ///
    /// Derived from the text rather than trusted from `parameters`, so a Skill edited by hand
    /// cannot end up asking for values it never uses, or using values it never asks for.
    public var referencedPlaceholders: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for step in steps {
            for placeholder in SkillRunner.placeholders(in: step.intent) where !seen.contains(placeholder) {
                seen.insert(placeholder)
                ordered.append(placeholder)
            }
        }
        return ordered
    }
}
