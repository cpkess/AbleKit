import Foundation

/// One run of one task.
///
/// The loop is the brief's: collect context, plan a single step, route it, check it, execute it,
/// observe, verify, repeat. Three things about it are worth stating outright, because they are
/// what separate an agent that is pleasant to use from one that is alarming:
///
/// - **It plans one step at a time.** A longer plan would be mostly fiction: the desktop changes
///   after every action, including in ways nobody predicted.
/// - **It can always be stopped.** Pause and cancel are checked between every phase and honoured
///   inside waits, so "Stop" means now, not at the end of the current step.
/// - **It is bounded in every direction.** Steps, wall-clock time, consecutive failures, repeated
///   actions and repeated screen states all terminate the task. An agent that cannot stop itself
///   is not something to leave running on someone's Mac.
@MainActor
@Observable
public final class AgentSession {

    // MARK: - Observable state

    public private(set) var phase: AgentPhase = .idle
    public let goal: String
    public private(set) var history: [StepRecord] = []
    /// What the agent is doing right now, for the HUD.
    public private(set) var currentActivity: String?
    /// The action about to be performed, for the overlay to highlight.
    public private(set) var pendingAction: DesktopAction?
    public private(set) var termination: TaskTermination?
    /// Information gathered along the way, such as a Copilot answer.
    public private(set) var gatheredInformation: [GatheredInformation] = []
    /// The most recent context, for the debug interface.
    public private(set) var latestContext: DesktopContext?

    public let id = UUID()
    public let startedAt = Date()

    // MARK: - Collaborators

    private let collector: any ContextCollecting
    private let intelligence: any IntelligenceProvider
    private let executor: Executor
    private let verifier: Verifier
    private let interaction: any UserInteracting
    private let limits: TaskLimits

    // MARK: - Control

    private var isPaused = false
    private var isCancelled = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var loopDetector: LoopDetector
    private var consecutiveFailures = 0
    /// How many times in a row the planner has proposed something already done.
    private var redundantProposals = 0

    public init(
        goal: String,
        collector: any ContextCollecting,
        intelligence: any IntelligenceProvider,
        executor: Executor,
        verifier: Verifier,
        interaction: any UserInteracting = DecliningUserInteraction(),
        limits: TaskLimits = .default
    ) {
        self.goal = goal
        self.collector = collector
        self.intelligence = intelligence
        self.executor = executor
        self.verifier = verifier
        self.interaction = interaction
        self.limits = limits
        self.loopDetector = LoopDetector(limits: limits)
    }

    // MARK: - Phase

    /// Moves the state machine on, unless the user has asked to pause.
    ///
    /// `pause()` can land at any point inside a step, while the loop only *acts* on it at the next
    /// checkpoint. Without this guard the work still in flight would immediately overwrite
    /// `.paused`, and the HUD would go on claiming the agent was working after the user stopped it.
    private func advance(to newPhase: AgentPhase) {
        guard !isPaused else { return }
        phase = newPhase
    }

    // MARK: - User control

    /// Suspends the task at the next phase boundary.
    ///
    /// A step already in flight is allowed to finish and be recorded: a click that has been
    /// dispatched cannot be recalled, and a history that omitted it would misrepresent what
    /// happened. What pausing guarantees is that no *further* step begins.
    public func pause() {
        guard phase.isRunning else { return }
        isPaused = true
        phase = .paused
        currentActivity = "Paused"
    }

    public func resume() {
        guard isPaused else { return }
        isPaused = false
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Stops the task. Takes effect at the next check, which is never more than one action away.
    public func cancel() {
        guard !phase.isTerminal else { return }
        isCancelled = true
        isPaused = false
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        finish(.cancelled)
    }

    // MARK: - The loop

    public func run() async {
        guard phase == .idle else { return }

        switch await intelligence.availability {
        case .available:
            break
        case .unavailable(let reason, let suggestion):
            let message = [reason, suggestion].compactMap { $0 }.joined(separator: " ")
            finish(.failed(message))
            return
        }

        var stepIndex = 0

        while true {
            guard await checkpoint() else { return }

            if let limit = breachedLimit(stepIndex: stepIndex) {
                finish(.limitReached(limit))
                return
            }

            // Observe.
            advance(to: .collectingContext)
            currentActivity = "Looking at the screen"
            let context = await collectContext()
            latestContext = context

            guard await checkpoint() else { return }

            // Plan.
            advance(to: .planning)
            currentActivity = "Deciding what to do"
            let agentContext = AgentContext(
                goal: goal,
                desktop: context,
                history: history,
                gatheredInformation: gatheredInformation,
                stepIndex: stepIndex,
                stepLimit: limits.maximumSteps
            )

            let step: PlannedStep
            do {
                step = try await intelligence.planNextStep(goal: goal, context: agentContext)
            } catch {
                // A plan that cannot be produced is recorded as a failed step rather than ending
                // the task, because the usual cause — a stale element id — is fixed by looking
                // again. The consecutive-failure limit stops this from going on forever.
                recordPlanningFailure(error, index: stepIndex, context: context)
                stepIndex += 1
                continue
            }

            guard await checkpoint() else { return }

            // Terminal steps end the task immediately.
            if case .complete(let summary) = step.action {
                finish(.completed(summary))
                return
            }
            if case .fail(let reason) = step.action {
                finish(.failed(reason))
                return
            }

            // Has this already been done? The on-device model reliably fails to notice that a goal
            // is met: asked to open System Settings, it opened it, saw it open, and opened it three
            // more times until the repeat limit ended the task as a failure. For actions whose
            // effect is the same however often they run, repeating a verified success achieves
            // nothing, so it is not executed. The first time, the planner is told why; the second
            // time, the work is evidently done and the task completes.
            if let earlier = alreadySucceeded(step.action) {
                redundantProposals += 1
                if redundantProposals >= 2 {
                    finish(.completed(Self.completionSummary(for: earlier.action)))
                    return
                }
                history.append(
                    StepRecord(
                        index: stepIndex,
                        action: step.action,
                        rationale: step.rationale,
                        classification: .routine,
                        capability: .control,
                        outcome: .skipped(
                            "Not repeated: this already worked. If the goal is achieved, complete."
                        ),
                        resultingFingerprint: context.stateFingerprint
                    )
                )
                stepIndex += 1
                continue
            }
            redundantProposals = 0

            // Would this just repeat something that is going nowhere?
            if loopDetector.wouldRepeat(step.action) {
                finish(.limitReached(.repeatedActions))
                return
            }
            loopDetector.record(action: step.action, fingerprint: context.stateFingerprint)
            if let breach = loopDetector.breachedLimit() {
                finish(.limitReached(breach))
                return
            }

            // Questions for the user are handled here rather than by a capability, because the
            // answer becomes context for the next planning turn.
            if case .requestUserInput(let prompt) = step.action {
                let answered = await handleUserInput(prompt: prompt, step: step, index: stepIndex)
                stepIndex += 1
                guard answered else { return }
                continue
            }

            // Act.
            advance(to: .acting)
            pendingAction = step.action
            currentActivity = step.action.summary
            let startedAt = Date()
            let report = await executor.execute(step.action, context: context)
            pendingAction = nil

            if let produced = report.producedText, !produced.isEmpty {
                gatheredInformation.append(
                    GatheredInformation(source: sourceName(for: report.action), text: produced)
                )
            }

            // Let the interface settle before looking at it.
            advance(to: .waiting)
            currentActivity = "Waiting for the interface"
            await sleep(for: limits.actionDelay)

            guard await checkpoint() else { return }

            // Observe and verify.
            let outcome: StepOutcome
            var resultingFingerprint: String?
            if case .succeeded = report.outcome {
                advance(to: .verifying)
                currentActivity = "Checking the result"
                let after = await collector.collect(options: .lightweight)
                latestContext = after
                resultingFingerprint = after.stateFingerprint
                let verification = await verifier.verify(
                    action: report.action, before: context, after: after
                )
                outcome = Self.outcome(from: verification)
            } else {
                outcome = report.outcome
            }

            history.append(
                StepRecord(
                    index: stepIndex,
                    action: report.action,
                    rationale: step.rationale,
                    classification: report.classification,
                    capability: report.capability,
                    outcome: outcome,
                    startedAt: startedAt,
                    duration: Date().timeIntervalSince(startedAt),
                    resultingFingerprint: resultingFingerprint
                )
            )

            // A declined confirmation is the user saying no, which ends the task rather than
            // sending the agent looking for another way to do the thing they just refused.
            if case .declined = outcome {
                finish(.failed("You declined \(report.action.summary.lowercased())."))
                return
            }
            if case .blocked(let reason) = outcome {
                finish(.failed(reason))
                return
            }

            updateFailureStreak(outcome)
            stepIndex += 1
        }
    }

    // MARK: - Loop helpers

    /// Honours pause and cancellation. Returns `false` when the task should stop.
    private func checkpoint() async -> Bool {
        if isCancelled { return false }
        while isPaused && !isCancelled {
            phase = .paused
            await withCheckedContinuation { continuation in
                pauseWaiters.append(continuation)
            }
        }
        if isCancelled { return false }
        if Task.isCancelled {
            finish(.cancelled)
            return false
        }
        return true
    }

    /// Collects context, escalating to screen capture when the app exposes nothing semantic.
    ///
    /// This is principle 5 in practice: visual understanding is not the default path, it is what
    /// happens when the semantic path comes back empty.
    private func collectContext() async -> DesktopContext {
        let semantic = await collector.collect(options: .semantic)
        guard semantic.accessibility?.interactiveElements.isEmpty ?? true else {
            return semantic
        }
        currentActivity = "Reading the screen"
        return await collector.collect(options: .full)
    }

    private func breachedLimit(stepIndex: Int) -> TaskTermination.LimitKind? {
        if stepIndex >= limits.maximumSteps { return .steps }
        if Date().timeIntervalSince(startedAt) >= limits.maximumDuration { return .duration }
        if consecutiveFailures >= limits.maximumConsecutiveFailures { return .consecutiveFailures }
        return nil
    }

    private func updateFailureStreak(_ outcome: StepOutcome) {
        switch outcome {
        case .succeeded, .inconclusive:
            // An unverifiable step is not evidence of being stuck, so it does not count against
            // the failure budget — but it does not reset it either.
            if case .succeeded = outcome { consecutiveFailures = 0 }
        default:
            consecutiveFailures += 1
        }
    }

    private func handleUserInput(prompt: String, step: PlannedStep, index: Int) async -> Bool {
        advance(to: .waitingForUser)
        currentActivity = prompt
        let answer = await interaction.requestInput(UserPrompt(message: prompt, style: .input))

        guard let answer, !answer.trimmed.isEmpty else {
            history.append(
                StepRecord(
                    index: index,
                    action: step.action,
                    rationale: step.rationale,
                    classification: .routine,
                    capability: .user,
                    outcome: .declined
                )
            )
            finish(.failed("AbleKit needed an answer to carry on."))
            return false
        }

        gatheredInformation.append(GatheredInformation(source: "You", text: answer))
        history.append(
            StepRecord(
                index: index,
                action: step.action,
                rationale: step.rationale,
                classification: .routine,
                capability: .user,
                outcome: .succeeded
            )
        )
        return true
    }

    private func recordPlanningFailure(_ error: any Error, index: Int, context: DesktopContext) {
        let message = (error as? IntelligenceError)?.description ?? error.localizedDescription
        history.append(
            StepRecord(
                index: index,
                action: .wait(seconds: 0),
                rationale: "Planning the next step",
                classification: .routine,
                capability: .control,
                outcome: .failed(message),
                resultingFingerprint: context.stateFingerprint
            )
        )
        consecutiveFailures += 1
    }

    private func finish(_ termination: TaskTermination) {
        guard !phase.isTerminal else { return }
        self.termination = termination
        pendingAction = nil
        switch termination {
        case .completed: phase = .completed
        case .cancelled: phase = .cancelled
        case .failed, .limitReached: phase = .failed
        }
        currentActivity = termination.userMessage
    }

    /// Sleeps, but wakes early if the user cancels.
    private func sleep(for interval: TimeInterval) async {
        guard interval > 0 else { return }
        let deadline = Date().addingTimeInterval(interval)
        // Stepping in small slices keeps "Stop" responsive during the settle delay, which is
        // otherwise the longest the user would ever wait for the agent to notice them.
        while Date() < deadline && !isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            try? await Task.sleep(for: .milliseconds(Int(min(remaining, 0.05) * 1000)))
        }
    }

    /// The earlier verified success of this same action, if the action is one whose effect does not
    /// change with repetition.
    private func alreadySucceeded(_ action: DesktopAction) -> StepRecord? {
        guard Self.isIdempotent(action) else { return nil }
        let signature = LoopDetector.signature(for: action)
        return history.last { record in
            record.outcome.isSuccess && LoopDetector.signature(for: record.action) == signature
        }
    }

    /// Actions that leave the machine in the same state however many times they run.
    ///
    /// Clicks, keystrokes and scrolls are deliberately absent: pressing Next twice or scrolling
    /// twice is ordinary progress.
    static func isIdempotent(_ action: DesktopAction) -> Bool {
        switch action {
        case .openApplication, .activateApplication:
            true
        case .nativeAction(let operation):
            switch operation {
            case .openURL, .openSystemSettings, .revealInFinder, .setClipboard: true
            }
        default:
            false
        }
    }

    static func completionSummary(for action: DesktopAction) -> String {
        switch action {
        case .openApplication(let app), .activateApplication(let app):
            "\(app.displayName) is open."
        default:
            "Done: \(action.summary.lowercased())."
        }
    }

    private func sourceName(for action: DesktopAction) -> String {
        if case .askAIBridge(let bridge, _) = action { return bridge.displayName }
        return "AbleKit"
    }

    private static func outcome(from verification: VerificationResult) -> StepOutcome {
        switch verification.outcome {
        case .succeeded: .succeeded
        case .failed: .failed(verification.reason)
        case .inconclusive: .inconclusive(verification.reason)
        }
    }
}
