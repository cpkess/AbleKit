import Foundation
import FoundationModels

/// The reasoning layer, backed by Apple Intelligence.
///
/// This is the only file in AbleKit that talks to Foundation Models. Everything the agent sees is
/// `PlannedStep` and `VerificationResult`, so the automation engine can be exercised against a
/// scripted provider in tests and a different model could be substituted without touching it.
///
/// Reasoning runs on this Mac unless the user has opted in to Private Cloud Compute. Even then,
/// every step falls back to the on-device model whenever the cloud cannot be used — no access,
/// quota spent, offline — so opting in can make AbleKit better but never makes it stop working.
/// Each `PlannedStep` records where it was actually reasoned, so the interface never has to
/// guess, and nothing is sent off the machine without it being visible.
///
/// A fresh `LanguageModelSession` is created for each call rather than kept across a task. That is
/// deliberate: `PromptBuilder` already assembles the history it wants the model to see, budgeted to
/// fit, so a long-lived transcript would only add unbounded context that eventually overflows.
public struct AppleIntelligenceProvider: IntelligenceProvider {
    public let requestedLocation: ReasoningLocation

    private let model: SystemLanguageModel
    private let localPrompts: PromptBuilder
    /// Prompts for the cloud leave out the clipboard. It is the one piece of context that routinely
    /// holds secrets — password managers put passwords there — and planning rarely needs it.
    private let cloudPrompts: PromptBuilder
    private let decoder: PlannedStepDecoder

    public init(
        location: ReasoningLocation = .onDevice,
        model: SystemLanguageModel = .default,
        budget: PromptBuilder.Budget = .default,
        decoder: PlannedStepDecoder = PlannedStepDecoder()
    ) {
        self.requestedLocation = location
        self.model = model
        self.localPrompts = PromptBuilder(budget: budget)
        self.cloudPrompts = PromptBuilder(budget: budget, includesClipboard: false)
        self.decoder = decoder
    }

    public var name: String {
        requestedLocation == .privateCloudCompute
            ? "Apple Intelligence (Private Cloud Compute when available)"
            : "Apple Intelligence (on this Mac)"
    }

    public var availability: IntelligenceAvailability {
        get async {
            if effectiveLocation() == .privateCloudCompute { return .available }
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

    // MARK: - Private Cloud Compute

    /// Whether Private Cloud Compute can be used right now.
    public static func cloudStatus() -> CloudReasoningStatus {
        guard #available(macOS 27.0, *) else { return .unsupportedSystem }
        if CloudAccessMemory.isDenied { return .accessNotGranted }
        let cloud = PrivateCloudComputeLanguageModel()
        switch cloud.availability {
        case .available:
            let quota = cloud.quotaUsage
            return quota.isLimitReached ? .quotaReached(resetDate: quota.resetDate) : .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .systemNotReady: return .systemNotReady
            @unknown default: return .systemNotReady
            }
        @unknown default:
            return .systemNotReady
        }
    }

    /// Where the next call will actually run.
    public func effectiveLocation() -> ReasoningLocation {
        requestedLocation == .privateCloudCompute && Self.cloudStatus().isAvailable
            ? .privateCloudCompute : .onDevice
    }

    /// Sends one trivial, made-up request to Private Cloud Compute, to find out whether this build
    /// is allowed to use it. Nothing from the user's screen is included.
    public static func testCloudAccess() async -> CloudReasoningStatus {
        CloudAccessMemory.reset()
        let status = cloudStatus()
        guard status.isAvailable, #available(macOS 27.0, *) else { return status }
        do {
            let session = LanguageModelSession(
                model: PrivateCloudComputeLanguageModel(),
                instructions: "Answer with one word."
            )
            _ = try await session.respond(to: "Reply with the word ready.")
            return .available
        } catch {
            if CloudAccessMemory.isAccessDenied(error) {
                CloudAccessMemory.recordDenied()
                return .accessNotGranted
            }
            return .systemNotReady
        }
    }

    /// Warms the on-device model so the first step of a task does not pay the load cost.
    ///
    /// Called when the command palette opens: by the time the user finishes typing, the model is
    /// usually resident.
    public func prewarm() {
        guard effectiveLocation() == .onDevice, case .available = model.availability else { return }
        let session = LanguageModelSession(model: model, instructions: PromptBuilder.planningInstructions)
        session.prewarm()
    }

    // MARK: - Planning

    public func planNextStep(goal: String, context: AgentContext) async throws -> PlannedStep {
        try await withFallback { (location) async throws(IntelligenceError) -> PlannedStep in
            let prompts = location == .privateCloudCompute ? cloudPrompts : localPrompts
            let prompt = prompts.planningPrompt(goal: goal, context: context)
            let draft = try await run(on: location, instructions: PromptBuilder.planningInstructions) {
                session in
                try await session.respond(
                    to: prompt, generating: PlannedStepDraft.self, options: Self.planningOptions
                ).content
            }
            let step = try decoder.decode(draft, context: context.desktop, goal: goal)
            return PlannedStep(
                action: step.action, rationale: step.rationale,
                confidence: step.confidence, reasonedBy: location
            )
        }
    }

    // MARK: - Verification

    public func verify(
        action: DesktopAction,
        before: DesktopContext,
        after: DesktopContext
    ) async throws -> VerificationResult {
        try await withFallback { (location) async throws(IntelligenceError) -> VerificationResult in
            let prompts = location == .privateCloudCompute ? cloudPrompts : localPrompts
            let prompt = prompts.verificationPrompt(action: action, before: before, after: after)
            let draft = try await run(on: location, instructions: PromptBuilder.verificationInstructions) {
                session in
                try await session.respond(
                    to: prompt, generating: VerificationDraft.self, options: Self.verificationOptions
                ).content
            }
            return VerificationResult(
                outcome: draft.verdict.outcome,
                reason: draft.reason.trimmed.isEmpty ? "No detail given." : draft.reason.trimmed,
                shouldRetry: draft.shouldRetry
            )
        }
    }

    // MARK: - Running a request

    /// Runs a request where it should run, and on this Mac if the cloud cannot take it.
    ///
    /// Only failures of the *service* fall back. A step the model got wrong is returned as the error
    /// it is, so the agent loop can re-plan — repeating it on-device would just be a second opinion
    /// the loop never asked for.
    private func withFallback<T: Sendable>(
        _ body: (ReasoningLocation) async throws(IntelligenceError) -> T
    ) async throws(IntelligenceError) -> T {
        let location = effectiveLocation()
        guard location == .privateCloudCompute else { return try await body(.onDevice) }
        do {
            return try await body(.privateCloudCompute)
        } catch {
            switch error {
            case .undecodableStep, .cancelled:
                throw error
            default:
                return try await body(.onDevice)
            }
        }
    }

    /// Opens a session on the chosen model and runs one request, translating any failure into
    /// AbleKit's own errors.
    ///
    /// Availability is re-checked on every call rather than cached: the user can switch Apple
    /// Intelligence off in System Settings while a task is mid-flight.
    private func run<T: Sendable>(
        on location: ReasoningLocation,
        instructions: String,
        _ request: (LanguageModelSession) async throws -> T
    ) async throws(IntelligenceError) -> T {
        let session: LanguageModelSession
        switch location {
        case .onDevice:
            guard case .available = model.availability else {
                let availability = await availability
                guard case .unavailable(let reason, _) = availability else {
                    throw .unavailable("Apple Intelligence is not available.")
                }
                throw .unavailable(reason)
            }
            session = LanguageModelSession(model: model, instructions: instructions)
        case .privateCloudCompute:
            guard #available(macOS 27.0, *) else {
                throw .unavailable(CloudReasoningStatus.unsupportedSystem.explanation)
            }
            session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: instructions)
        }

        do {
            return try await request(session)
        } catch let error as IntelligenceError {
            throw error
        } catch is CancellationError {
            throw .cancelled
        } catch {
            if location == .privateCloudCompute, CloudAccessMemory.isAccessDenied(error) {
                // Remembered, so later steps go straight to the Mac instead of asking again.
                CloudAccessMemory.recordDenied()
                throw .unavailable(CloudReasoningStatus.accessNotGranted.explanation)
            }
            throw Self.translate(error)
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
