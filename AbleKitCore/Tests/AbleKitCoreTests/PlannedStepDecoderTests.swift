import CoreGraphics
import Testing

@testable import AbleKitCore

private let saveButton = ElementReference(
    id: "e7", role: "AXButton", title: "Save",
    frame: CGRect(x: 100, y: 200, width: 60, height: 22), actions: ["AXPress"]
)
private let nameField = ElementReference(
    id: "e8", role: "AXTextField", title: "Name",
    frame: CGRect(x: 100, y: 100, width: 200, height: 22)
)

private let context = DesktopContext(
    focusedWindow: WindowInfo(title: "Tracker", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
    accessibility: AccessibilitySnapshot(
        bundleIdentifier: "com.example.tracker",
        elements: [saveButton, nameField]
    ),
    arrangement: ScreenArrangement(displays: [
        DisplayGeometry(
            displayID: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
            scaleFactor: 2, isPrimary: true
        )
    ])
)

@Suite("Decoding a planned step")
struct PlannedStepDecoderTests {
    private let decoder = PlannedStepDecoder()

    @Test("An element id becomes an element-targeted action")
    func resolvesElementID() throws {
        let draft = PlannedStepDraft(kind: .clickElement, rationale: "Save the record", elementID: "e7")
        let step = try decoder.decode(draft, context: context)
        #expect(step.action == .click(target: .element(saveButton)))
        #expect(step.rationale == "Save the record")
    }

    @Test("Ids wrapped in brackets, as they appear in the prompt, are accepted")
    func acceptsBracketedID() throws {
        let draft = PlannedStepDraft(kind: .clickElement, rationale: "Save", elementID: "[e7]")
        let step = try decoder.decode(draft, context: context)
        #expect(step.action == .click(target: .element(saveButton)))
    }

    @Test("A label used in place of an id still resolves")
    func fallsBackToLabelMatching() throws {
        let draft = PlannedStepDraft(kind: .clickElement, rationale: "Save", elementID: "Save")
        let step = try decoder.decode(draft, context: context)
        #expect(step.action == .click(target: .element(saveButton)))
    }

    @Test("An id that no longer exists is reported in terms the planner can act on")
    func rejectsUnknownElement() {
        let draft = PlannedStepDraft(kind: .clickElement, rationale: "Save", elementID: "e99")
        #expect(throws: IntelligenceError.self) {
            try decoder.decode(draft, context: context)
        }
    }

    @Test("A step that needs a payload is rejected without one")
    func rejectsMissingPayload() {
        #expect(throws: IntelligenceError.self) {
            try decoder.decode(PlannedStepDraft(kind: .typeText, rationale: "type"), context: context)
        }
        #expect(throws: IntelligenceError.self) {
            try decoder.decode(
                PlannedStepDraft(kind: .openApplication, rationale: "open"), context: context)
        }
        #expect(throws: IntelligenceError.self) {
            try decoder.decode(PlannedStepDraft(kind: .askCopilot, rationale: "ask"), context: context)
        }
    }

    @Test("A hotkey becomes a key plus modifiers")
    func decodesHotkey() throws {
        let draft = PlannedStepDraft(
            kind: .hotkey, rationale: "Save", keyName: "s", modifiers: [.command]
        )
        let step = try decoder.decode(draft, context: context)
        #expect(step.action == .hotkey(key: .character("s"), modifiers: [.command]))
    }

    @Test("A hotkey with no modifiers degrades to a plain keypress rather than failing")
    func hotkeyWithoutModifiers() throws {
        let draft = PlannedStepDraft(kind: .hotkey, rationale: "Confirm", keyName: "return")
        let step = try decoder.decode(draft, context: context)
        #expect(step.action == .pressKey(.returnKey))
    }

    @Test(
        "Key names are read the way a person writes them",
        arguments: [
            ("return", Key.returnKey), ("Escape", .escape), ("esc", .escape),
            ("arrow down", .arrowDown), ("Page Up", .pageUp), ("f5", .function(5)),
            ("TAB", .tab), ("back space", .delete),
        ]
    )
    func parsesKeyNames(name: String, expected: Key) throws {
        #expect(try PlannedStepDecoder.parseKey(name) == expected)
    }

    @Test("A key name that means nothing is rejected")
    func rejectsUnknownKey() {
        #expect(throws: IntelligenceError.self) { try PlannedStepDecoder.parseKey("wibble") }
    }

    @Test("A scroll with no element aims at the focused window")
    func scrollDefaultsToWindow() throws {
        let draft = PlannedStepDraft(kind: .scroll, rationale: "See more", scrollAmount: -5)
        let step = try decoder.decode(draft, context: context)
        #expect(step.action == .scroll(target: .point(CGPoint(x: 400, y: 300)), deltaX: 0, deltaY: -5))
    }

    @Test("A scroll of zero is rejected as a wasted step")
    func rejectsZeroScroll() {
        let draft = PlannedStepDraft(kind: .scroll, rationale: "nothing", scrollAmount: 0)
        #expect(throws: IntelligenceError.self) { try decoder.decode(draft, context: context) }
    }

    @Test("An over-long wait is clamped rather than failing the step")
    func clampsWait() throws {
        let draft = PlannedStepDraft(kind: .wait, rationale: "Let it load", waitSeconds: 600)
        let step = try decoder.decode(draft, context: context)
        #expect(step.action == .wait(seconds: 10))
    }

    @Test("A bare host name is given a scheme")
    func normalizesURL() {
        #expect(PlannedStepDecoder.normalizeURL("example.com") == "https://example.com")
        #expect(PlannedStepDecoder.normalizeURL("https://example.com") == "https://example.com")
    }

    @Test("Completing without a summary still produces something to show the user")
    func completeWithoutSummary() throws {
        let draft = PlannedStepDraft(kind: .complete, rationale: "done")
        let step = try decoder.decode(draft, context: context)
        #expect(step.action == .complete(summary: "Done."))
    }

    @Test("Confidence is clamped into range")
    func clampsConfidence() throws {
        let draft = PlannedStepDraft(kind: .wait, rationale: "wait", waitSeconds: 1, confidence: 5)
        #expect(try decoder.decode(draft, context: context).confidence == 1)
    }

    @Test("An app with no readable controls says so, instead of blaming the id")
    func noAccessibilityTree() {
        let bare = DesktopContext()
        let draft = PlannedStepDraft(kind: .clickElement, rationale: "click", elementID: "e7")
        #expect(throws: IntelligenceError.self) { try decoder.decode(draft, context: bare) }
    }
}
