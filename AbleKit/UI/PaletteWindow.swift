import AbleKitCore
import AppKit
import SwiftUI

/// Hosts the command palette.
@MainActor
final class PaletteWindowController {

    private let host = HostedPanel(width: 620, initialHeight: 64, anchor: .top)
    private var panel: FloatingPanel { host.panel }
    private weak var delegate: AppDelegate?
    let model = PaletteModel()

    var isVisible: Bool { panel.isVisible }

    init(state: AppState, delegate: AppDelegate) {
        self.delegate = delegate

        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .utilityWindow

        host.setContent(
            CommandPaletteView(
                onSubmit: { [weak delegate] request in
                    delegate?.hidePalette()
                    switch request {
                    case .goal(let goal):
                        state.start(goal: goal)
                    case .skill(let skill, let parameters):
                        state.run(skill, parameters: parameters)
                    }
                    delegate?.showHUD()
                },
                onDismiss: { [weak delegate] in delegate?.hidePalette() },
                model: model
            )
            .environment(state)
        )
    }

    func show() {
        position()
        // A menu-bar app is not frontmost, so it must activate before its panel can take the
        // keystrokes the user is about to type.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Places the palette where Spotlight puts itself: horizontally centred, in the upper third of
    /// whichever screen the pointer is on.
    private func position() {
        let screen =
            NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.maxY - visible.height * 0.28 - size.height
            )
        )
    }

    #if DEBUG
        /// Types into the palette one character at a time, exactly as the text field would see it.
        func simulateTyping(_ text: String) async {
            show()
            model.goal = ""
            for character in text {
                model.goal.append(character)
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    #endif
}
