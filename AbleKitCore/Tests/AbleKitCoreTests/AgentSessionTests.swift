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
        let session = makeSession(
            intelligence: intelligence,
            // A screen that does not change is the failure the system itself can see.
            collector: ScriptedCollector(repeating: .fixture(), varying: false)
        )

        await session.run()

        #expect(session.history[0].outcome == .failed("Nothing on screen changed."))
    }

    @Test("A model's failure verdict on a changed screen does not end the task")
    func modelFailureVerdictIsNotFatal() async {
        let intelligence = ScriptedIntelligence(actions: [
            .click(target: .element(.fixture())),
            .click(target: .element(.fixture(id: "e2", title: "Next"))),
            .click(target: .element(.fixture(id: "e3", title: "Finish"))),
            .complete(summary: "done"),
        ])
        intelligence.verification = .failed("looks wrong to me")
        let session = makeSession(
            intelligence: intelligence,
            limits: TaskLimits(maximumConsecutiveFailures: 2, actionDelay: 0)
        )

        await session.run()

        #expect(session.phase == .completed)
        #expect(session.history.allSatisfy { if case .inconclusive = $0.outcome { true } else { false } })
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
        let capability = RecordingCapability()
        capability.result = .failure(.executionFailed("did not work"))
        let session = makeSession(
            intelligence: intelligence,
            capability: capability,
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

    @Test("An app that is already open is not reopened, and the task completes once it is done")
    func completesInsteadOfReopening() async {
        // The planner that motivated this: it keeps asking to open an app that is already open.
        let intelligence = ScriptedIntelligence.repeating(
            .openApplication(ApplicationReference(name: "Tracker"))
        )
        intelligence.goalCheck = GoalCheck(isAchieved: true, summary: "Tracker is open.")
        let capability = RecordingCapability(kind: .native)
        let session = makeSession(intelligence: intelligence, capability: capability)

        await session.run()

        #expect(session.phase == .completed)
        #expect(session.termination == .completed("Tracker is open."))
        // Opened once; the repeat was never executed.
        #expect(capability.executed.count == 1)
    }

    @Test("A repeat is skipped, not treated as completion, while work remains")
    func redundantProposalDoesNotFinishAnUnfinishedTask() async {
        // "Use Calculator to work out 12 times 7" once finished the moment Calculator opened.
        let intelligence = ScriptedIntelligence.repeating(
            .openApplication(ApplicationReference(name: "Tracker"))
        )
        intelligence.goalCheck = .notYet
        let capability = RecordingCapability(kind: .native)
        let session = makeSession(
            intelligence: intelligence,
            capability: capability,
            limits: TaskLimits(maximumSteps: 6, maximumConsecutiveFailures: 99, actionDelay: 0)
        )

        await session.run()

        #expect(session.termination != .completed("Tracker is open."))
        #expect(capability.executed.count == 1)
        #expect(session.history.contains { if case .skipped = $0.outcome { true } else { false } })
    }

    @Test("A task ends as soon as the goal is reached, without further steps")
    func stopsWhenGoalIsReached() async {
        let intelligence = ScriptedIntelligence.neverFinishing()
        intelligence.goalCheck = GoalCheck(isAchieved: true, summary: "The status is updated.")
        let capability = RecordingCapability()
        let session = makeSession(intelligence: intelligence, capability: capability)

        await session.run()

        #expect(session.phase == .completed)
        #expect(session.termination == .completed("The status is updated."))
        // One step ran; the check ended the task before a second could.
        #expect(capability.executed.count == 1)
    }

    @Test("One redundant proposal is a nudge, not the end, when new work follows")
    func redundantProposalThenProgress() async {
        let open = DesktopAction.openApplication(ApplicationReference(name: "Tracker"))
        let intelligence = ScriptedIntelligence(actions: [
            open,
            open,
            .click(target: .element(.fixture())),
            .complete(summary: "Saved."),
        ])
        let capability = RecordingCapability()
        let session = makeSession(intelligence: intelligence, capability: capability)

        await session.run()

        #expect(session.termination == .completed("Saved."))
        #expect(capability.executed.count == 2)
    }

    @Test("Repeating a click is progress, not redundancy")
    func clicksAreNotIdempotent() {
        #expect(!AgentSession.isIdempotent(.click(target: .element(.fixture()))))
        #expect(!AgentSession.isIdempotent(.scroll(target: .point(.zero), deltaX: 0, deltaY: -3)))
        #expect(AgentSession.isIdempotent(.openApplication(ApplicationReference(name: "Mail"))))
        #expect(AgentSession.isIdempotent(.nativeAction(.openURL("https://example.com"))))
    }
}

@Suite("Planning failures")
@MainActor
struct PlanningFailureTests {
    @Test("An unusable plan is shown to the model as a planning problem, not as an action")
    func planningFailureInPrompt() {
        let record = StepRecord(
            index: 0, action: .wait(seconds: 0), rationale: "", classification: .routine,
            capability: .control, outcome: .failed("openApplication needs the application's name"),
            isPlanningFailure: true
        )
        let prompt = PromptBuilder().planningPrompt(
            goal: "g", context: AgentContext(goal: "g", desktop: .fixture(), history: [record])
        )
        #expect(prompt.contains("Your previous step could not be used: openApplication needs"))
        #expect(!prompt.contains("Waiting 0.0s"))
    }
}

@Suite("Planning a task")
@MainActor
struct TaskPlanTests {

    @Test("A plan is written once, and the agent works through it a step at a time")
    func worksThroughThePlan() async {
        let intelligence = ScriptedIntelligence(actions: [
            .click(target: .element(.fixture(id: "e1", title: "1"))),
            .click(target: .element(.fixture(id: "e2", title: "2"))),
            .click(target: .element(.fixture(id: "e3", title: "Equals"))),
        ])
        intelligence.scriptedPlan = ["Enter 12", "Press equals"]
        intelligence.goalCheck = GoalCheck(isAchieved: true, summary: "12 is on screen.")
        let session = makeSession(intelligence: intelligence)

        await session.run()

        #expect(intelligence.planCount == 1)
        #expect(session.plan.steps.map(\.intent) == ["Enter 12", "Press equals"])
        // One action per sub-goal, then the goal check ends it — not the step limit.
        #expect(session.phase == .completed)
        #expect(session.termination == .completed("12 is on screen."))
    }

    @Test("The plan, and where it has got to, is put in front of the planner")
    func planInPrompt() {
        var plan = TaskPlan(intents: ["Clear the display", "Enter 12", "Press equals"])
        plan.completeCurrent()
        let prompt = PromptBuilder().planningPrompt(
            goal: "g", context: AgentContext(goal: "g", desktop: .fixture(), plan: plan)
        )
        #expect(prompt.contains("THE PLAN"))
        #expect(prompt.contains("\u{2713} 1. Clear the display"))
        #expect(prompt.contains("\u{2192} 2. Enter 12"))
        #expect(prompt.contains("DO THIS NOW: Enter 12"))
    }

    @Test("A sub-goal that will not finish makes the agent rethink the plan, not grind on")
    func revisesWhenStuck() async {
        let intelligence = ScriptedIntelligence.neverFinishing()
        // Nothing ever completes a sub-goal.
        intelligence.verification = VerificationResult(
            outcome: .succeeded, reason: "no change", completedSubGoal: false
        )
        intelligence.scriptedPlan = ["Enter 12", "Press equals"]
        intelligence.scriptedRevision = ["Type 12 with the keyboard", "Press equals"]
        let session = makeSession(
            intelligence: intelligence,
            limits: TaskLimits(
                maximumSteps: 12, maximumConsecutiveFailures: 99, actionDelay: 0,
                attemptsPerPlanStep: 2, maximumPlanRevisions: 1
            )
        )

        await session.run()

        #expect(intelligence.revisionCount >= 1)
        #expect(session.plan.steps.first?.intent == "Type 12 with the keyboard")
    }

    @Test("A rewrite keeps the work already done")
    func revisionKeepsCompletedWork() {
        var plan = TaskPlan(intents: ["Open the file", "Change the status", "Save"])
        plan.completeCurrent()
        plan.replaceRemaining(with: ["Click Edit", "Set the status to Amber", "Press Save"])

        #expect(plan.steps.map(\.intent) == ["Open the file", "Click Edit", "Set the status to Amber", "Press Save"])
        #expect(plan.completedCount == 1)
        #expect(plan.current?.intent == "Click Edit")
        #expect(plan.revisions == 1)
    }

    @Test("A plan that finishes without the goal being met is reworked, then given up honestly")
    func planFinishedButGoalNotMet() async {
        let intelligence = ScriptedIntelligence.neverFinishing()
        intelligence.scriptedPlan = ["Do the thing"]
        intelligence.scriptedRevision = ["Do the thing another way"]
        intelligence.goalCheck = .notYet
        let session = makeSession(
            intelligence: intelligence,
            limits: TaskLimits(
                maximumSteps: 20, maximumConsecutiveFailures: 99, maximumRepeatedStates: 99,
                actionDelay: 0, attemptsPerPlanStep: 9, maximumPlanRevisions: 1
            )
        )

        await session.run()

        #expect(session.phase == .failed)
        #expect(session.termination?.userMessage.contains("not done") == true)
    }

    @Test("Position is reported for the task window")
    func position() {
        var plan = TaskPlan(intents: ["One", "Two", "Three"])
        #expect(plan.positionDescription == "Step 1 of 3")
        plan.completeCurrent()
        #expect(plan.positionDescription == "Step 2 of 3")
        plan.completeCurrent()
        plan.completeCurrent()
        #expect(plan.isComplete)
        #expect(plan.positionDescription == nil)
    }

    @Test("A task with no plan still runs, checking the goal after each step")
    func worksWithoutAPlan() async {
        let intelligence = ScriptedIntelligence(actions: [.click(target: .element(.fixture()))])
        intelligence.scriptedPlan = []
        intelligence.goalCheck = GoalCheck(isAchieved: true, summary: "Done.")
        let session = makeSession(intelligence: intelligence)

        await session.run()

        #expect(session.phase == .completed)
    }
}

@Suite("Plan hygiene")
struct PlanHygieneTests {

    @Test("Steps that merely open an app are dropped")
    func dropsOpeningSteps() {
        let plan = TaskPlan(intents: ["Open Calculator", "Launch the app", "The display shows 12"])
        #expect(plan.steps.map(\.intent) == ["The display shows 12"])
    }

    @Test("Steps repeated back to back are collapsed")
    func collapsesRepeats() {
        let plan = TaskPlan(intents: ["Enter 12", "enter 12", "Press equals"])
        #expect(plan.steps.map(\.intent) == ["Enter 12", "Press equals"])
    }

    @Test("Opening something that is not an app is real work, and kept")
    func keepsRealWork() {
        #expect(!TaskPlan.isOpeningAnApp("Open the file", applications: ["Calculator", "Finder"]))
        #expect(!TaskPlan.isOpeningAnApp("Open the entry for Atlas", applications: ["Calculator"]))
        #expect(TaskPlan.isOpeningAnApp("Open Calculator", applications: ["Calculator"]))
        #expect(TaskPlan.isOpeningAnApp("Launch the app", applications: []))
    }
}
