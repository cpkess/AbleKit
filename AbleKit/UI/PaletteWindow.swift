import AbleKitCore
import AppKit
import SwiftUI

/// A borderless panel that can take keyboard focus.
///
/// `NSPanel` refuses to become key by default when it has no title bar, which would leave the
/// palette unable to receive the text the user is trying to type into it.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Hosts the command palette.
@MainActor
final class PaletteWindowController {

    private let panel: FloatingPanel
    private weak var delegate: AppDelegate?

    var isVisible: Bool { panel.isVisible }

    init(state: AppState, delegate: AppDelegate) {
        self.delegate = delegate

        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 92),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        let root = CommandPaletteView(
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
            onDismiss: { [weak delegate] in delegate?.hidePalette() }
        )
        .environment(state)

        // A hosting controller rather than a hosting view, so the panel resizes to fit its content.
        // The palette grows when a Skill asks for values, and a fixed-height panel would clip the
        // form it is showing.
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
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
}
