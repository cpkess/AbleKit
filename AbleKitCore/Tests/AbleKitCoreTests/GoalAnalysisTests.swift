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
        #expect(GoalAnalysis(goal: "Open Calculator", context: context()).promptSection == nil)
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
}
