import AbleKitCore
import Foundation

/// Bridges the agent's need for an answer to the user interface that asks for it.
///
/// The agent suspends on `confirm` or `requestInput` while a prompt is shown, and resumes when the
/// user decides. Keeping this on the main actor and storing exactly one pending prompt at a time
/// is what guarantees the user is never asked two questions at once, and never asked about an
/// action that has already been abandoned.
@MainActor
@Observable
final class InteractionCoordinator: UserInteracting {

    /// The question currently in front of the user, if any.
    private(set) var pending: UserPrompt?

    private var confirmationContinuation: CheckedContinuation<Bool, Never>?
    private var inputContinuation: CheckedContinuation<String?, Never>?

    nonisolated init() {}

    func confirm(_ prompt: UserPrompt) async -> Bool {
        await withCheckedContinuation { continuation in
            // A prompt arriving while another is open means the agent is in an unexpected state;
            // the older one is declined rather than left waiting forever.
            resolveOutstanding()
            pending = prompt
            confirmationContinuation = continuation
        }
    }

    func requestInput(_ prompt: UserPrompt) async -> String? {
        await withCheckedContinuation { continuation in
            resolveOutstanding()
            pending = prompt
            inputContinuation = continuation
        }
    }

    // MARK: - Answers from the UI

    func approve() {
        let continuation = confirmationContinuation
        clear()
        continuation?.resume(returning: true)
    }

    func decline() {
        let continuation = confirmationContinuation
        clear()
        continuation?.resume(returning: false)
    }

    func answer(_ text: String) {
        let continuation = inputContinuation
        clear()
        continuation?.resume(returning: text)
    }

    func dismiss() {
        resolveOutstanding()
    }

    /// Ends any outstanding question as a refusal, so the agent is never left suspended.
    private func resolveOutstanding() {
        let confirmation = confirmationContinuation
        let input = inputContinuation
        clear()
        confirmation?.resume(returning: false)
        input?.resume(returning: nil)
    }

    private func clear() {
        pending = nil
        confirmationContinuation = nil
        inputContinuation = nil
    }
}
