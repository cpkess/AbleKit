import AppKit
import SwiftUI

/// Draws a highlight around whatever AbleKit is about to touch.
///
/// The overlay answers a question the user would otherwise have to guess at: *what is it about to
/// click?* Being able to see the target — and to stop before it is pressed — is most of what makes
/// watching an agent work tolerable rather than unnerving.
///
/// The window ignores mouse events entirely. An overlay that could intercept input would be a
/// serious bug in a tool that synthesises input for a living: AbleKit's own clicks would land on
/// its own window.
@MainActor
final class OverlayController {

    private var window: NSWindow?

    func show(_ frame: CGRect) {
        let window = window ?? makeWindow()
        self.window = window

        // The frame arrives in canonical space (top-left origin); AppKit windows are positioned in
        // its own bottom-left space, so this is the one place in the UI that flips.
        window.setFrame(Self.appKitFrame(for: frame.insetBy(dx: -4, dy: -4)), display: true)
        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Above ordinary windows but below the HUD, so the two never fight over the same pixels.
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: OverlayHighlight())
        return window
    }

    /// Converts a canonical rect into AppKit screen coordinates.
    private static func appKitFrame(for rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.screens.first
        else { return rect }
        return CGRect(
            x: rect.origin.x,
            y: primary.frame.height - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}

/// The highlight itself: a rounded outline, deliberately quiet.
private struct OverlayHighlight: View {
    @State private var isPulsing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2.5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .opacity(isPulsing ? 0.65 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
