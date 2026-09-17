import AbleKitCore
import SwiftUI

/// The menu behind the menu-bar icon.
///
/// Short on purpose. The menu is a way in and a way out — summon the palette, stop what is running,
/// reach Settings — not a place to browse.
struct MenuBarMenu: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let session = state.session, !session.phase.isTerminal {
            Text(session.currentActivity ?? session.phase.displayName)
            Divider()
            if session.phase == .paused {
                Button("Resume") { state.resume() }
            } else {
                Button("Pause") { state.pause() }
            }
            Button("Stop") { state.cancel() }
                .keyboardShortcut(".", modifiers: .command)
            Divider()
        } else {
            Button("Ask AbleKit\u{2026}") { appDelegate?.showPalette() }
                .keyboardShortcut(.space, modifiers: [.control, .option])
        }

        if !state.skills.isEmpty, !state.isRunning {
            Menu("Skills") {
                ForEach(state.skills) { skill in
                    Button(skill.name) {
                        if skill.parameters.isEmpty {
                            // Nothing to ask for, so run it straight away.
                            state.run(skill, parameters: [:])
                            appDelegate?.showHUD()
                        } else {
                            // It needs values first; the palette is where those are collected.
                            appDelegate?.showPalette(preselecting: skill)
                        }
                    }
                }
            }
        }

        if let reason = state.blockingReason {
            Divider()
            Text(reason)
        }

        Divider()
        // Always available, not only while something is missing: permissions can be revoked, and
        // this is the one place that shows their live state.
        Button("Setup & Permissions\u{2026}") { appDelegate?.showOnboarding() }
        Button("Settings\u{2026}") { appDelegate?.showSettings() }
            .keyboardShortcut(",", modifiers: .command)
        Button("Quit AbleKit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private var appDelegate: AppDelegate? {
        AppDelegate.shared
    }
}
