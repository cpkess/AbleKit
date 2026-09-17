import AbleKitCore
import SwiftUI

/// Settings, kept deliberately short (brief §27).
struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AutomationSettings().tabItem { Label("Automation", systemImage: "wand.and.rays") }
            IntelligenceSettings().tabItem { Label("Intelligence", systemImage: "brain") }
            SkillsSettings().tabItem { Label("Skills", systemImage: "sparkles") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "lock.shield") }
            UpdateSettings().tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            if state.settings.showsDebugInterface {
                DeveloperSettings().tabItem { Label("Developer", systemImage: "hammer") }
            }
        }
        .environment(state)
        .frame(width: 520, height: 420)
    }
}

private struct GeneralSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var settings = state.settings
        Form {
            Toggle("Launch AbleKit at login", isOn: $settings.launchAtLogin)
            Toggle("Show the menu bar icon", isOn: $settings.showsMenuBarIcon)

            LabeledContent("Shortcut") {
                VStack(alignment: .trailing, spacing: 4) {
                    ShortcutRecorder(shortcut: $settings.shortcut) {
                        AppDelegate.shared?.registerShortcut()
                    }
                    if state.shortcutRegistrationFailed {
                        // Said plainly, because a shortcut that another app has already claimed
                        // simply does nothing, with no other clue as to why.
                        Text("Another app is already using this.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Text(
                    "The menu bar icon stays visible while a task is running, so you can always stop it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AutomationSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var settings = state.settings
        Form {
            Section {
                Stepper(
                    "Maximum steps per task: \(settings.maximumSteps)",
                    value: $settings.maximumSteps,
                    in: 5...100,
                    step: 5
                )
                LabeledContent("Pause between actions") {
                    HStack {
                        Slider(value: $settings.actionDelay, in: 0...2, step: 0.1)
                        Text(String(format: "%.1fs", settings.actionDelay))
                            .font(.body.monospaced())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            } footer: {
                Text("A longer pause gives slower apps time to catch up before AbleKit looks again.")
            }

            Section {
                Toggle(
                    "Ask before anything consequential",
                    isOn: $settings.confirmsConsequentialActions
                )
            } footer: {
                Text(
                    """
                    Sending, deleting, purchasing and similar steps stop for your approval. \
                    Turning this off does not allow AbleKit to enter passwords or payment \
                    details \u{2014} it never does those.
                    """
                )
            }

            Section {
                Toggle("Show what AbleKit is working from", isOn: $settings.showsDebugInterface)
            } footer: {
                Text("Adds a developer panel to the task window: context, capability and timings.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct SkillsSettings: View {
    @Environment(AppState.self) private var state
    @State private var selection: Skill.ID?

    var body: some View {
        VStack(spacing: 0) {
            if state.skills.isEmpty {
                ContentUnavailableView(
                    "No Skills yet",
                    systemImage: "sparkles",
                    description: Text("Skills are saved procedures you can run again.")
                )
            } else {
                List(state.skills, selection: $selection) { skill in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(skill.name).font(.headline)
                        Text(skill.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text("\(skill.steps.count) steps")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                    .tag(skill.id)
                }
            }

            Divider()
            HStack {
                Text("Stored as readable files in Application Support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Delete", role: .destructive) {
                    if let selection { state.deleteSkill(selection) }
                    selection = nil
                }
                .disabled(selection == nil)
            }
            .padding(10)
        }
    }
}

private struct PrivacySettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var settings = state.settings
        Form {
            Section {
                Text(
                    """
                    Screenshots are analysed on this Mac and are never written to disk or sent \
                    anywhere. There is no AbleKit account and no AbleKit server. Task history \
                    lives in memory and disappears when the task ends.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("What AbleKit keeps")
            }

            Section {
                Toggle("Diagnostic logging", isOn: $settings.diagnosticLoggingEnabled)
            } footer: {
                Text(
                    """
                    Writes what AbleKit did to the system log \u{2014} steps and outcomes only, \
                    never screen contents or the text you type.
                    """
                )
            }

            Section {
                Button("Clear recent tasks") { state.settings.clearTaskHistory() }
            } footer: {
                Text("Removes the list of goals shown as suggestions in the palette.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpdateSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var settings = state.settings
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $settings.automaticallyChecksForUpdates)
                    .onChange(of: settings.automaticallyChecksForUpdates) { _, value in
                        state.updates.automaticallyChecksForUpdates = value
                    }

                LabeledContent("Version") { Text(state.updates.currentVersion) }

                HStack {
                    Button("Check for Updates\u{2026}") { state.updates.checkForUpdates() }
                        .disabled(!state.updates.canCheckForUpdates || !state.updates.isConfigured)
                    Spacer()
                    Text(state.updates.lastCheckDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if state.updates.isConfigured {
                    Text("Updates are cryptographically verified before they are installed.")
                } else {
                    // Said outright rather than shown as a button that can only fail.
                    Text(
                        """
                        This build has no update signing key, so it cannot receive updates. \
                        Official builds from GitHub Releases do.
                        """
                    )
                    .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}
