import Foundation

/// Handles the steps that do not touch the desktop.
///
/// Waiting and asking the user are real steps with real outcomes, so they go through the same
/// pipeline as everything else rather than being special-cased inside the loop. That keeps the
/// step history complete: "waited 2s" and "you declined" are part of what happened.
public struct ControlCapability: Capability {
    public let kind = CapabilityKind.control

    private let interaction: any UserInteracting

    public init(interaction: any UserInteracting = DecliningUserInteraction()) {
        self.interaction = interaction
    }

    public func canHandle(_ action: DesktopAction) -> Bool {
        switch action {
        case .wait, .requestConfirmation, .complete, .fail:
            true
        default:
            false
        }
    }

    public func execute(_ action: DesktopAction, context: DesktopContext?) async throws
        -> CapabilityOutcome
    {
        switch action {
        case .wait(let seconds):
            try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            return .success("Waited \(String(format: "%.1f", seconds))s.")

        case .requestConfirmation(let prompt):
            let approved = await interaction.confirm(
                UserPrompt(message: prompt, style: .confirmation(action: action, reason: prompt))
            )
            return CapabilityOutcome(
                succeeded: approved,
                detail: approved ? "You approved it." : "You declined."
            )

        case .complete, .fail:
            // Reached only if something bypassed the loop, which ends tasks on these itself.
            return .success

        default:
            throw CapabilityError.noCapability(action.summary)
        }
    }
}
