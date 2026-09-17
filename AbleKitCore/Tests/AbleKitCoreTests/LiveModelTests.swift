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

    @Test("Once the goal is done, the agent finishes without doing it again")
    @MainActor
    func finishesAfterVerifiedSuccess() async throws {
        // The whole loop, with the real planner and a scripted desktop, because what the user gets
        // is the agent's behaviour — planner and repeat guard together — not the planner's alone.
        let settings = DesktopContext(
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
        let capability = RecordingCapability(kind: .native)
        let session = AgentSession(
            goal: "Open System Settings",
            collector: ScriptedCollector(repeating: settings),
            intelligence: provider,
            executor: Executor(router: CapabilityRouter(capabilities: [capability]), policy: ActionPolicy()),
            verifier: Verifier(intelligence: provider),
            limits: TaskLimits(maximumSteps: 6, actionDelay: 0)
        )

        await session.run()

        #expect(session.phase == .completed, "ended \(session.phase): \(session.termination?.userMessage ?? "")")
        #expect(capability.executed.count <= 1, "executed \(capability.executed)")
    }

    private func textEditDesktop(screenText: [RecognizedText] = [], elements: [ElementReference] = [])
        -> DesktopContext
    {
        DesktopContext(
            frontmostApplication: RunningApplicationInfo(
                bundleIdentifier: "com.apple.TextEdit", localizedName: "TextEdit",
                processIdentifier: 700, isActive: true
            ),
            focusedWindow: WindowInfo(
                title: "Untitled", owningApplication: "TextEdit",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600), isFocused: true
            ),
            accessibility: AccessibilitySnapshot(
                bundleIdentifier: "com.apple.TextEdit",
                elements: elements,
                menuItems: [
                    MenuItem(path: ["File", "New"]), MenuItem(path: ["File", "Open\u{2026}"]),
                    MenuItem(path: ["File", "Save\u{2026}"]), MenuItem(path: ["Edit", "Select All"]),
                    MenuItem(path: ["Edit", "Copy"]), MenuItem(path: ["Format", "Font", "Bold"]),
                    MenuItem(path: ["Format", "Font", "Italic"]),
                    MenuItem(path: ["Format", "Make Plain Text"]),
                ]
            ),
            screen: screenText.isEmpty ? nil : ScreenObservation(
                image: nil,
                geometry: CaptureGeometry(
                    region: CGRect(x: 0, y: 0, width: 800, height: 600),
                    pixelSize: CGSize(width: 1600, height: 1200)
                ),
                textRegions: screenText
            ),
            arrangement: .fixture()
        )
    }

    @Test("An app command is planned as a menu choice")
    func plansMenuCommand() async throws {
        let step = try await plan("Create a new TextEdit document", desktop: textEditDesktop())
        #expect(step.action == .chooseMenuItem(path: ["File", "New"]), "got \(step.action) — \(step.rationale)")
    }

    @Test("Formatting is planned through the Format menu")
    func plansNestedMenuCommand() async throws {
        let step = try await plan("Make the selected text bold", desktop: textEditDesktop())
        #expect(
            step.action == .chooseMenuItem(path: ["Format", "Font", "Bold"])
                || step.action == .hotkey(key: .character("b"), modifiers: [.command]),
            "got \(step.action) — \(step.rationale)"
        )
    }

    @Test("Text found only on screen can be clicked by its id")
    func plansClickOnScreenText() async throws {
        let desktop = textEditDesktop(screenText: [
            RecognizedText(string: "Welcome", confidence: 0.9, frame: CGRect(x: 100, y: 80, width: 120, height: 30)),
            RecognizedText(string: "Get Started", confidence: 0.9, frame: CGRect(x: 340, y: 400, width: 120, height: 30)),
        ])
        let step = try await plan("Click Get Started", desktop: desktop)
        #expect(
            step.action == .click(target: .point(CGPoint(x: 400, y: 415))),
            "got \(step.action) — \(step.rationale)"
        )
    }

    @Test("Typing names the field it is meant for")
    func focusesBeforeTyping() async throws {
        let field = ElementReference(
            id: "e4", role: "AXTextField", title: "Name",
            frame: CGRect(x: 100, y: 100, width: 300, height: 24)
        )
        let step = try await plan("Type Chris into the Name field", desktop: textEditDesktop(elements: [field]))
        #expect(
            step.action == .typeText("Chris", into: field) || step.action == .click(target: .element(field)),
            "got \(step.action) — \(step.rationale)"
        )
    }

    // MARK: - Mirrors of the first live evaluation's failures

    private func appDesktop(
        app: String, bundle: String, window: String,
        elements: [ElementReference] = [], menus: [MenuItem] = [],
        history: [StepRecord] = []
    ) -> DesktopContext {
        DesktopContext(
            frontmostApplication: RunningApplicationInfo(
                bundleIdentifier: bundle, localizedName: app, processIdentifier: 800, isActive: true
            ),
            focusedWindow: WindowInfo(
                title: window, owningApplication: app,
                frame: CGRect(x: 0, y: 0, width: 800, height: 600), isFocused: true
            ),
            accessibility: AccessibilitySnapshot(bundleIdentifier: bundle, elements: elements, menuItems: menus),
            arrangement: .fixture()
        )
    }

    @Test("Eval: System Settings panes are reached through the View menu")
    func evalSettingsViewMenu() async throws {
        let desktop = appDesktop(
            app: "System Settings", bundle: "com.apple.systempreferences", window: "General",
            menus: [
                MenuItem(path: ["File", "Close"]), MenuItem(path: ["Edit", "Find"]),
                MenuItem(path: ["View", "Back"]), MenuItem(path: ["View", "Wi\u{2011}Fi"]),
                MenuItem(path: ["View", "Bluetooth"]), MenuItem(path: ["View", "General"]),
                MenuItem(path: ["View", "Appearance"]), MenuItem(path: ["View", "Sound"]),
                MenuItem(path: ["Window", "Minimize"]),
            ]
        )
        let step = try await plan("Go to the Appearance settings", desktop: desktop)
        #expect(step.action == .chooseMenuItem(path: ["View", "Appearance"]), "got \(step.action) — \(step.rationale)")
    }

    @Test("Eval: a Finder folder is created with File > New Folder")
    func evalFinderNewFolder() async throws {
        let desktop = appDesktop(
            app: "Finder", bundle: "com.apple.finder", window: "AbleKitEval",
            elements: [
                ElementReference(id: "e2", role: "AXButton", elementDescription: "Back",
                    frame: CGRect(x: 10, y: 10, width: 30, height: 20), actions: ["AXPress"]),
                ElementReference(id: "e3", role: "AXStaticText", value: "Recents",
                    frame: CGRect(x: 10, y: 60, width: 80, height: 20)),
                ElementReference(id: "e4", role: "AXStaticText", value: "Applications",
                    frame: CGRect(x: 10, y: 80, width: 80, height: 20)),
            ],
            menus: [
                MenuItem(path: ["File", "New Finder Window"]), MenuItem(path: ["File", "New Folder"]),
                MenuItem(path: ["File", "New Smart Folder"]), MenuItem(path: ["File", "Get Info"]),
                MenuItem(path: ["Edit", "Copy"]), MenuItem(path: ["View", "as Icons"]),
                MenuItem(path: ["Go", "Home"]),
            ]
        )
        let step = try await plan("In the Finder window that is open, create a new folder named Eval Folder", desktop: desktop)
        #expect(step.action == .chooseMenuItem(path: ["File", "New Folder"]), "got \(step.action) — \(step.rationale)")
    }

    @Test("Eval: naming the new folder types into the focused name field")
    func evalFinderNameFolder() async throws {
        let nameField = ElementReference(
            id: "e14", role: "AXTextField", value: "untitled folder",
            frame: CGRect(x: 200, y: 200, width: 120, height: 20), isFocused: true
        )
        let history = [StepRecord(
            index: 0, action: .chooseMenuItem(path: ["File", "New Folder"]), rationale: "",
            classification: .routine, capability: .accessibility, outcome: .succeeded
        )]
        let desktop = appDesktop(
            app: "Finder", bundle: "com.apple.finder", window: "AbleKitEval", elements: [nameField]
        )
        let goal = "In the Finder window that is open, create a new folder named Eval Folder"
        let step = try await provider.planNextStep(
            goal: goal,
            context: AgentContext(goal: goal, desktop: desktop, history: history, stepIndex: 1)
        )
        guard case .typeText(let text, _) = step.action else {
            Issue.record("expected typing the name, got \(step.action) — \(step.rationale)"); return
        }
        #expect(text.contains("Eval Folder"))
    }

    @Test("Eval: Calculator is operated by pressing its buttons, not by typing the answer")
    func evalCalculatorButtons() async throws {
        func button(_ id: String, _ title: String, x: Double) -> ElementReference {
            ElementReference(
                id: id, role: "AXButton", elementDescription: title,
                frame: CGRect(x: x, y: 300, width: 40, height: 40), actions: ["AXPress"]
            )
        }
        let elements = [
            ElementReference(id: "e2", role: "AXStaticText", value: "0", frame: CGRect(x: 0, y: 50, width: 200, height: 40)),
            button("e3", "All Clear", x: 0), button("e4", "1", x: 40), button("e5", "2", x: 80),
            button("e6", "7", x: 120), button("e7", "Multiply", x: 160), button("e8", "Equals", x: 200),
        ]
        let desktop = appDesktop(
            app: "Calculator", bundle: "com.apple.calculator", window: "Calculator", elements: elements,
            menus: [MenuItem(path: ["Edit", "Copy"]), MenuItem(path: ["Edit", "Paste"])]
        )
        let step = try await plan("Use Calculator to work out 12 times 7, then copy the result", desktop: desktop)
        let pressedDigitOrClear: Bool = {
            guard case .click(.element(let element)) = step.action else { return false }
            return ["e3", "e4"].contains(element.id)
        }()
        #expect(pressedDigitOrClear, "got \(step.action) — \(step.rationale)")
    }
}
