import Foundation

/// Operates interfaces semantically.
///
/// This capability only accepts work it can do *properly*: it declines any element that does not
/// advertise the action being asked of it, which sends the request down to the visual tier rather
/// than issuing an `AXPress` that will quietly fail. Declining well is what makes the tiering
/// meaningful.
public struct AccessibilityCapability: Capability {
    public let kind = CapabilityKind.accessibility

    private let service: AccessibilityService
    private let permissions: any PermissionChecking

    public init(
        service: AccessibilityService = AccessibilityService(),
        permissions: any PermissionChecking = SystemPermissionChecker()
    ) {
        self.service = service
        self.permissions = permissions
    }

    public func canHandle(_ action: DesktopAction) -> Bool {
        guard permissions.status(of: .accessibility).isGranted else { return false }
        guard case .accessibilityAction(let element, let axAction) = action else { return false }
        return element.actions.contains(axAction)
    }

    public func execute(_ action: DesktopAction, context: DesktopContext?) async throws
        -> CapabilityOutcome
    {
        guard case .accessibilityAction(let element, let axAction) = action else {
            throw CapabilityError.noCapability(action.summary)
        }
        guard permissions.status(of: .accessibility).isGranted else {
            throw CapabilityError.permissionRequired(.accessibility)
        }
        guard let processIdentifier = context?.frontmostApplication?.processIdentifier else {
            throw CapabilityError.executionFailed("There is no frontmost application to act on.")
        }

        // Accessibility calls are synchronous IPC into another process and can block for as long
        // as the messaging timeout, so they are moved off whatever actor is driving the agent.
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    try service.perform(axAction, on: element, processIdentifier: processIdentifier)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        return .success("Performed \(axAction) on \(element.description).")
    }
}
