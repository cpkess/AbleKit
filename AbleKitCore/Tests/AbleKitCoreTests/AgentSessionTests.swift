import CoreGraphics
import Foundation
import Testing

@testable import AbleKitCore

@MainActor
private func makeSession(
    goal: String = "do the thing",
    intelligence: ScriptedIntelligence,
    collector: ScriptedCollector = ScriptedCollector(repeating: .fixture()),
    capability: RecordingCapability = RecordingCapability(),
    policy: ActionPolicy = ActionPolicy(),
    user: ScriptedUser = ScriptedUser(),
    limits: TaskLimits = TaskLimits(actionDelay: 0)
) -> AgentSession {
    let router = CapabilityRouter(capabilities: [capability])
    return AgentSession(
        goal: goal,
        collector: collector,
        intelligence: intelligence,
        executor: Executor(router: router, policy: policy, interaction: user),
        verifier: Verifier(intelligence: intelligence),
        interaction: user,
        limits: limits
    )
}

@Suite("Agent loop")
@MainActor
struct AgentSessionTests {

    @Test("A task that reaches its goal completes and says so")
    func completesSuccessfully() async {
        let intelligence = ScriptedIntelligence(actions: [
            .click(target: .element(.fixture())),
            .complete(summary: "Updated the tracker."),
        ])
        let capability = RecordingCapability()
        let session = makeSession(intelligence: intelligence, capability: capability)

        await session.run()

        #expect(session.phase == .completed)
        #expect(session.termination == .completed("Updated the tracker."))
        #expect(session.history.count == 1)
        #expect(session.history[0].outcome == .succeeded)
        #expect(capability.executed.count == 1)
    }

    @Test("A failing verification is recorded as a failed step, not a success")
    func recordsVerificationFailure() async {
        let intelligence = ScriptedIntelligence(actions: [
            .click(target: .element(.fixture())),
            .complete(summary: "done"),
        ])
        intelligence.verification = .failed("Nothing changed.")
        let session = makeSession(intelligence: intelligence)

        await session.run()

        #expect(session.history[0].outcome == .failed("Nothing changed."))
    }

    @Test("An unverifiable step is reported as unverified rather than claimed as done")
    func recordsInconclusive() async {
        let intelligence = ScriptedIntelligence(actions: [
            .click(target: .element(.fixture())),
            .complete(summary: "done"),
        ])
        intelligence.verification = .inconclusive("The screen does not say.")
        let session = makeSession(intelligence: intelligence)

        await session.run()

        #expect(session.history[0].outcome == .inconclusive("The screen does not say."))
        #expect(session.phase == .completed)
    }

    @Test("The step limit ends the task")
    func stopsAtStepLimit() async {
        let intelligence = ScriptedIntelligence.neverFinishing()
        let session = makeSession(
            intelligence: intelligence,
            limits: TaskLimits(maximumSteps: 3, actionDelay: 0)
        )

        await session.run()

        #expect(session.phase == .failed)
        #expect(session.termination == .limitReached(.steps))
        #expect(session.history.count == 3)
    }

    @Test("Repeating the same action stops the task")
    func stopsOnRepeatedAction() async {
        let element = ElementReference.fixture()
        let intelligence = ScriptedIntelligence.repeating(.click(target: .element(element)))
        let session = makeSession(
            intelligence: intelligence,
            limits: TaskLimits(maximumSteps: 20, maximumRetriesPerAction: 2, actionDelay: 0)
        )

        await session.run()

        #expect(session.termination == .limitReached(.repeatedActions))
        // Attempted up to the retry budget, then stopped rather than spending the step limit.
        #expect(session.history.count <= 3)
    }

    @Test("An unchanging screen stops the task")
    func stopsOnFrozenScreen() async {
        // Distinct actions each time, so only the frozen screen can trip the detector.
        let intelligence = ScriptedIntelligence.neverFinishing()
        let session = makeSession(
            intelligence: intelligence,
            collector: ScriptedCollector(repeating: .fixture(), varying: false),
            limits: TaskLimits(
                maximumSteps: 20,
                maximumConsecutiveFailures: 99,
                maximumRepeatedStates: 3,
                actionDelay: 0
            )
        )

        await session.run()

        #expect(session.termination == .limitReached(.repeatedStates))
    }

    @Test("Repeated failures stop the task")
    func stopsOnConsecutiveFailures() async {
        let intelligence = ScriptedIntelligence.neverFinishing()
        intelligence.verification = .failed("did not work")
        let session = makeSession(
            intelligence: intelligence,
            limits: TaskLimits(maximumSteps: 20, maximumConsecutiveFailures: 2, actionDelay: 0)
        )

        await session.run()

        #expect(session.termination == .limitReached(.consecutiveFailures))
    }

    @Test("Cancelling stops the task immediately")
    func cancels() async {
        let intelligence = ScriptedIntelligence.neverFinishing()
        let session = makeSession(
            intelligence: intelligence,
            limits: TaskLimits(maximumSteps: 500, actionDelay: 0.05)
        )

        let task = Task { await session.run() }
        // Let a step or two happen, then stop.
        try? await Task.sleep(for: .milliseconds(60))
        session.cancel()
        await task.value

        #expect(session.phase == .cancelled)
        #expect(session.termination == .cancelled)
        #expect(session.history.count < 500)
    }

    @Test("Pausing holds the task until it is resumed")
    func pausesAndResumes() async {
        let intelligence = ScriptedIntelligence.neverFinishing()
        let session = makeSession(
            intelligence: intelligence,
            limits: TaskLimits(maximumSteps: 500, maximumConsecutiveFailures: 99, actionDelay: 0.01)
        )

        let task = Task { await session.run() }
        try? await Task.sleep(for: .milliseconds(40))
        session.pause()
        #expect(session.phase == .paused)

        // A step already in flight is allowed to finish and be recorded — dropping it would make
        // the history lie about what was done. What must not happen is a *new* step starting, so
        // settle first, then assert the count holds.
        try? await Task.sleep(for: .milliseconds(60))
        let countWhilePaused = session.history.count
        try? await Task.sleep(for: .milliseconds(80))
        #expect(session.history.count == countWhilePaused)
        #expect(session.phase == .paused)

        session.resume()
        try? await Task.sleep(for: .milliseconds(40))
        session.cancel()
        await task.value

        #expect(session.history.count > countWhilePaused)
    }

    @Test("Declining a confirmation ends the task rather than finding another way")
    func declinedConfirmationEndsTask() async {
        let sendButton = ElementReference.fixture(id: "send", title: "Send")
        let intelligence = ScriptedIntelligence(actions: [
            .click(target: .element(sendButton)),
            .complete(summary: "sent"),
        ])
        let session = makeSession(
            intelligence: intelligence,
            collector: ScriptedCollector(repeating: .fixture(elements: [sendButton])),
            user: ScriptedUser(confirms: false)
        )

        await session.run()

        #expect(session.phase == .failed)
        #expect(session.history.last?.outcome == .declined)
    }

    @Test("A confirmed consequential action goes ahead")
    func confirmedActionProceeds() async {
        let sendButton = ElementReference.fixture(id: "send", title: "Send")
        let intelligence = ScriptedIntelligence(actions: [
            .click(target: .element(sendButton)),
            .complete(summary: "sent"),
        ])
        let capability = RecordingCapability()
        let session = makeSession(
            intelligence: intelligence,
            collector: ScriptedCollector(repeating: .fixture(elements: [sendButton])),
            capability: capability,
            user: ScriptedUser(confirms: true)
        )

        await session.run()

        #expect(session.phase == .completed)
        #expect(capability.executed.count == 1)
    }

    @Test("A blocked action ends the task and says why")
    func blockedActionEndsTask() async {
        let signIn = ElementReference.fixture(id: "signin", title: "Sign in")
        let intelligence = ScriptedIntelligence(actions: [.click(target: .element(signIn))])
        let capability = RecordingCapability()
        let session = makeSession(
            intelligence: intelligence,
            collector: ScriptedCollector(repeating: .fixture(elements: [signIn])),
            capability: capability
        )

        await session.run()

        #expect(session.phase == .failed)
        #expect(capability.executed.isEmpty)
        if case .blocked = session.history.last?.outcome {} else {
            Issue.record("expected the step to be blocked, got \(String(describing: session.history.last?.outcome))")
        }
    }

    @Test("A planning error is recorded and the agent looks again")
    func recoversFromPlanningError() async {
        let intelligence = ScriptedIntelligence(steps: [
            .failure(.undecodableStep("no such control")),
            .success(PlannedStep(action: .complete(summary: "recovered"), rationale: "")),
        ])
        let session = makeSession(intelligence: intelligence)

        await session.run()

        #expect(session.phase == .completed)
        #expect(session.history.count == 1)
        #expect(session.history[0].outcome == .failed("AbleKit could not turn that into an action: no such control"))
    }

    @Test("Text produced by a step becomes context for later steps")
    func gathersProducedText() async {
        let intelligence = ScriptedIntelligence(actions: [
            .askAIBridge(bridge: .copilot, prompt: "what is the status?"),
            .complete(summary: "done"),
        ])
        let capability = RecordingCapability(kind: .bridge)
        capability.result = .success(
            CapabilityOutcome(succeeded: true, producedText: "Milestone 2 slipped a week.")
        )
        let session = makeSession(intelligence: intelligence, capability: capability)

        await session.run()

        #expect(session.gatheredInformation.count == 1)
        #expect(session.gatheredInformation[0].source == "Copilot")
        #expect(session.gatheredInformation[0].text == "Milestone 2 slipped a week.")
    }

    @Test("An app with no readable controls escalates to reading the screen")
    func escalatesToVisualContext() async {
        let blind = DesktopContext.fixture(elements: [])
        let collector = ScriptedCollector(repeating: blind)
        let intelligence = ScriptedIntelligence(actions: [.complete(summary: "done")])
        let session = makeSession(intelligence: intelligence, collector: collector)

        await session.run()

        #expect(collector.requestedOptions.contains(.semantic))
        #expect(collector.requestedOptions.contains(.full))
    }

    @Test("An app with readable controls is never screenshotted")
    func doesNotCaptureWhenSemanticsSuffice() async {
        let collector = ScriptedCollector(repeating: .fixture())
        let intelligence = ScriptedIntelligence(actions: [.complete(summary: "done")])
        let session = makeSession(intelligence: intelligence, collector: collector)

        await session.run()

        #expect(!collector.requestedOptions.contains { $0.includesScreenshot })
    }

    @Test("A task refuses to start when local reasoning is unavailable")
    func refusesWithoutIntelligence() async {
        let intelligence = ScriptedIntelligence(actions: [.complete(summary: "done")])
        intelligence.availabilityValue = .unavailable(
            reason: "Apple Intelligence is switched off.",
            recoverySuggestion: "Turn it on in System Settings."
        )
        let session = makeSession(intelligence: intelligence)

        await session.run()

        #expect(session.phase == .failed)
        #expect(session.termination?.userMessage.contains("switched off") == true)
        #expect(intelligence.planCallCount == 0)
    }

    @Test("A question to the user feeds their answer back into planning")
    func userAnswerBecomesContext() async {
        let intelligence = ScriptedIntelligence(actions: [
            .requestUserInput(prompt: "Which quarter?"),
            .complete(summary: "done"),
        ])
        let session = makeSession(
            intelligence: intelligence, user: ScriptedUser(input: "Q3")
        )

        await session.run()

        #expect(session.gatheredInformation.first?.text == "Q3")
        #expect(session.gatheredInformation.first?.source == "You")
        #expect(session.phase == .completed)
    }

    @Test("A question the user ignores stops the task")
    func unansweredQuestionStopsTask() async {
        let intelligence = ScriptedIntelligence(actions: [
            .requestUserInput(prompt: "Which quarter?"),
            .complete(summary: "done"),
        ])
        let session = makeSession(intelligence: intelligence, user: ScriptedUser(input: nil))

        await session.run()

        #expect(session.phase == .failed)
        #expect(session.history.last?.outcome == .declined)
    }
}
