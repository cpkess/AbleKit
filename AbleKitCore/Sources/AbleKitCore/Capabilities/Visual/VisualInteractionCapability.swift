import CoreGraphics
import Foundation

/// Drives interfaces with synthetic input aimed at screen positions.
///
/// The fallback tier, and the one to reach for last. It works on anything — including interfaces
/// that expose nothing to Accessibility at all, which is precisely the case AbleKit exists to
/// cover — but it is blind: a click here is a click at a position, and only `Verifier` will find
/// out whether it landed on the intended thing.
public struct VisualInteractionCapability: Capability {
    public let kind = CapabilityKind.visual

    private let mouse: MouseController
    private let keyboard: KeyboardController
    private let permissions: any PermissionChecking

    public init(
        mouse: MouseController = MouseController(),
        keyboard: KeyboardController = KeyboardController(),
        permissions: any PermissionChecking = SystemPermissionChecker()
    ) {
        self.mouse = mouse
        self.keyboard = keyboard
        self.permissions = permissions
    }

    public func canHandle(_ action: DesktopAction) -> Bool {
        guard permissions.status(of: .accessibility).isGranted else { return false }
        switch action {
        case .click, .doubleClick, .rightClick, .movePointer, .scroll, .drag, .typeText,
            .pressKey, .hotkey:
            return true
        default:
            return false
        }
    }

    public func execute(_ action: DesktopAction, context: DesktopContext?) async throws
        -> CapabilityOutcome
    {
        // Posting synthetic events requires Accessibility permission; without it `CGEvent` creation
        // fails in a way that is easy to mistake for the action having worked.
        guard permissions.status(of: .accessibility).isGranted else {
            throw CapabilityError.permissionRequired(.accessibility)
        }

        switch action {
        case .click(let target):
            try mouse.click(at: target.resolvedPoint)
        case .doubleClick(let target):
            try mouse.click(at: target.resolvedPoint, count: 2)
        case .rightClick(let target):
            try mouse.click(at: target.resolvedPoint, button: .right)
        case .movePointer(let target):
            try mouse.move(to: target.resolvedPoint)
        case .scroll(let target, let deltaX, let deltaY):
            try mouse.scroll(at: target.resolvedPoint, deltaX: deltaX, deltaY: deltaY)
        case .drag(let from, let to):
            try mouse.drag(from: from.resolvedPoint, to: to.resolvedPoint)
        case .typeText(let text):
            try keyboard.type(text)
        case .pressKey(let key):
            try keyboard.press(key)
        case .hotkey(let key, let modifiers):
            try keyboard.press(key, modifiers: modifiers)
        default:
            throw CapabilityError.noCapability(action.summary)
        }

        return .success(action.summary)
    }
}
