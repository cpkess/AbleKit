import Foundation

/// Asks Microsoft Copilot a question through its own interface, and brings the answer back.
///
/// This is the capability that makes AbleKit more than a macOS automation tool. Copilot has the
/// enterprise context; AbleKit has the desktop and the hands. Bridging them lets a task read
/// something on screen, ask an authorised system what it means, and act on the answer in a second
/// application — none of which either side could do alone.
///
/// Two constraints shape the implementation:
///
/// - **It drives the interface the user already signed into.** There is no enterprise Copilot API
///   assumed here, and nothing about this bypasses authentication or policy: AbleKit types into
///   the same window the user could type into, with the same access they already have (brief §20).
/// - **The handoff is explicit.** Only text is sent, never a screenshot, and because the policy
///   classifies a bridge call as consequential, the exact prompt is shown to the user before it
///   leaves the machine (brief §15).
public struct CopilotBridge: AIBridge {
    public let identifier = AIBridgeIdentifier.copilot

    private let surface: any CopilotSurface
    private let clock: any BridgeClock

    /// How often the interface is re-read while waiting for an answer.
    ///
    /// Slow enough not to spend the machine's time on Accessibility round trips, fast enough that
    /// a short answer does not sit finished for long before being noticed.
    public static let pollInterval = Duration.milliseconds(800)

    public init(surface: any CopilotSurface, clock: any BridgeClock = SystemBridgeClock()) {
        self.surface = surface
        self.clock = clock
    }

    public func isAvailable() async -> Bool {
        surface.isInstalled
    }

    public func ask(prompt: String, context: BridgeContext) async throws -> BridgeResult {
        guard surface.isInstalled else {
            throw AIBridgeError.unavailable("Microsoft Copilot is not installed.")
        }

        try await surface.activate()

        var interface = try await surface.readInterface()

        // Switch mode before typing: the affordance usually applies to the message about to be
        // sent, not retroactively to one already in flight.
        var effectiveMode = CopilotMode.standard
        var fallbackReason: String?
        if context.mode == .researcher {
            if let control = interface.researcherControl {
                do {
                    try await surface.selectMode(.researcher, using: control)
                    effectiveMode = .researcher
                    interface = try await surface.readInterface()
                } catch {
                    fallbackReason =
                        "Copilot's research mode could not be switched on, so this is a standard answer."
                }
            } else {
                // Reported rather than silently downgraded: an answer the user believes was
                // researched, but was not, is worse than no answer.
                fallbackReason =
                    "This build of Copilot exposes no research mode, so this is a standard answer."
            }
        }

        guard let field = interface.promptField else {
            throw AIBridgeError.promptFieldNotFound
        }

        let fullPrompt = Self.composePrompt(prompt, sharedContext: context.sharedContext)
        try await surface.enterPrompt(fullPrompt, into: field)

        // What was on screen before submitting, so a reply can be told from the conversation that
        // was already there.
        let baseline = interface.responseText.trimmed

        try await surface.submit(interface)

        let answer = try await waitForAnswer(after: baseline, timeout: context.timeout)

        return BridgeResult(text: answer, mode: effectiveMode, modeFallbackReason: fallbackReason)
    }

    // MARK: - Waiting

    /// Polls until the answer settles, the time runs out, or the user cancels.
    private func waitForAnswer(after baseline: String, timeout: Duration) async throws -> String {
        var detector = ResponseStabilityDetector()
        let deadline = clock.now.advanced(by: timeout)
        var sawSubmissionTakeEffect = false

        while clock.now < deadline {
            try Task.checkCancellation()

            let interface: CopilotInterface
            do {
                interface = try await surface.readInterface()
            } catch is CancellationError {
                throw AIBridgeError.cancelled
            } catch {
                throw AIBridgeError.responseNotFound
            }

            // Copilot either starts working or the transcript grows; either means the question
            // was actually received, which is worth distinguishing from a prompt that never sent.
            if interface.isBusy || interface.responseText.trimmed != baseline {
                sawSubmissionTakeEffect = true
            }

            if sawSubmissionTakeEffect {
                let reply = Self.newContent(in: interface.responseText, after: baseline)
                if case .settled(let settled) = detector.observe(
                    text: reply, isBusy: interface.isBusy
                ), !settled.isEmpty {
                    return settled
                }
            }

            try await clock.sleep(for: Self.pollInterval)
        }

        // Out of time. If something partial was seen, say so rather than returning it as if it
        // were the whole answer.
        throw AIBridgeError.timedOut(timeout)
    }

    // MARK: - Text handling

    /// The part of the transcript that was not there before the question was asked.
    ///
    /// Copilot's response area holds the whole conversation, so the reply has to be separated from
    /// its own history. A clean prefix match is the reliable case; when the interface has reflowed
    /// and the prefix no longer matches, the whole text is returned rather than guessing at a
    /// boundary and truncating the answer.
    static func newContent(in current: String, after baseline: String) -> String {
        let trimmedCurrent = current.trimmed
        guard !baseline.isEmpty else { return trimmedCurrent }
        guard trimmedCurrent.hasPrefix(baseline) else { return trimmedCurrent }
        return String(trimmedCurrent.dropFirst(baseline.count)).trimmed
    }

    /// Builds what is actually sent.
    ///
    /// Desktop context is included as plain text and clearly labelled, so that the user reviewing
    /// the confirmation can see exactly what is leaving their machine. A screenshot is never sent:
    /// the relevant information is extracted locally first (brief §15).
    static func composePrompt(_ prompt: String, sharedContext: String?) -> String {
        guard let sharedContext = sharedContext?.trimmed, !sharedContext.isEmpty else {
            return prompt
        }
        return """
            \(prompt)

            Context from my screen:
            \(sharedContext)
            """
    }
}

/// The passage of time, so that waiting can be tested without actually waiting.
public protocol BridgeClock: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(for duration: Duration) async throws
}

public struct SystemBridgeClock: BridgeClock {
    public init() {}
    public var now: ContinuousClock.Instant { ContinuousClock.now }
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Exposes an AI bridge to the agent as an ordinary capability.
///
/// Once wrapped, asking Copilot is just another step: routed, classified, confirmed and verified
/// like a click. That uniformity is what lets a Copilot answer flow into the next action without
/// the agent loop knowing anything special about it.
public struct AIBridgeCapability: Capability {
    public let kind = CapabilityKind.bridge

    private let bridges: [AIBridgeIdentifier: any AIBridge]

    public init(bridges: [any AIBridge]) {
        self.bridges = Dictionary(
            bridges.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public func canHandle(_ action: DesktopAction) -> Bool {
        guard case .askAIBridge(let identifier, _) = action else { return false }
        return bridges[identifier] != nil
    }

    public func execute(_ action: DesktopAction, context: DesktopContext?) async throws
        -> CapabilityOutcome
    {
        guard case .askAIBridge(let identifier, let prompt) = action,
            let bridge = bridges[identifier]
        else {
            throw CapabilityError.noCapability(action.summary)
        }

        do {
            let result = try await bridge.ask(
                prompt: prompt,
                context: BridgeContext(sharedContext: nil)
            )
            let detail = [
                "\(identifier.displayName) answered.",
                result.modeFallbackReason,
            ].compactMap { $0 }.joined(separator: " ")

            return CapabilityOutcome(succeeded: true, detail: detail, producedText: result.text)
        } catch let error as AIBridgeError {
            throw CapabilityError.executionFailed(error.description)
        }
    }
}
