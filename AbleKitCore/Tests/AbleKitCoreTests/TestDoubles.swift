import CoreGraphics
import Foundation

@testable import AbleKitCore

/// A planner that returns a scripted sequence, so an agent run is fully deterministic.
final class ScriptedIntelligence: IntelligenceProvider, @unchecked Sendable {
    let name = "Scripted"
    var availability: IntelligenceAvailability { availabilityValue }

    var availabilityValue: IntelligenceAvailability = .available
    private var steps: [Result<PlannedStep, IntelligenceError>]
    /// Returned once the script runs out, so a loop that should have stopped does not hang.
    /// A closure rather than a value so a test can keep proposing *distinct* actions, which is
    /// what it takes to exercise a limit other than repeated-action detection.
    private let fallback: @Sendable (Int) -> PlannedStep
    var verification: VerificationResult?
    private(set) var planCallCount = 0
    private(set) var lastPrompts: [String] = []

    init(
        steps: [Result<PlannedStep, IntelligenceError>],
        fallback: @escaping @Sendable (Int) -> PlannedStep = { _ in
            PlannedStep(action: .complete(summary: "Out of script."), rationale: "")
        }
    ) {
        self.steps = steps
        self.fallback = fallback
    }

    /// A planner that never finishes, proposing a different action every time.
    static func neverFinishing() -> ScriptedIntelligence {
        ScriptedIntelligence(steps: []) { count in
            PlannedStep(action: .typeText("step-\(count)"), rationale: "stalling")
        }
    }

    /// A planner that proposes the very same action forever.
    static func repeating(_ action: DesktopAction) -> ScriptedIntelligence {
        ScriptedIntelligence(steps: []) { _ in PlannedStep(action: action, rationale: "again") }
    }

    convenience init(actions: [DesktopAction]) {
        self.init(steps: actions.map { .success(PlannedStep(action: $0, rationale: "because")) })
    }

    func planNextStep(goal: String, context: AgentContext) async throws -> PlannedStep {
        planCallCount += 1
        lastPrompts.append(goal)
        guard !steps.isEmpty else { return fallback(planCallCount) }
        return try steps.removeFirst().get()
    }

    func verify(action: DesktopAction, before: DesktopContext, after: DesktopContext) async throws
        -> VerificationResult
    {
        verification ?? .succeeded("scripted")
    }
}

/// A desktop that can be scripted, and that records what was asked of it.
final class ScriptedCollector: ContextCollecting, @unchecked Sendable {
    private let contexts: [DesktopContext]
    /// Whether each collection reports a slightly different screen.
    ///
    /// Real applications respond to being clicked, and `Verifier` treats an entirely unchanged
    /// screen as evidence that an action did nothing. A double that returned a frozen desktop
    /// would therefore make every step fail verification, so varying is the realistic default and
    /// a frozen screen is opted into by the test that is actually about being stuck.
    private let varying: Bool
    private var index = 0
    private(set) var requestedOptions: [ContextCollectionOptions] = []

    init(_ contexts: [DesktopContext], varying: Bool = true) {
        self.contexts = contexts.isEmpty ? [DesktopContext()] : contexts
        self.varying = varying
    }

    convenience init(repeating context: DesktopContext, varying: Bool = true) {
        self.init([context], varying: varying)
    }

    func collect(options: ContextCollectionOptions) async -> DesktopContext {
        requestedOptions.append(options)
        defer { index += 1 }
        // The last scripted context repeats, so a run may take more steps than were scripted.
        let context = contexts[min(index, contexts.count - 1)]
        guard varying else { return context }
        return context.withWindowTitle("\(context.focusedWindow?.title ?? "Window") \(index)")
    }
}

/// A capability that records what it was asked to do instead of doing it.
final class RecordingCapability: Capability, @unchecked Sendable {
    let kind: CapabilityKind
    private let handles: @Sendable (DesktopAction) -> Bool
    var result: Result<CapabilityOutcome, CapabilityError> = .success(.success)
    private(set) var executed: [DesktopAction] = []

    init(
        kind: CapabilityKind = .visual,
        handles: @escaping @Sendable (DesktopAction) -> Bool = { _ in true }
    ) {
        self.kind = kind
        self.handles = handles
    }

    func canHandle(_ action: DesktopAction) -> Bool { handles(action) }

    func execute(_ action: DesktopAction, context: DesktopContext?) async throws -> CapabilityOutcome {
        executed.append(action)
        return try result.get()
    }
}

/// A user who always answers the same way.
struct ScriptedUser: UserInteracting {
    var confirms: Bool = true
    var input: String?

    func confirm(_ prompt: UserPrompt) async -> Bool { confirms }
    func requestInput(_ prompt: UserPrompt) async -> String? { input }
}

// MARK: - Fixtures

extension DesktopContext {
    /// A desktop with one app, one window, and a couple of controls.
    static func fixture(
        app: String = "Tracker",
        bundleIdentifier: String = "com.example.tracker",
        windowTitle: String = "Q3",
        elements: [ElementReference] = [.fixture()],
        screenText: [RecognizedText] = []
    ) -> DesktopContext {
        DesktopContext(
            frontmostApplication: RunningApplicationInfo(
                bundleIdentifier: bundleIdentifier,
                localizedName: app,
                processIdentifier: 1234,
                isActive: true
            ),
            focusedWindow: WindowInfo(
                title: windowTitle,
                owningApplication: app,
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                isFocused: true
            ),
            accessibility: AccessibilitySnapshot(
                bundleIdentifier: bundleIdentifier, elements: elements
            ),
            screen: screenText.isEmpty
                ? nil
                : ScreenObservation(
                    image: nil,
                    geometry: CaptureGeometry(
                        region: CGRect(x: 0, y: 0, width: 1512, height: 982),
                        pixelSize: CGSize(width: 3024, height: 1964)
                    ),
                    textRegions: screenText
                ),
            arrangement: .fixture()
        )
    }
}

extension ScreenArrangement {
    static func fixture() -> ScreenArrangement {
        ScreenArrangement(displays: [
            DisplayGeometry(
                displayID: 1,
                bounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
                scaleFactor: 2,
                isPrimary: true
            )
        ])
    }
}

extension ElementReference {
    static func fixture(
        id: String = "e1",
        role: String = "AXButton",
        title: String? = "Save",
        enabled: Bool = true,
        focused: Bool = false,
        value: String? = nil,
        actions: [String] = ["AXPress"],
        frame: CGRect = CGRect(x: 100, y: 200, width: 60, height: 22)
    ) -> ElementReference {
        ElementReference(
            id: id, role: role, title: title, value: value, frame: frame,
            isEnabled: enabled, isFocused: focused, actions: actions
        )
    }
}


extension DesktopContext {
    /// A copy whose window title differs, which is enough to change the state fingerprint.
    func withWindowTitle(_ title: String) -> DesktopContext {
        DesktopContext(
            capturedAt: capturedAt,
            frontmostApplication: frontmostApplication,
            focusedWindow: focusedWindow.map {
                WindowInfo(
                    windowID: $0.windowID,
                    title: title,
                    owningApplication: $0.owningApplication,
                    owningBundleIdentifier: $0.owningBundleIdentifier,
                    frame: $0.frame,
                    isOnScreen: $0.isOnScreen,
                    isFocused: $0.isFocused
                )
            },
            visibleWindows: visibleWindows,
            selectedText: selectedText,
            clipboard: clipboard,
            finderSelection: finderSelection,
            accessibility: accessibility,
            screen: screen,
            arrangement: arrangement
        )
    }
}
