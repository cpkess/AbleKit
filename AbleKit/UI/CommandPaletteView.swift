import AbleKitCore
import SwiftUI

/// The way into AbleKit: one field, one question.
///
/// Modelled on Spotlight rather than on a chat window (brief §21). The difference is not
/// decorative — a chat window invites a conversation, and AbleKit is not trying to have one. It is
/// trying to be told a task and get out of the way.
struct CommandPaletteView: View {
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void

    @Environment(AppState.self) private var state
    @State private var goal = ""
    @State private var selectedSuggestion: Int?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field

            if let reason = state.blockingReason {
                banner(reason)
            } else if !suggestions.isEmpty {
                Divider().padding(.horizontal, 12)
                suggestionList
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .onAppear { isFieldFocused = true }
        .onExitCommand(perform: onDismiss)
        .frame(width: 620)
    }

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
                .onSubmit(submit)

            if !goal.isEmpty {
                Button(action: submit) {
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
                onDismiss()
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                Button {
                    goal = suggestion.text
                    submit()
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
                    title: $0.name, detail: "Skill", symbol: "sparkles", text: $0.summary
                )
            }

        let recents = state.settings.recentGoals
            .filter { query.isEmpty || $0.lowercased().contains(query) }
            .prefix(query.isEmpty ? 3 : 2)
            .map { Suggestion(title: $0, detail: nil, symbol: "clock", text: $0) }

        return Array(skills) + Array(recents)
    }

    private func submit() {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        goal = ""
        onSubmit(trimmed)
    }

    private struct Suggestion {
        let title: String
        let detail: String?
        let symbol: String
        let text: String
    }
}
