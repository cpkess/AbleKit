import CoreGraphics
import Foundation
import Testing

@testable import AbleKitCore

@Suite("Reading the goal")
struct GoalAnalysisTests {

    private func context(
        elements: [ElementReference] = [], menus: [MenuItem] = [], text: [RecognizedText] = []
    ) -> DesktopContext {
        DesktopContext(
            accessibility: AccessibilitySnapshot(bundleIdentifier: nil, elements: elements, menuItems: menus),
            screen: text.isEmpty ? nil : ScreenObservation(
                image: nil,
                geometry: CaptureGeometry(region: CGRect(x: 0, y: 0, width: 800, height: 600), pixelSize: CGSize(width: 800, height: 600)),
                textRegions: text
            )
        )
    }

    @Test("A menu command named in the goal is found, preferring the most specific")
    func findsMenuCommand() {
        let analysis = GoalAnalysis(
            goal: "In the Finder window that is open, create a new folder named Eval Folder",
            context: context(menus: [
                MenuItem(path: ["File", "New Finder Window"]),
                MenuItem(path: ["File", "New Folder"]),
                MenuItem(path: ["File", "New"]),
            ])
        )
        #expect(analysis.mentions.map(\.reference) == ["File > New Folder"])
    }

    @Test("Screen text named in the goal is found by its id")
    func findsScreenText() {
        let analysis = GoalAnalysis(
            goal: "Click Get Started",
            context: context(
                menus: [MenuItem(path: ["File", "New"])],
                text: [
                    RecognizedText(string: "Welcome", confidence: 1, frame: CGRect(x: 0, y: 0, width: 50, height: 10)),
                    RecognizedText(string: "Get Started", confidence: 1, frame: CGRect(x: 0, y: 40, width: 50, height: 10)),
                ]
            )
        )
        #expect(analysis.mentions.map(\.reference) == ["t2"])
    }

    @Test("A control is matched as a whole phrase, not inside another word")
    func wholePhraseOnly() {
        let save = ElementReference(id: "e1", role: "AXButton", title: "Save", frame: CGRect(x: 0, y: 0, width: 10, height: 10), actions: ["AXPress"])
        #expect(GoalAnalysis(goal: "Save the file", context: context(elements: [save])).mentions.count == 1)
        #expect(GoalAnalysis(goal: "Show the saved files", context: context(elements: [save])).mentions.isEmpty)
    }

    @Test("Short labels are not treated as evidence")
    func ignoresShortLabels() {
        let ok = ElementReference(id: "e1", role: "AXButton", title: "OK", frame: CGRect(x: 0, y: 0, width: 10, height: 10), actions: ["AXPress"])
        #expect(GoalAnalysis(goal: "Click OK", context: context(elements: [ok])).mentions.isEmpty)
    }

    @Test(
        "Text meant to be typed is extracted exactly",
        arguments: [
            ("create a new folder named Eval Folder", ["Eval Folder"]),
            ("type AbleKit was here, then select all the text and copy it", ["AbleKit was here"]),
            ("type Bold move, select all of it", ["Bold move"]),
            ("Rename it to \"Q3 Review\" and save", ["Q3 Review"]),
            ("Write \u{201C}Hello, world\u{201D} in the note", ["Hello, world"]),
            ("Open System Settings", []),
            ("Add a reminder called Buy milk and then close it", ["Buy milk"]),
        ]
    )
    func extractsLiteralText(goal: String, expected: [String]) {
        #expect(GoalAnalysis.literalTexts(in: goal) == expected)
    }

    @Test("The hints appear in the planning prompt")
    func promptIncludesHints() {
        let prompt = PromptBuilder().planningPrompt(
            goal: "create a new folder named Eval Folder",
            context: AgentContext(
                goal: "create a new folder named Eval Folder",
                desktop: context(menus: [MenuItem(path: ["File", "New Folder"])])
            )
        )
        #expect(prompt.contains("NAMED IN THE GOAL"))
        #expect(prompt.contains("File > New Folder menu command"))
        #expect(prompt.contains("EXACT TEXT FROM THE GOAL"))
        #expect(prompt.contains("\u{201C}Eval Folder\u{201D}"))
    }

    @Test("A goal that names nothing adds nothing")
    func noHints() {
        #expect(GoalAnalysis(goal: "Scroll down a bit", context: context(), applications: ["Calculator"]).promptSection == nil)
    }

    private func frontmost(_ name: String) -> DesktopContext {
        DesktopContext(
            frontmostApplication: RunningApplicationInfo(
                bundleIdentifier: nil, localizedName: name, processIdentifier: 1, isActive: true
            )
        )
    }

    @Test("An app named in the goal but not in front is flagged")
    func appNotOpen() throws {
        let analysis = GoalAnalysis(
            goal: "Open System Settings and go to the Appearance settings",
            context: frontmost("TextEdit"),
            applications: ["System Settings", "TextEdit", "Notes"]
        )
        #expect(analysis.applicationToOpen == "System Settings")
        let section = try #require(analysis.promptSection)
        #expect(section.contains("NOT OPEN YET"))
        #expect(section.contains("TextEdit's"))
    }

    @Test("The app already in front is not flagged")
    func appAlreadyOpen() {
        let analysis = GoalAnalysis(
            goal: "In System Settings, go to Appearance",
            context: frontmost("System Settings"),
            applications: ["System Settings"]
        )
        #expect(analysis.applicationToOpen == nil)
    }

    @Test(
        "App names used as ordinary words are not taken as apps",
        arguments: [
            "Type hello into the notes field",
            "Open the keyboard shortcuts panel",
            "Show a preview of the file",
            "Rename the file to Notes Backup",
        ]
    )
    func ordinaryWords(goal: String) {
        let analysis = GoalAnalysis(
            goal: goal, context: frontmost("Finder"), applications: ["Notes", "Shortcuts", "Preview"]
        )
        #expect(analysis.applicationToOpen == nil)
    }

    @Test(
        "App names used as apps are recognised",
        arguments: [
            ("Add a note in Notes saying hello", "Notes"),
            ("Open Preview", "Preview"),
            ("Use Calculator to add 2 and 2", "Calculator"),
            ("Calculator: work out 2 plus 2", "Calculator"),
        ]
    )
    func appWords(goal: String, app: String) {
        let analysis = GoalAnalysis(
            goal: goal, context: frontmost("Finder"), applications: ["Notes", "Preview", "Calculator"]
        )
        #expect(analysis.applicationToOpen == app)
    }

    @Test(
        "Typed text is corrected only toward what the goal says",
        arguments: [
            ("eval", ["Eval Folder"], "Eval Folder"),
            ("typeText", ["Eval Folder"], "Eval Folder"),
            ("text", ["AbleKit was here"], "AbleKit was here"),
            ("Eval Folder", ["Eval Folder"], "Eval Folder"),
            ("I'll be late", [], "I'll be late"),
            ("something else entirely", ["Eval Folder"], "something else entirely"),
        ]
    )
    func reconcilesTypedText(typed: String, literals: [String], expected: String) throws {
        #expect(try PlannedStepDecoder.reconcileTypedText(typed, literals: literals) == expected)
    }

    @Test("A placeholder with nothing to fall back on is refused")
    func placeholderWithoutFallback() {
        #expect(throws: IntelligenceError.self) {
            try PlannedStepDecoder.reconcileTypedText("typeText", literals: [])
        }
        #expect(throws: IntelligenceError.self) {
            try PlannedStepDecoder.reconcileTypedText("text", literals: ["one", "two"])
        }
    }

    @Test("Clicking the field that already has the cursor becomes typing the goal's text")
    func clickOnFocusedFieldBecomesTyping() throws {
        let field = ElementReference(
            id: "e14", role: "AXTextField", value: "untitled folder",
            frame: CGRect(x: 0, y: 0, width: 100, height: 20), isFocused: true
        )
        let desktop = DesktopContext(accessibility: AccessibilitySnapshot(bundleIdentifier: nil, elements: [field]))
        let draft = PlannedStepDraft(kind: .clickElement, subject: "e14", rationale: "rename")
        let step = try PlannedStepDecoder().decode(draft, context: desktop, goal: "create a new folder named Eval Folder")
        #expect(step.action == .typeText("Eval Folder", into: field))

        #expect(throws: IntelligenceError.self) {
            try PlannedStepDecoder().decode(draft, context: desktop, goal: "rename the folder")
        }
    }
}

@Suite("Evidence for finishing")
struct GoalEvidenceTests {

    private func context(elements: [ElementReference] = [], clipboard: String? = nil) -> DesktopContext {
        DesktopContext(
            clipboard: clipboard.map { ClipboardSnapshot(text: $0) },
            accessibility: AccessibilitySnapshot(bundleIdentifier: nil, elements: elements)
        )
    }

    private func text(_ value: String) -> ElementReference {
        ElementReference(id: "e1", role: "AXStaticText", value: value, frame: CGRect(x: 0, y: 0, width: 100, height: 20))
    }

    @Test("A name the goal asked for, still missing from the screen, contradicts completion")
    func missingName() {
        let goal = "create a new folder named Eval Folder"
        #expect(GoalEvidence.contradiction(ofCompletedGoal: goal, in: context(elements: [text("untitled folder")])) != nil)
        #expect(GoalEvidence.contradiction(ofCompletedGoal: goal, in: context(elements: [text("Eval Folder")])) == nil)
    }

    @Test("Text that ended up on the clipboard counts as evidence")
    func clipboardCounts() {
        let goal = "type AbleKit was here, then select all the text and copy it"
        #expect(GoalEvidence.contradiction(ofCompletedGoal: goal, in: context(clipboard: "AbleKit was here")) == nil)
    }

    @Test("A goal that asks for a copy is not done with an empty clipboard")
    func emptyClipboard() {
        let goal = "Use Calculator to work out 12 times 7, then copy the result"
        #expect(GoalEvidence.contradiction(ofCompletedGoal: goal, in: context()) != nil)
        #expect(GoalEvidence.contradiction(ofCompletedGoal: goal, in: context(clipboard: "84")) == nil)
    }

    @Test("A goal with nothing observable to check is left to judgement")
    func nothingToCheck() {
        #expect(GoalEvidence.contradiction(ofCompletedGoal: "In Dictionary, look up the word haptic", in: context()) == nil)
        #expect(GoalEvidence.contradiction(ofCompletedGoal: "Open System Settings", in: context()) == nil)
    }
}
