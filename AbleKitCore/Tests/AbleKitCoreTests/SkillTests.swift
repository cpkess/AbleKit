import Foundation
import Testing

@testable import AbleKitCore

private let skill = Skill(
    name: "Update programme status",
    summary: "Record the latest status for {programme}.",
    parameters: [
        SkillParameter(name: "programme", prompt: "Which programme?"),
        SkillParameter(name: "tracker", prompt: "Which tracker?", defaultValue: "Tracker"),
    ],
    steps: [
        SkillStep(intent: "Open {tracker} and find {programme}."),
        SkillStep(intent: "Update the status.", successCriterion: "The entry shows the new status."),
    ]
)

@Suite("Skills")
struct SkillTests {
    private let runner = SkillRunner()

    @Test("A Skill renders into an ordered goal with its values filled in")
    func rendersGoal() throws {
        let goal = try runner.goal(for: skill, parameters: ["programme": "Atlas"])

        #expect(goal.contains("Record the latest status for Atlas."))
        #expect(goal.contains("1. Open Tracker and find Atlas."))
        #expect(goal.contains("2. Update the status. (done when: The entry shows the new status.)"))
    }

    @Test("A missing value is reported by name rather than rendered as a blank")
    func reportsMissingParameters() {
        #expect(throws: SkillRunner.PreparationError.missingParameters(["programme"])) {
            try runner.goal(for: skill)
        }
    }

    @Test("Defaults fill in for values the user did not supply")
    func usesDefaults() throws {
        let values = runner.resolvedValues(for: skill, provided: ["programme": "Atlas"])
        #expect(values["tracker"] == "Tracker")
    }

    @Test("A supplied value overrides the default")
    func overridesDefaults() throws {
        let values = runner.resolvedValues(
            for: skill, provided: ["programme": "Atlas", "tracker": "Jira"]
        )
        #expect(values["tracker"] == "Jira")
    }

    @Test("A Skill with no steps is refused")
    func rejectsEmptySkill() {
        let empty = Skill(name: "Nothing", summary: "", steps: [])
        #expect(throws: SkillRunner.PreparationError.noSteps) { try runner.goal(for: empty) }
    }

    @Test("Placeholders are read from the steps, in the order they appear")
    func findsPlaceholders() {
        #expect(skill.referencedPlaceholders == ["tracker", "programme"])
        #expect(SkillRunner.placeholders(in: "no placeholders here").isEmpty)
        #expect(SkillRunner.placeholders(in: "{a} and {b} and {a}") == ["a", "b", "a"])
    }

    @Test("The bundled sample Skills are valid and free of coordinates")
    func samplesAreWellFormed() throws {
        for sample in Skill.samples {
            #expect(!sample.steps.isEmpty)
            let values = Dictionary(
                uniqueKeysWithValues: sample.parameters.map { ($0.name, "value") }
            )
            let goal = try runner.goal(for: sample, parameters: values)
            #expect(!goal.contains("{"))
            // A Skill is a set of intentions; a recorded coordinate in one would defeat the point.
            for step in sample.steps {
                #expect(!step.intent.contains(where: \.isNumber) || !step.intent.contains(","))
            }
        }
    }
}

@Suite("Skill storage")
struct SkillStoreTests {

    private func temporaryStore() -> (SkillStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "AbleKitTests-\(UUID().uuidString)")
        return (SkillStore(directory: directory), directory)
    }

    @Test("A saved Skill comes back")
    func savesAndLoads() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.save(skill)
        let loaded = try store.load()

        #expect(loaded.count == 1)
        #expect(loaded[0].id == skill.id)
        #expect(loaded[0].steps.count == 2)
    }

    @Test("An empty store is empty, not an error")
    func emptyStore() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try store.load().isEmpty)
    }

    @Test("Deleting removes it, and deleting again is harmless")
    func deletes() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.save(skill)
        try store.delete(skill.id)
        #expect(try store.load().isEmpty)
        try store.delete(skill.id)
    }

    @Test("One corrupt file does not hide the others")
    func toleratesCorruptFile() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.save(skill)
        try Data("not json".utf8).write(
            to: directory.appending(path: "\(UUID().uuidString).json")
        )

        #expect(try store.load().count == 1)
    }

    @Test("Skills come back in a stable, readable order")
    func sortsByName() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.save(Skill(name: "Zebra", summary: "", steps: [SkillStep(intent: "x")]))
        try store.save(Skill(name: "Apple", summary: "", steps: [SkillStep(intent: "x")]))

        #expect(try store.load().map(\.name) == ["Apple", "Zebra"])
    }
}
