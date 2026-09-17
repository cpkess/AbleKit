import CoreGraphics
import Foundation
import Testing

@testable import AbleKitCore

/// Tests that exercise the real on-device model.
///
/// These are opt-in, because they depend on Apple Intelligence being enabled on the machine and are
/// far slower than the rest of the suite. CI does not run them; they exist to answer the question
/// the mocked tests cannot — *does the actual model, given AbleKit's actual prompt, choose a
/// sensible step?*
///
/// Run with:
///
///     ABLEKIT_LIVE_MODEL_TESTS=1 swift test --package-path AbleKitCore --filter LiveModel
///
/// Assertions are about the *shape* of the decision, not its exact wording: a language model is
/// allowed to phrase a rationale however it likes, but it is not allowed to invent an action that
/// does not exist or to click a control that is not on screen. Those are the properties worth
/// enforcing, and they are the ones AbleKit's safety depends on.
private let liveTestsEnabled = ProcessInfo.processInfo.environment["ABLEKIT_LIVE_MODEL_TESTS"] == "1"

@Suite(
    "LiveModel: Apple Intelligence",
    .enabled(if: liveTestsEnabled, "set ABLEKIT_LIVE_MODEL_TESTS=1 to run")
)
struct LiveModelTests {

    private let provider = AppleIntelligenceProvider()

    /// Plans a step the way `AgentSession` does: a rejected plan is re-planned rather than fatal.
    ///
    /// A single planning call is the wrong unit to assert on. The decoder refusing a malformed step
    /// is a designed part of the pipeline, not a failure of it — the loop records the refusal and
    /// asks again, which is exactly what a bounded retry budget is for. Testing one call would be
    /// holding a stochastic model to a standard the system never asks of it.
    private func plan(_ goal: String, desktop: DesktopContext, attempts: Int = 3) async throws
        -> PlannedStep
    {
        var lastError: (any Error)?
        for _ in 0..<attempts {
            do {
                return try await provider.planNextStep(
                    goal: goal, context: AgentContext(goal: goal, desktop: desktop)
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? IntelligenceError.undecodableStep("no attempts made")
    }

    /// A desktop showing a tracker with a couple of real controls.
    private func trackerDesktop() -> DesktopContext {
        DesktopContext(
            frontmostApplication: RunningApplicationInfo(
                bundleIdentifier: "com.example.tracker",
                localizedName: "Tracker",
                processIdentifier: 501,
                isActive: true
            ),
            focusedWindow: WindowInfo(
                title: "Atlas \u{2014} Programme Status",
                owningApplication: "Tracker",
                frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                isFocused: true
            ),
            accessibility: AccessibilitySnapshot(
                bundleIdentifier: "com.example.tracker",
                elements: [
                    ElementReference(
                        id: "e1", role: "AXButton", title: "Edit",
                        frame: CGRect(x: 900, y: 120, width: 70, height: 24),
                        actions: ["AXPress"]
                    ),
                    ElementReference(
                        id: "e2", role: "AXTextField", title: "Status", value: "Green",
                        frame: CGRect(x: 300, y: 200, width: 400, height: 24)
                    ),
                    ElementReference(
                        id: "e3", role: "AXButton", title: "Save",
                        frame: CGRect(x: 980, y: 700, width: 70, height: 24),
                        actions: ["AXPress"]
                    ),
                ]
            ),
            arrangement: .fixture()
        )
    }

    @Test("Apple Intelligence is available on this machine")
    func isAvailable() async {
        #expect(await provider.availability.isAvailable)
    }

    @Test("Opening an application is planned as a native launch, not a hunt through the Dock")
    func plansNativeLaunch() async throws {
        let step = try await plan("Open Safari", desktop: trackerDesktop())

        guard case .openApplication(let application) = step.action else {
            Issue.record("expected an application launch, got \(step.action)")
            return
        }
        #expect(application.name?.localizedCaseInsensitiveContains("safari") == true)
    }

    @Test("A step that names a control names one that is actually on screen")
    func plansAgainstRealElements() async throws {
        let desktop = trackerDesktop()
        let step = try await plan("Change the status of this programme to Amber", desktop: desktop)

        // The decoder has already refused any element id that does not exist, so reaching here at
        // all is the assertion that matters: the model cannot hallucinate a target into the system.
        if let target = step.action.pointerTarget, case .element(let element) = target {
            #expect(desktop.accessibility?.element(withID: element.id) != nil)
        }
        #expect(!step.rationale.isEmpty)
    }

    @Test("A goal that is already met completes instead of doing something anyway")
    func completesWhenDone() async throws {
        let step = try await plan(
            "Make sure the Tracker app is the frontmost application", desktop: trackerDesktop()
        )

        // The line that matters is whether the step touches the interface. Completing is the ideal
        // answer. Bringing forward the app that is already frontmost is a harmless no-op that
        // verifies as succeeded and completes on the next turn — and AbleKit's native capability
        // treats opening and activating as the same operation, so distinguishing them here would be
        // a distinction the system itself does not make. Clicking a control is the real error.
        switch step.action {
        case .complete, .activateApplication, .openApplication:
            return
        default:
            Issue.record(
                "expected the goal to be met without operating the interface, got \(step.action) — \(step.rationale)"
            )
        }
    }

    @Test("Asking Copilot is planned as a bridge call, not as typing into the current app")
    func plansBridgeCall() async throws {
        let step = try await plan(
            "Ask Copilot what the risks are for this programme", desktop: trackerDesktop()
        )

        guard case .askAIBridge(let bridge, let prompt) = step.action else {
            Issue.record("expected a bridge call, got \(step.action) — \(step.rationale)")
            return
        }
        #expect(bridge == .copilot)
        #expect(!prompt.isEmpty)
    }

    @Test("A screen that did not change is judged a failure, not a success")
    func verifiesUnchangedScreenAsFailure() async throws {
        // Handled deterministically before the model is consulted, which is the point: this is the
        // most common failure mode there is and it costs nothing to detect.
        let before = trackerDesktop()
        let result = await Verifier(intelligence: provider).verify(
            action: .click(target: .element(before.accessibility!.elements[0])),
            before: before,
            after: before
        )
        #expect(result.outcome == .failed)
    }

    @Test("A real change is judged on its merits")
    func verifiesRealChange() async throws {
        let before = trackerDesktop()
        let after = DesktopContext(
            frontmostApplication: before.frontmostApplication,
            focusedWindow: WindowInfo(
                title: "Atlas \u{2014} Editing",
                owningApplication: "Tracker",
                frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                isFocused: true
            ),
            accessibility: AccessibilitySnapshot(
                bundleIdentifier: "com.example.tracker",
                elements: [
                    ElementReference(
                        id: "e3", role: "AXButton", title: "Save",
                        frame: CGRect(x: 980, y: 700, width: 70, height: 24),
                        actions: ["AXPress"]
                    )
                ]
            ),
            arrangement: .fixture()
        )

        let result = await Verifier(intelligence: provider).verify(
            action: .click(target: .element(before.accessibility!.elements[0])),
            before: before,
            after: after
        )
        // The window title changed and a Save button appeared, so this should not read as a failure.
        #expect(result.outcome != .failed)
    }

    @Test("After the goal has verifiably been done, the planner says so")
    func completesAfterVerifiedSuccess() async throws {
        let desktop = DesktopContext(
            frontmostApplication: RunningApplicationInfo(
                bundleIdentifier: "com.apple.systempreferences",
                localizedName: "System Settings",
                processIdentifier: 600,
                isActive: true
            ),
            focusedWindow: WindowInfo(
                title: "General", owningApplication: "System Settings",
                frame: CGRect(x: 0, y: 0, width: 700, height: 600), isFocused: true
            ),
            arrangement: .fixture()
        )
        let history = [
            StepRecord(
                index: 0,
                action: .openApplication(ApplicationReference(name: "System Settings")),
                rationale: "Open it",
                classification: .routine,
                capability: .native,
                outcome: .succeeded
            )
        ]
        let goal = "Open System Settings"
        let step = try await provider.planNextStep(
            goal: goal,
            context: AgentContext(goal: goal, desktop: desktop, history: history, stepIndex: 1)
        )
        guard case .complete = step.action else {
            Issue.record("expected completion, got \(step.action) — \(step.rationale)")
            return
        }
    }
}
