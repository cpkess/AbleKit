import CoreGraphics
import Testing

@testable import AbleKitCore

@Suite("Capability routing")
struct CapabilityRouterTests {

    private func router(_ kinds: [CapabilityKind]) -> CapabilityRouter {
        CapabilityRouter(capabilities: kinds.map { kind in
            RecordingCapability(kind: kind) { action in
                switch kind {
                case .accessibility:
                    if case .accessibilityAction = action { return true }
                    return false
                case .native:
                    switch action {
                    case .openApplication, .activateApplication, .nativeAction: return true
                    default: return false
                    }
                case .visual:
                    switch action {
                    case .click, .doubleClick, .rightClick, .movePointer, .scroll, .drag,
                        .typeText, .pressKey, .hotkey:
                        return true
                    default: return false
                    }
                case .bridge:
                    if case .askAIBridge = action { return true }
                    return false
                default:
                    return true
                }
            }
        })
    }

    @Test("A click on a pressable control becomes an Accessibility press")
    func upgradesClickToAccessibility() throws {
        let button = ElementReference.fixture(actions: ["AXPress"])
        let routed = try router([.accessibility, .visual]).route(.click(target: .element(button)))

        #expect(routed.decision.kind == .accessibility)
        #expect(routed.decision.action == .accessibilityAction(element: button, action: "AXPress"))
        #expect(routed.decision.refinement != nil)
    }

    @Test("A control with no press action is clicked at its position")
    func fallsBackToVisual() throws {
        let plain = ElementReference.fixture(role: "AXImage", title: "Chart", actions: [])
        let routed = try router([.accessibility, .visual]).route(.click(target: .element(plain)))

        #expect(routed.decision.kind == .visual)
        #expect(routed.decision.action == .click(target: .element(plain)))
    }

    @Test("A planned position is upgraded to the control that sits there")
    func upgradesPointToElement() throws {
        let button = ElementReference.fixture(
            frame: CGRect(x: 100, y: 100, width: 100, height: 40)
        )
        let context = DesktopContext.fixture(elements: [button])
        let routed = try router([.accessibility, .visual])
            .route(.click(target: .point(CGPoint(x: 150, y: 120))), context: context)

        #expect(routed.decision.kind == .accessibility)
        #expect(routed.decision.action == .accessibilityAction(element: button, action: "AXPress"))
    }

    @Test("The innermost control wins when they nest")
    func prefersSmallestContainingElement() throws {
        let window = ElementReference.fixture(
            id: "w", role: "AXWindow", title: "Main", actions: ["AXPress"],
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let button = ElementReference.fixture(
            id: "b", title: "Save", actions: ["AXPress"],
            frame: CGRect(x: 100, y: 100, width: 80, height: 30)
        )
        let context = DesktopContext.fixture(elements: [window, button])
        let routed = try router([.accessibility, .visual])
            .route(.click(target: .point(CGPoint(x: 120, y: 110))), context: context)

        #expect(routed.decision.action == .accessibilityAction(element: button, action: "AXPress"))
    }

    @Test("A position over nothing interactive stays a position")
    func leavesBarePointAlone() throws {
        let context = DesktopContext.fixture(elements: [])
        let routed = try router([.accessibility, .visual])
            .route(.click(target: .point(CGPoint(x: 700, y: 700))), context: context)

        #expect(routed.decision.kind == .visual)
        #expect(routed.decision.action == .click(target: .point(CGPoint(x: 700, y: 700))))
    }

    @Test("Without the Accessibility capability, a click still gets through visually")
    func degradesWhenAccessibilityMissing() throws {
        let button = ElementReference.fixture(actions: ["AXPress"])
        let routed = try router([.visual]).route(.click(target: .element(button)))

        #expect(routed.decision.kind == .visual)
        #expect(routed.decision.action == .click(target: .element(button)))
        #expect(routed.decision.refinement?.contains("Fell back") == true)
    }

    @Test("Launching an app goes to the native capability, never to the mouse")
    func prefersNative() throws {
        let routed = try router([.native, .accessibility, .visual])
            .route(.openApplication(ApplicationReference(name: "Safari")))

        #expect(routed.decision.kind == .native)
    }

    @Test("A right-click becomes a menu request when the control offers one")
    func upgradesRightClick() throws {
        let element = ElementReference.fixture(actions: ["AXShowMenu"])
        let routed = try router([.accessibility, .visual]).route(.rightClick(target: .element(element)))

        #expect(routed.decision.action == .accessibilityAction(element: element, action: "AXShowMenu"))
    }

    @Test("An action nothing can carry out is reported, not silently dropped")
    func failsWhenNothingHandles() {
        #expect(throws: CapabilityError.self) {
            try router([.native]).route(.typeText("hello"))
        }
    }

    @Test("Capability tiers are ordered most deterministic first")
    func preferenceOrdering() {
        #expect(CapabilityKind.native < .accessibility)
        #expect(CapabilityKind.accessibility < .visual)
        #expect(CapabilityKind.visual < .bridge)
    }
}

@Suite("Verification")
struct VerifierTests {

    private func context(app: String, bundle: String, window: String = "w") -> DesktopContext {
        .fixture(app: app, bundleIdentifier: bundle, windowTitle: window)
    }

    @Test("Activating an app is settled by looking at what is frontmost")
    func activationVerifiedDeterministically() throws {
        let before = context(app: "Finder", bundle: "com.apple.finder")
        let after = context(app: "Safari", bundle: "com.apple.Safari")
        let result = try #require(
            Verifier.deterministicVerdict(
                action: .activateApplication(ApplicationReference(bundleIdentifier: "com.apple.Safari")),
                before: before,
                after: after
            )
        )
        #expect(result.outcome == .succeeded)
    }

    @Test("The wrong app coming forward is a failure worth retrying")
    func activationFailure() throws {
        let before = context(app: "Finder", bundle: "com.apple.finder")
        let after = context(app: "Mail", bundle: "com.apple.mail")
        let result = try #require(
            Verifier.deterministicVerdict(
                action: .activateApplication(ApplicationReference(bundleIdentifier: "com.apple.Safari")),
                before: before,
                after: after
            )
        )
        #expect(result.outcome == .failed)
        #expect(result.shouldRetry)
    }

    @Test("An app named loosely still matches")
    func matchesByName() throws {
        let after = context(app: "System Settings", bundle: "com.apple.systempreferences")
        let result = try #require(
            Verifier.deterministicVerdict(
                action: .openApplication(ApplicationReference(name: "System Settings")),
                before: context(app: "Finder", bundle: "com.apple.finder"),
                after: after
            )
        )
        #expect(result.outcome == .succeeded)
    }

    @Test("A screen that did not change at all means the action did nothing")
    func unchangedScreenIsFailure() throws {
        let same = context(app: "Tracker", bundle: "com.example")
        let result = try #require(
            Verifier.deterministicVerdict(
                action: .click(target: .element(.fixture())), before: same, after: same
            )
        )
        #expect(result.outcome == .failed)
        #expect(result.shouldRetry)
    }

    @Test("Scrolling to the end of a view is not a failure")
    func unchangedScreenAfterScrollIsNotFailure() {
        let same = context(app: "Tracker", bundle: "com.example")
        let result = Verifier.deterministicVerdict(
            action: .scroll(target: .point(.zero), deltaX: 0, deltaY: -3),
            before: same,
            after: same
        )
        // No verdict: handed up the ladder rather than called a failure.
        #expect(result == nil)
    }

    @Test("Typing is confirmed when the text lands in the focused field")
    func typingVerifiedByFieldValue() throws {
        let field = ElementReference.fixture(
            id: "f", role: "AXTextField", title: "Status", focused: true, value: "Q3 is green", actions: []
        )
        let after = DesktopContext.fixture(elements: [field])
        let result = try #require(
            Verifier.deterministicVerdict(
                action: .typeText("Q3 is green"),
                before: DesktopContext.fixture(elements: []),
                after: after
            )
        )
        #expect(result.outcome == .succeeded)
    }

    @Test("A changed screen with no deterministic signature is left to the model")
    func ambiguousCaseDefersToModel() {
        let before = context(app: "Tracker", bundle: "com.example", window: "before")
        let after = context(app: "Tracker", bundle: "com.example", window: "after")
        #expect(
            Verifier.deterministicVerdict(
                action: .click(target: .element(.fixture())), before: before, after: after
            ) == nil
        )
    }

    @Test("A model that cannot answer yields inconclusive, never a false success")
    func failingModelIsInconclusive() async {
        struct Failing: IntelligenceProvider {
            let name = "failing"
            var availability: IntelligenceAvailability { .available }
            func planNextStep(goal: String, context: AgentContext) async throws -> PlannedStep {
                throw IntelligenceError.cancelled
            }
            func verify(action: DesktopAction, before: DesktopContext, after: DesktopContext)
                async throws -> VerificationResult
            {
                throw IntelligenceError.underlying("model exploded")
            }
        }
        let before = context(app: "Tracker", bundle: "com.example", window: "before")
        let after = context(app: "Tracker", bundle: "com.example", window: "after")
        let result = await Verifier(intelligence: Failing()).verify(
            action: .click(target: .element(.fixture())), before: before, after: after
        )
        #expect(result.outcome == .inconclusive)
    }
}
