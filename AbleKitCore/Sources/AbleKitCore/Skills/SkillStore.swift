import Foundation

/// Where Skills live.
///
/// One JSON file per Skill in Application Support. That choice is deliberate: Skills are few, small
/// and user-owned, so a file the user can read, copy between Macs, or delete is worth more than a
/// database. It also means AbleKit introduces no server, no daemon, and no schema migration to get
/// wrong (brief §28).
public protocol SkillStoring: Sendable {
    func load() throws -> [Skill]
    func save(_ skill: Skill) throws
    func delete(_ id: UUID) throws
}

public struct SkillStore: SkillStoring {
    private let directory: URL

    /// `FileManager` is not `Sendable`, so the default instance is reached for per call rather
    /// than stored. Every use here is a discrete, thread-safe file operation.
    private var fileManager: FileManager { .default }

    public init(directory: URL? = nil) {
        self.directory =
            directory
            ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AbleKit/Skills", directoryHint: .isDirectory)
    }

    public func load() throws -> [Skill] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return
            files
            .filter { $0.pathExtension == "json" }
            // A single unreadable file — hand-edited into invalid JSON, say — should not hide
            // every other Skill the user has.
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Skill.self, from: data)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func save(_ skill: Skill) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var updated = skill
        updated.updatedAt = Date()
        try encoder.encode(updated).write(to: url(for: skill.id), options: .atomic)
    }

    public func delete(_ id: UUID) throws {
        let url = url(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func url(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }
}

extension Skill {
    /// Skills shipped with AbleKit, as worked examples of how one is written.
    ///
    /// They are intentionally about *intent* at every step — no coordinates, no key sequences —
    /// because they are the template anyone writing their own will copy from.
    public static let samples: [Skill] = [
        Skill(
            name: "Ask Copilot about this screen",
            summary: "Have Copilot explain what is on screen, and bring its answer back.",
            parameters: [
                SkillParameter(
                    name: "question",
                    prompt: "What should Copilot be asked?",
                    defaultValue: "What should I be concerned about here?"
                )
            ],
            steps: [
                SkillStep(intent: "Read what the current application is showing."),
                SkillStep(
                    intent: "Ask Copilot: {question}, including the relevant details from the screen.",
                    successCriterion: "Copilot has finished answering."
                ),
                SkillStep(intent: "Summarise Copilot's answer for me."),
            ]
        ),
        Skill(
            name: "Update programme status",
            summary: "Ask Copilot for the latest on a programme, then record it in the tracker.",
            parameters: [
                SkillParameter(name: "programme", prompt: "Which programme?"),
                SkillParameter(
                    name: "tracker",
                    prompt: "Which application holds the tracker?",
                    defaultValue: "the tracker application"
                ),
            ],
            steps: [
                SkillStep(intent: "Ask Copilot what has changed recently for {programme}."),
                SkillStep(intent: "Open {tracker} and find the entry for {programme}."),
                SkillStep(intent: "Put it into edit mode."),
                SkillStep(
                    intent: "Update the status field with what Copilot reported.",
                    successCriterion: "The field shows the new status."
                ),
                SkillStep(
                    intent: "Save the entry.",
                    successCriterion: "The entry is no longer in edit mode and shows the new status."
                ),
            ]
        ),
    ]
}
