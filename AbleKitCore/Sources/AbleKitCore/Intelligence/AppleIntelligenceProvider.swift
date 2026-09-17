import Foundation
import FoundationModels

/// The local reasoning layer, backed by Apple's on-device foundation model.
///
/// This is the only file in AbleKit that talks to Foundation Models. Everything the agent sees is
/// `PlannedStep` and `VerificationResult`, so the automation engine can be exercised against a
/// scripted provider in tests and a different model could be substituted without touching it.
///
/// A fresh `LanguageModelSession` is created for each call rather than kept across a task. That is
/// deliberate: `PromptBuilder` already assembles the history it wants the model to see, budgeted to
/// fit, so a long-lived transcript would only add unbounded context that eventually overflows.
public struct AppleIntelligenceProvider: IntelligenceProvider {
    public let name = "Apple Intelligence"

    private let model: SystemLanguageModel
    private let promptBuilder: PromptBuilder
    private let decoder: PlannedStepDecoder

    public init(
        model: SystemLanguageModel = .default,
        promptBuilder: PromptBuilder = PromptBuilder(),
        decoder: PlannedStepDecoder = PlannedStepDecoder()
    ) {
        self.model = model
        self.promptBuilder = promptBuilder
        self.decoder = decoder
    }

    public var availability: IntelligenceAvailability {
        get async {
            switch model.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .unavailable(
                    reason: Self.description(of: reason),
                    recoverySuggestion: Self.recovery(for: reason)
                )
            @unknown default:
                return .unavailable(
                    reason: "Apple Intelligence is not available on this Mac.",
                    recoverySuggestion: nil
                )
            }
        }
    }

    /// Warms the model so the first step of a task does not pay the load cost.
    ///
    /// Called when the command palette opens: by the time the user finishes typing, the model is
    /// usually resident.
    public func prewarm() {
        guard case .available = model.availability else { return }
        let session = LanguageModelSession(model: model, instructions: PromptBuilder.planningInstructions)
        session.prewarm()
    }

    // MARK: - Planning

    public func planNextStep(goal: String, context: AgentContext) async throws -> PlannedStep {
        try await withAvailableModel {
            let session = LanguageModelSession(
                model: model,
                instructions: PromptBuilder.planningInstructions
            )
            let prompt = promptBuilder.planningPrompt(goal: goal, context: context)
            let response = try await session.respond(
                to: prompt,
                generating: PlannedStepDraft.self,
                options: Self.planningOptions
            )
            return try decoder.decode(response.content, context: context.desktop, goal: goal)
        }
    }

    // MARK: - Verification

    public func verify(
        action: DesktopAction,
        before: DesktopContext,
        after: DesktopContext
    ) async throws -> VerificationResult {
        try await withAvailableModel {
            let session = LanguageModelSession(
                model: model,
                instructions: PromptBuilder.verificationInstructions
            )
            let prompt = promptBuilder.verificationPrompt(action: action, before: before, after: after)
            let response = try await session.respond(
                to: prompt,
                generating: VerificationDraft.self,
                options: Self.verificationOptions
            )
            let draft = response.content
            return VerificationResult(
                outcome: draft.verdict.outcome,
                reason: draft.reason.trimmed.isEmpty ? "No detail given." : draft.reason.trimmed,
                shouldRetry: draft.shouldRetry
            )
        }
    }

    // MARK: - Generation settings

    /// Planning is a decision, not a composition, so it is decoded greedily: the same screen and
    /// goal produce the same step every time. That matters beyond tidiness — with even a little
    /// sampling, a prompt change could look like a fix on one run and a regression on the next,
    /// and failures could not be reproduced to be fixed.
    private static let planningOptions = GenerationOptions(samplingMode: .greedy)

    /// Verification is a judgement and is decoded the same way.
    private static let verificationOptions = GenerationOptions(samplingMode: .greedy)

    // MARK: - Error translation

    /// Runs a model call, turning Foundation Models' errors into AbleKit's own.
    ///
    /// Availability is re-checked on every call rather than cached: the user can switch Apple
    /// Intelligence off in System Settings while a task is mid-flight.
    private func withAvailableModel<T: Sendable>(
        _ body: () async throws -> T
    ) async throws(IntelligenceError) -> T {
        guard case .available = model.availability else {
            let availability = await availability
            guard case .unavailable(let reason, _) = availability else {
                throw .unavailable("Apple Intelligence is not available.")
            }
            throw .unavailable(reason)
        }
        do {
            return try await body()
        } catch let error as IntelligenceError {
            throw error
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw Self.translate(error)
        }
    }

    /// Maps a Foundation Models failure onto AbleKit's own error type.
    ///
    /// `LanguageModelSession.GenerationError` is used rather than the newer `LanguageModelError`
    /// because it exists in the macOS 26 SDK as well as 27, and AbleKit's deployment target is 26 —
    /// referencing the newer type would make the project impossible to build with anything but the
    /// very latest Xcode, including on CI runners. The older type is deprecated as of macOS 27,
    /// which produces no warning here because AbleKit deploys to 26.
    private static func translate(_ error: any Error) -> IntelligenceError {
        guard let generationError = error as? LanguageModelSession.GenerationError else {
            return .underlying(error.localizedDescription)
        }
        switch generationError {
        case .exceededContextWindowSize:
            return .contextTooLarge
        case .guardrailViolation:
            return .underlying("Apple Intelligence declined to answer about what is on screen.")
        case .unsupportedLanguageOrLocale:
            return .underlying("Apple Intelligence does not support this language yet.")
        case .assetsUnavailable:
            return .underlying("Apple Intelligence is still preparing its model.")
        case .rateLimited:
            return .underlying("Apple Intelligence is busy. Try again in a moment.")
        default:
            return .underlying(generationError.localizedDescription)
        }
    }

    private static func description(
        of reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            "This Mac does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is switched off."
        case .modelNotReady:
            "Apple Intelligence is still downloading its model."
        @unknown default:
            "Apple Intelligence is not available."
        }
    }

    private static func recovery(
        for reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String? {
        switch reason {
        case .deviceNotEligible:
            "AbleKit needs a Mac with Apple Silicon and Apple Intelligence support."
        case .appleIntelligenceNotEnabled:
            "Turn it on in System Settings \u{203A} Apple Intelligence & Siri."
        case .modelNotReady:
            "Leave the Mac connected to power and Wi-Fi, then try again shortly."
        @unknown default:
            nil
        }
    }
}

extension VerificationVerdict {
    var outcome: VerificationOutcome {
        switch self {
        case .succeeded: .succeeded
        case .failed: .failed
        case .inconclusive: .inconclusive
        }
    }
}
