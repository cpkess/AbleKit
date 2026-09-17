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

/// A floating panel whose height follows its SwiftUI content — without crashing.
///
/// The obvious way to do this is to let SwiftUI size the window: an `NSHostingController` with
/// `.preferredContentSize`, or an `NSHostingView` with its default sizing options. Both install
/// constraints that resize the window *during* AppKit's layout pass. The resize changes the hosting
/// view's safe area, SwiftUI asks for another constraint update from inside the one already running,
/// and AppKit throws. In 0.1.0 that happened every time typing in the palette changed the number of
/// suggestions — the app simply vanished.
///
/// So SwiftUI is given no say in the window's size at all (`sizingOptions = []`). The content reports
/// its height, and the window is resized on the *next* turn of the run loop, after layout has
/// finished. The panel is also borderless: a hidden title bar still contributes safe-area insets,
/// and every change to those is another trip through the same path.
@MainActor
final class HostedPanel {
    enum Anchor {
        /// The top edge stays put and the panel grows downward, like Spotlight.
        case top
        /// The bottom edge stays put and the panel grows upward, like a notification.
        case bottom
    }

    let panel: FloatingPanel
    private let anchor: Anchor
    private var lastHeight: CGFloat = 0

    init(width: CGFloat, initialHeight: CGFloat, anchor: Anchor) {
        self.anchor = anchor
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: initialHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
    }

    /// Installs the content. Call once.
    func setContent(_ content: some View) {
        let root = content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { [weak self] height in
                self?.contentHeightChanged(height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor == .top ? .top : .bottom)
            .ignoresSafeArea()

        let hosting = NSHostingView(rootView: root)
        // The crucial line: SwiftUI must not drive the window's frame.
        hosting.sizingOptions = []
        panel.contentView = hosting
    }

    private func contentHeightChanged(_ height: CGFloat) {
        let height = ceil(height)
        guard height > 0, abs(height - lastHeight) > 0.5 else { return }
        lastHeight = height

        // Deferred on purpose. This callback runs inside SwiftUI's update, which runs inside AppKit's
        // layout pass; resizing the window from here is precisely the re-entrancy that crashed.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var frame = panel.frame
            if anchor == .top {
                let top = frame.maxY
                frame.size.height = height
                frame.origin.y = top - height
            } else {
                frame.size.height = height
            }
            panel.setFrame(frame, display: true, animate: false)
        }
    }
}
