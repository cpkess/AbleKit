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

        if !state.skills.isEmpty {
            Menu("Skills") {
                ForEach(state.skills) { skill in
                    Button(skill.name) { appDelegate?.showPalette() }
                }
            }
        }

        if let reason = state.blockingReason {
            Divider()
            Text(reason)
            Button("Open Setup\u{2026}") { appDelegate?.showOnboarding() }
        }

        Divider()
        Button("Settings\u{2026}") { appDelegate?.showSettings() }
            .keyboardShortcut(",", modifiers: .command)
        Button("Quit AbleKit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private var appDelegate: AppDelegate? {
        NSApplication.shared.delegate as? AppDelegate
    }
}
