import AbleKitCore
import SwiftUI

/// What the user chose to start.
enum PaletteRequest {
    /// Free text typed into the field.
    case goal(String)
    /// A saved Skill, with values for its parameters.
    case skill(Skill, parameters: [String: String])
}

/// The way into AbleKit: one field, one question.
///
/// Modelled on Spotlight rather than on a chat window (brief §21). The difference is not
/// decorative — a chat window invites a conversation, and AbleKit is not trying to have one. It is
/// trying to be told a task and get out of the way.
struct CommandPaletteView: View {
    let onSubmit: (PaletteRequest) -> Void
    let onDismiss: () -> Void

    @Environment(AppState.self) private var state
    @State private var goal = ""
    /// Set when a Skill needs values before it can run, which turns the palette into a short form.
    @State private var pendingSkill: Skill?
    @State private var parameterValues: [String: String] = [:]
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pendingSkill {
                parameterForm(for: pendingSkill)
            } else {
                field

                if let reason = state.blockingReason {
                    banner(reason)
                } else if !suggestions.isEmpty {
                    Divider().padding(.horizontal, 12)
                    suggestionList
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .onAppear {
            isFieldFocused = true
            consumePreselectedSkill()
        }
        .onChange(of: state.pendingSkillLaunch?.id) { _, _ in consumePreselectedSkill() }
        .onExitCommand(perform: dismiss)
        .frame(width: 620)
    }

    // MARK: - Entering a goal

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.rays")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("What should I do?", text: $goal, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .regular))
                .lineLimit(1...3)
                .focused($isFieldFocused)
                .onSubmit(submitGoal)

            if !goal.isEmpty {
                Button(action: submitGoal) {
                    Image(systemName: "return")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Start")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
    }

    private func banner(_ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Set Up\u{2026}") {
                (NSApplication.shared.delegate as? AppDelegate)?.showOnboarding()
                dismiss()
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions) { suggestion in
                Button {
                    choose(suggestion)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: suggestion.symbol)
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        Text(suggestion.title)
                            .lineLimit(1)
                        Spacer()
                        if let detail = suggestion.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Running a Skill

    /// The short form shown when a Skill needs values before it can run.
    ///
    /// Asking here rather than mid-task is deliberate: these are things the user already knows, and
    /// stopping to ask for them halfway through would interrupt work that is already underway.
    private func parameterForm(for skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name).font(.headline)
                    Text(skill.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }

            ForEach(skill.parameters) { parameter in
                VStack(alignment: .leading, spacing: 4) {
                    Text(parameter.prompt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField(
                        parameter.defaultValue ?? "",
                        text: binding(for: parameter.name)
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runPendingSkill() }
                }
            }

            HStack {
                Button("Cancel") { self.pendingSkill = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Run") { runPendingSkill() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRunPendingSkill)
            }
        }
        .padding(18)
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { parameterValues[name] ?? "" },
            set: { parameterValues[name] = $0 }
        )
    }

    /// Whether every placeholder the Skill actually uses now has a value.
    private var canRunPendingSkill: Bool {
        guard let pendingSkill else { return false }
        let resolved = SkillRunner().resolvedValues(for: pendingSkill, provided: parameterValues)
        return pendingSkill.referencedPlaceholders.allSatisfy {
            resolved[$0]?.trimmingCharacters(in: .whitespaces).isEmpty == false
        }
    }

    /// Picks up a Skill chosen from the menu bar, which has no way to ask for values itself.
    private func consumePreselectedSkill() {
        guard let skill = state.pendingSkillLaunch else { return }
        state.pendingSkillLaunch = nil
        parameterValues = [:]
        pendingSkill = skill
    }

    private func choose(_ suggestion: Suggestion) {
        switch suggestion.kind {
        case .skill(let skill):
            guard !skill.parameters.isEmpty else {
                onSubmit(.skill(skill, parameters: [:]))
                reset()
                return
            }
            parameterValues = [:]
            pendingSkill = skill
        case .recentGoal(let text):
            onSubmit(.goal(text))
            reset()
        }
    }

    private func runPendingSkill() {
        guard let pendingSkill, canRunPendingSkill else { return }
        onSubmit(.skill(pendingSkill, parameters: parameterValues))
        reset()
    }

    // MARK: - Suggestions

    /// Skills whose name matches what has been typed, then goals used before.
    ///
    /// Suggestions are offered rather than pushed: the field is always free text, because the
    /// things worth automating are mostly things nobody thought to save first.
    private var suggestions: [Suggestion] {
        let query = goal.trimmingCharacters(in: .whitespaces).lowercased()

        let skills = state.skills
            .filter { query.isEmpty || $0.name.lowercased().contains(query) }
            .prefix(4)
            .map {
                Suggestion(
                    id: $0.id.uuidString,
                    title: $0.name,
                    detail: "Skill",
                    symbol: "sparkles",
                    kind: .skill($0)
                )
            }

        let recents = state.settings.recentGoals
            .filter { query.isEmpty || $0.lowercased().contains(query) }
            .prefix(query.isEmpty ? 3 : 2)
            .map {
                Suggestion(
                    id: "recent:\($0)", title: $0, detail: nil, symbol: "clock",
                    kind: .recentGoal($0)
                )
            }

        return Array(skills) + Array(recents)
    }

    private func submitGoal() {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(.goal(trimmed))
        reset()
    }

    private func dismiss() {
        if pendingSkill != nil {
            // Escape backs out of the form rather than closing the palette outright.
            pendingSkill = nil
        } else {
            onDismiss()
        }
    }

    private func reset() {
        goal = ""
        pendingSkill = nil
        parameterValues = [:]
    }

    struct Suggestion: Identifiable {
        enum Kind {
            case skill(Skill)
            case recentGoal(String)
        }

        let id: String
        let title: String
        let detail: String?
        let symbol: String
        let kind: Kind
    }
}
