import CoreGraphics
import Testing

@testable import AbleKitCore

private func element(
    id: String = "e1",
    role: String = "AXButton",
    title: String? = nil,
    enabled: Bool = true,
    focused: Bool = false,
    actions: [String] = ["AXPress"],
    frame: CGRect = CGRect(x: 10, y: 10, width: 80, height: 24)
) -> ElementReference {
    ElementReference(
        id: id, role: role, title: title, frame: frame,
        isEnabled: enabled, isFocused: focused, actions: actions
    )
}

@Suite("Sensitive action detection")
struct SensitiveActionDetectorTests {
    private let detector = SensitiveActionDetector()

    @Test("Ordinary navigation is routine")
    func routineActions() {
        #expect(detector.classify(.scroll(target: .point(.zero), deltaX: 0, deltaY: -3)).classification == .routine)
        #expect(detector.classify(.openApplication(ApplicationReference(name: "Safari"))).classification == .routine)
        #expect(detector.classify(.click(target: .element(element(title: "Next")))).classification == .routine)
    }

    @Test(
        "Buttons that act on the world need confirmation",
        arguments: ["Send", "Delete All", "Submit Order", "Publish", "Buy now", "Install Update"]
    )
    func consequentialLabels(label: String) {
        let result = detector.classify(.click(target: .element(element(title: label))))
        #expect(result.classification == .consequential)
        #expect(result.reason != nil)
    }

    @Test(
        "Words that merely contain a keyword are not treated as consequential",
        arguments: ["Resend later", "Undeleted items", "Sender", "Postcode"]
    )
    func wholeWordMatchingOnly(label: String) {
        #expect(detector.classify(.click(target: .element(element(title: label)))).classification == .routine)
    }

    @Test("Credential and payment surfaces are restricted")
    func restrictedLabels() {
        #expect(
            detector.classify(.click(target: .element(element(title: "Sign in")))).classification
                == .restricted
        )
        #expect(
            detector.classify(.click(target: .element(element(title: "Card number")))).classification
                == .restricted
        )
    }

    @Test("Typing into a secure field is restricted")
    func secureFieldTyping() {
        let secure = element(id: "pw", role: "AXSecureTextField", focused: true, actions: [])
        let context = DesktopContext(
            accessibility: AccessibilitySnapshot(bundleIdentifier: "com.example", elements: [secure])
        )
        let result = detector.classify(.typeText("hunter2"), context: context)
        #expect(result.classification == .restricted)
    }

    @Test("Typing ordinary text into an ordinary field is routine")
    func ordinaryTyping() {
        let field = element(id: "t", role: "AXTextField", focused: true, actions: [])
        let context = DesktopContext(
            accessibility: AccessibilitySnapshot(bundleIdentifier: "com.example", elements: [field])
        )
        #expect(detector.classify(.typeText("Q3 status is green"), context: context).classification == .routine)
    }

    @Test("Return is consequential only while a dialog is up")
    func returnInDialog() {
        #expect(detector.classify(.pressKey(.returnKey)).classification == .routine)
        let sheet = element(id: "s", role: "AXSheet", actions: [])
        let context = DesktopContext(
            accessibility: AccessibilitySnapshot(bundleIdentifier: "com.example", elements: [sheet])
        )
        #expect(detector.classify(.pressKey(.returnKey), context: context).classification == .consequential)
    }

    @Test("Quitting an application is consequential")
    func quitHotkey() {
        let action = DesktopAction.hotkey(key: .character("q"), modifiers: [.command])
        #expect(detector.classify(action).classification == .consequential)
    }

    @Test("Handing information to another AI is always surfaced")
    func bridgeHandoffIsConsequential() {
        let action = DesktopAction.askAIBridge(bridge: .copilot, prompt: "summarise this")
        #expect(detector.classify(action).classification == .consequential)
    }

    @Test("Web links are routine, other schemes are not")
    func urlSchemes() {
        #expect(detector.classify(.nativeAction(.openURL("https://example.com"))).classification == .routine)
        #expect(detector.classify(.nativeAction(.openURL("ssh://host"))).classification == .consequential)
    }

    @Test("A bare coordinate carries no label to judge")
    func unlabelledPoint() {
        #expect(detector.classify(.click(target: .point(CGPoint(x: 5, y: 5)))).classification == .routine)
    }
}

@Suite("Action policy")
struct ActionPolicyTests {

    @Test("Routine actions are allowed outright")
    func allowsRoutine() {
        let policy = ActionPolicy()
        #expect(policy.evaluate(.wait(seconds: 1)) == .allow)
    }

    @Test("Consequential actions ask first, and say why")
    func confirmsConsequential() {
        let policy = ActionPolicy()
        let decision = policy.evaluate(.click(target: .element(element(title: "Send"))))
        guard case .confirm(let reason) = decision else {
            Issue.record("expected a confirmation, got \(decision)")
            return
        }
        #expect(reason.contains("Send"))
    }

    @Test("Turning confirmation off does not unlock restricted actions")
    func restrictedIgnoresSetting() {
        let policy = ActionPolicy(confirmsConsequentialActions: false)
        // The setting downgrades consequential actions...
        #expect(policy.evaluate(.click(target: .element(element(title: "Send")))) == .allow)
        // ...but restricted ones are still refused.
        let decision = policy.evaluate(.click(target: .element(element(title: "Sign in"))))
        guard case .block = decision else {
            Issue.record("expected a block, got \(decision)")
            return
        }
    }
}

@Suite("Action validation")
struct ActionValidatorTests {
    private let validator = ActionValidator(
        arrangement: ScreenArrangement(displays: [
            DisplayGeometry(
                displayID: 1,
                bounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
                scaleFactor: 2,
                isPrimary: true
            )
        ])
    )

    @Test("A point on screen validates")
    func validPoint() throws {
        try validator.validate(.click(target: .point(CGPoint(x: 100, y: 100))))
    }

    @Test("A point off every display is rejected")
    func offScreenPoint() {
        #expect(throws: ActionValidationError.pointOffScreen(CGPoint(x: 9000, y: 9000))) {
            try validator.validate(.click(target: .point(CGPoint(x: 9000, y: 9000))))
        }
    }

    @Test("A disabled element is rejected before it is clicked")
    func disabledElement() {
        let disabled = element(title: "Save", enabled: false)
        #expect(throws: ActionValidationError.elementDisabled(disabled.description)) {
            try validator.validate(.click(target: .element(disabled)))
        }
    }

    @Test("An element with no area is rejected")
    func zeroSizeElement() {
        let collapsed = element(title: "Save", frame: CGRect(x: 10, y: 10, width: 0, height: 0))
        #expect(throws: ActionValidationError.elementHasNoArea(collapsed.description)) {
            try validator.validate(.click(target: .element(collapsed)))
        }
    }

    @Test("An unsupported Accessibility action is rejected")
    func unsupportedAXAction() {
        let button = element(title: "Save", actions: ["AXPress"])
        #expect(throws: ActionValidationError.self) {
            try validator.validate(.accessibilityAction(element: button, action: "AXIncrement"))
        }
    }

    @Test("Empty payloads are rejected")
    func emptyPayloads() {
        #expect(throws: ActionValidationError.self) { try validator.validate(.typeText("")) }
        #expect(throws: ActionValidationError.self) {
            try validator.validate(.askAIBridge(bridge: .copilot, prompt: "   "))
        }
    }

    @Test("An implausibly long wait is rejected rather than obeyed")
    func longWait() {
        #expect(throws: ActionValidationError.waitTooLong(600)) {
            try validator.validate(.wait(seconds: 600))
        }
        #expect(throws: Never.self) { try validator.validate(.wait(seconds: 2)) }
    }

    @Test("An application must be identified somehow")
    func unidentifiedApplication() {
        #expect(throws: ActionValidationError.applicationNotIdentified) {
            try validator.validate(.openApplication(ApplicationReference()))
        }
    }
}
