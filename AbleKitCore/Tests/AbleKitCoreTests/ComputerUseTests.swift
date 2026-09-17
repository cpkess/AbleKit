import CoreGraphics
import Foundation
import Testing

@testable import AbleKitCore

private let textEditMenus: [MenuItem] = [
    MenuItem(path: ["File", "New"], shortcut: "\u{2318}N"),
    MenuItem(path: ["File", "Open\u{2026}"]),
    MenuItem(path: ["File", "Save\u{2026}"]),
    MenuItem(path: ["File", "Export as PDF\u{2026}"]),
    MenuItem(path: ["Edit", "Undo"], isEnabled: false),
    MenuItem(path: ["Edit", "Select All"]),
    MenuItem(path: ["Format", "Font", "Bold"]),
    MenuItem(path: ["Format", "Font", "Italic"]),
    MenuItem(path: ["Format", "Make Plain Text"]),
    MenuItem(path: ["Window", "Minimize"]),
]

private func desktop(
    elements: [ElementReference] = [],
    menus: [MenuItem] = textEditMenus,
    screenText: [RecognizedText] = []
) -> DesktopContext {
    DesktopContext.fixture(
        app: "TextEdit",
        bundleIdentifier: "com.apple.TextEdit",
        elements: elements,
        screenText: screenText
    )
    .replacingAccessibility(
        AccessibilitySnapshot(
            bundleIdentifier: "com.apple.TextEdit", elements: elements, menuItems: menus
        )
    )
}

extension DesktopContext {
    fileprivate func replacingAccessibility(_ snapshot: AccessibilitySnapshot) -> DesktopContext {
        DesktopContext(
            capturedAt: capturedAt, frontmostApplication: frontmostApplication,
            focusedWindow: focusedWindow, visibleWindows: visibleWindows,
            selectedText: selectedText, clipboard: clipboard, finderSelection: finderSelection,
            accessibility: snapshot, screen: screen, arrangement: arrangement
        )
    }
}

@Suite("Menu commands")
struct MenuCommandTests {
    private let decoder = PlannedStepDecoder()

    @Test("A menu path is read however a person writes it", arguments: [
        "File > New", "File › New", "File -> New", "File / New", " File>New ",
    ])
    func parsesSeparators(raw: String) {
        #expect(PlannedStepDecoder.parseMenuPath(raw) == ["File", "New"])
    }

    @Test("A command is found despite a missing ellipsis or different case")
    func lenientMatching() {
        let snapshot = AccessibilitySnapshot(bundleIdentifier: nil, elements: [], menuItems: textEditMenus)
        #expect(snapshot.menuItem(matching: ["file", "save as"]) == nil)
        #expect(snapshot.menuItem(matching: ["File", "Save"])?.path == ["File", "Save\u{2026}"])
        #expect(snapshot.menuItem(matching: ["FILE", "export as pdf..."])?.path == ["File", "Export as PDF\u{2026}"])
    }

    @Test("A submenu may be skipped when the command is unambiguous")
    func skippedSubmenu() {
        let snapshot = AccessibilitySnapshot(bundleIdentifier: nil, elements: [], menuItems: textEditMenus)
        #expect(snapshot.menuItem(matching: ["Format", "Bold"])?.path == ["Format", "Font", "Bold"])
        #expect(snapshot.menuItem(matching: ["Minimize"])?.path == ["Window", "Minimize"])
    }

    @Test("An ambiguous bare title is refused rather than guessed")
    func ambiguousTitle() {
        let menus = textEditMenus + [MenuItem(path: ["Window", "New"])]
        let snapshot = AccessibilitySnapshot(bundleIdentifier: nil, elements: [], menuItems: menus)
        #expect(snapshot.menuItem(matching: ["New"]) == nil)
    }

    @Test("A planned menu command becomes the app's exact titles")
    func decodesMenuCommand() throws {
        let draft = PlannedStepDraft(kind: .chooseMenuItem, subject: "File > New", rationale: "New document")
        let step = try decoder.decode(draft, context: desktop())
        #expect(step.action == .chooseMenuItem(path: ["File", "New"]))
    }

    @Test("A menu path with an arrow instead of a chevron is still understood")
    func menuPathWithArrow() throws {
        let draft = PlannedStepDraft(kind: .chooseMenuItem, subject: "Format -> Font -> Bold", rationale: "Bold")
        #expect(try decoder.decode(draft, context: desktop()).action == .chooseMenuItem(path: ["Format", "Font", "Bold"]))
    }

    @Test("A command the app does not have is refused with a hint")
    func unknownCommand() {
        let draft = PlannedStepDraft(kind: .chooseMenuItem, subject: "File > Teleport", rationale: "x")
        #expect(throws: IntelligenceError.self) { try decoder.decode(draft, context: desktop()) }
    }

    @Test("A greyed-out command is refused before it is tried")
    func disabledCommand() {
        let draft = PlannedStepDraft(kind: .chooseMenuItem, subject: "Edit > Undo", rationale: "undo")
        #expect(throws: IntelligenceError.undecodableStep("\u{201C}Edit > Undo\u{201D} is greyed out right now.")) {
            try decoder.decode(draft, context: desktop())
        }
    }

    @Test("Menus are listed for the planner, without greyed-out commands")
    func promptListsMenus() {
        let prompt = PromptBuilder().planningPrompt(goal: "g", context: AgentContext(goal: "g", desktop: desktop()))
        #expect(prompt.contains("MENUS"))
        #expect(prompt.contains("File: New, Open\u{2026}, Save\u{2026}, Export as PDF\u{2026}"))
        #expect(prompt.contains("Format: Font > Bold, Font > Italic, Make Plain Text"))
        #expect(!prompt.contains("Undo"))
    }

    @Test("A long menu bar is cut to the budget")
    func menuBudget() {
        let many = (0..<400).map { MenuItem(path: ["Menu\($0 / 10)", "Command number \($0)"]) }
        let builder = PromptBuilder(budget: .init(maximumMenuCharacters: 300))
        let prompt = builder.planningPrompt(goal: "g", context: AgentContext(goal: "g", desktop: desktop(menus: many)))
        let section = prompt.components(separatedBy: "MENUS").last ?? ""
        #expect(section.contains("more menus not listed"))
        #expect(section.count < 600)
    }

    @Test("Menu commands are judged by their titles", arguments: [
        (["File", "New"], ActionClassification.routine),
        (["Edit", "Delete"], .consequential),
        (["TextEdit", "Quit TextEdit"], .consequential),
        (["Finder", "Empty Trash\u{2026}"], .consequential),
        (["Format", "Font", "Bold"], .routine),
    ])
    func menuSafety(path: [String], expected: ActionClassification) {
        #expect(SensitiveActionDetector().classify(.chooseMenuItem(path: path)).classification == expected)
    }

    @Test("Choosing a menu command goes through Accessibility")
    func routesToAccessibility() throws {
        let router = CapabilityRouter(capabilities: [
            RecordingCapability(kind: .accessibility) { if case .chooseMenuItem = $0 { true } else { false } },
            RecordingCapability(kind: .visual),
        ])
        #expect(try router.route(.chooseMenuItem(path: ["File", "New"])).decision.kind == .accessibility)
    }
}

@Suite("Screen text targets")
struct ScreenTextTargetTests {
    private let decoder = PlannedStepDecoder()
    private let text = [
        RecognizedText(string: "Cancel", confidence: 0.9, frame: CGRect(x: 300, y: 500, width: 60, height: 20)),
        RecognizedText(string: "Title", confidence: 0.9, frame: CGRect(x: 100, y: 100, width: 80, height: 30)),
        RecognizedText(string: "Continue", confidence: 0.9, frame: CGRect(x: 400, y: 502, width: 80, height: 20)),
    ]

    @Test("Screen text is numbered in reading order, shared by prompt and decoder")
    func readingOrder() throws {
        let screen = try #require(desktop(screenText: text).screen)
        #expect(screen.labeledTextRegions.map(\.text.string) == ["Title", "Cancel", "Continue"])
        #expect(screen.textRegion(withID: "t3")?.string == "Continue")
    }

    @Test("The planner sees each piece of text with an id and a position")
    func promptListsTextWithPositions() {
        let prompt = PromptBuilder().planningPrompt(
            goal: "g", context: AgentContext(goal: "g", desktop: desktop(screenText: text))
        )
        #expect(prompt.contains("[t1] \u{201C}Title\u{201D} at (140, 115)"))
        #expect(prompt.contains("[t3] \u{201C}Continue\u{201D} at (440, 512)"))
    }

    @Test("Clicking a text id clicks where that text is")
    func clickTextID() throws {
        let draft = PlannedStepDraft(kind: .clickElement, subject: "t3", rationale: "go")
        let step = try decoder.decode(draft, context: desktop(screenText: text))
        #expect(step.action == .click(target: .point(CGPoint(x: 440, y: 512))))
    }

    @Test("A text id that is not on screen is refused")
    func unknownTextID() {
        let draft = PlannedStepDraft(kind: .clickElement, subject: "t9", rationale: "go")
        #expect(throws: IntelligenceError.self) { try decoder.decode(draft, context: desktop(screenText: text)) }
    }
}

@Suite("Reading the screen on request")
@MainActor
struct ReadScreenTests {

    @Test("readScreen makes the next look include the screen, and only the next")
    func readScreenEscalatesOnce() async {
        let collector = ScriptedCollector(repeating: .fixture())
        let intelligence = ScriptedIntelligence(actions: [
            .readScreen,
            .click(target: .element(.fixture())),
            .complete(summary: "done"),
        ])
        let router = CapabilityRouter(capabilities: [RecordingCapability()])
        let session = AgentSession(
            goal: "g",
            collector: collector,
            intelligence: intelligence,
            executor: Executor(router: router, policy: ActionPolicy()),
            verifier: Verifier(intelligence: intelligence),
            limits: TaskLimits(actionDelay: 0)
        )

        await session.run()

        #expect(session.phase == .completed)
        let planningLooks = collector.requestedOptions.filter { $0 != .lightweight }
        // Look 1: semantic. readScreen. Look 2: full. click, verify. Look 3: semantic again.
        #expect(planningLooks == [.semantic, .full, .semantic])
        #expect(session.history.first?.action == .readScreen)
    }
}

@Suite("Element identifiers")
struct ElementIdentifierTests {

    @Test("A tree path round-trips")
    func treePathRoundTrip() {
        #expect(AccessibilityService.treePath(for: [0, 12, 3]) == "0-12-3")
        #expect(AccessibilityService.path(fromTreePath: "0-12-3") == [0, 12, 3])
        #expect(AccessibilityService.path(fromTreePath: "") == [])
        #expect(AccessibilityService.path(fromTreePath: "0-x") == nil)
    }
}

@Suite("Typing into fields")
struct TypingTests {
    private let decoder = PlannedStepDecoder()
    private let name = ElementReference(
        id: "e2", role: "AXTextField", title: "Name", frame: CGRect(x: 10, y: 10, width: 200, height: 24)
    )

    @Test("A typing step names its field")
    func namedField() throws {
        let draft = PlannedStepDraft(kind: .typeText, subject: "Chris", field: "e2", rationale: "name")
        let step = try decoder.decode(draft, context: desktop(elements: [name]))
        #expect(step.action == .typeText("Chris", into: name))
    }

    @Test("Typing blind into a window with unfocused fields is refused")
    func blindTypingRefused() {
        let draft = PlannedStepDraft(kind: .typeText, subject: "Chris", rationale: "name")
        #expect(throws: IntelligenceError.self) { try decoder.decode(draft, context: desktop(elements: [name])) }
    }

    @Test("Typing into the field that already has focus needs no name")
    func focusedFieldAllowed() throws {
        let focused = ElementReference(
            id: "e2", role: "AXTextField", title: "Name",
            frame: CGRect(x: 10, y: 10, width: 200, height: 24), isFocused: true
        )
        let draft = PlannedStepDraft(kind: .typeText, subject: "Chris", rationale: "name")
        #expect(try decoder.decode(draft, context: desktop(elements: [focused])).action == .typeText("Chris"))
    }

    @Test("Typing into a window with no readable fields is allowed")
    func canvasAllowed() throws {
        let draft = PlannedStepDraft(kind: .typeText, subject: "hello", rationale: "draw")
        #expect(try decoder.decode(draft, context: desktop(elements: [])).action == .typeText("hello"))
    }

    @Test("A field labelled as a password is protected even if it is not a secure field")
    func passwordLabelledField() {
        let field = ElementReference(
            id: "p", role: "AXTextField", title: "Password", frame: CGRect(x: 0, y: 0, width: 100, height: 20)
        )
        #expect(
            SensitiveActionDetector().classify(.typeText("hunter2", into: field)).classification == .restricted
        )
    }

    @Test("Typing is verified in the named field, found again by its label")
    func verifiesNamedField() throws {
        let after = ElementReference(
            id: "e9", role: "AXTextField", title: "Name", value: "Chris",
            frame: CGRect(x: 10, y: 10, width: 200, height: 24)
        )
        let result = try #require(
            Verifier.deterministicVerdict(
                action: .typeText("Chris", into: name),
                before: desktop(elements: [name]),
                after: desktop(elements: [after])
            )
        )
        #expect(result.outcome == .succeeded)
    }
}

@Suite("The subject field")
struct SubjectTests {
    private let decoder = PlannedStepDecoder()

    @Test("A step whose subject is empty or 'none' is refused where it needs one", arguments: ["", "none", "  ", "N/A"])
    func emptySubjects(subject: String) {
        let draft = PlannedStepDraft(kind: .openApplication, subject: subject, rationale: "open")
        #expect(throws: IntelligenceError.self) { try decoder.decode(draft, context: desktop()) }
    }

    @Test(
        "Shortcuts are read however they are written",
        arguments: [
            ("cmd+s", Key.character("s"), [ModifierKey.command]),
            ("Command + Shift + Z", .character("z"), [.shift, .command]),
            ("\u{21E7}\u{2318}S", .character("s"), [.shift, .command]),
            ("return", .returnKey, []),
        ]
    )
    func parsesShortcuts(text: String, key: Key, modifiers: [ModifierKey]) throws {
        let (parsedKey, parsedModifiers) = try PlannedStepDecoder.parseShortcut(text)
        #expect(parsedKey == key)
        #expect(Set(parsedModifiers) == Set(modifiers))
    }

    @Test("A pressKey written as a shortcut becomes a hotkey")
    func pressKeyWithModifiers() throws {
        let draft = PlannedStepDraft(kind: .pressKey, subject: "cmd+n", rationale: "new")
        #expect(try decoder.decode(draft, context: desktop()).action == .hotkey(key: .character("n"), modifiers: [.command]))
    }

    @Test("Modifiers given both ways are combined, not duplicated")
    func combinedModifiers() throws {
        let draft = PlannedStepDraft(kind: .hotkey, subject: "cmd+s", modifiers: [.command, .shift], rationale: "save as")
        let action = try decoder.decode(draft, context: desktop()).action
        guard case .hotkey(let key, let modifiers) = action else {
            Issue.record("expected a hotkey, got \(action)"); return
        }
        #expect(key == .character("s"))
        #expect(modifiers.count == 2 && Set(modifiers) == [.command, .shift])
    }

    @Test("A position is read however it is written", arguments: ["400, 300", "(400,300)", "x=400 y=300", "400 300"])
    func parsesPositions(text: String) {
        #expect(PlannedStepDecoder.parsePoint(text) == CGPoint(x: 400, y: 300))
    }

    @Test("A position with one number is refused")
    func incompletePosition() {
        let draft = PlannedStepDraft(kind: .clickPosition, subject: "400", rationale: "click")
        #expect(throws: IntelligenceError.self) { try decoder.decode(draft, context: desktop()) }
    }

    @Test("Typed text keeps its spaces")
    func typedTextIsNotTrimmed() throws {
        let draft = PlannedStepDraft(kind: .typeText, subject: " two words ", rationale: "type")
        #expect(try decoder.decode(draft, context: desktop()).action == .typeText(" two words "))
    }

    @Test("A button named as the place to type is ignored, not clicked")
    func buttonIsNotATypingField() throws {
        // Calculator: the model named the Equals button as the field.
        let equals = ElementReference(
            id: "e9", role: "AXButton", title: "Equals",
            frame: CGRect(x: 0, y: 0, width: 40, height: 40), actions: ["AXPress"]
        )
        let draft = PlannedStepDraft(kind: .typeText, subject: "12*7=", field: "e9", rationale: "compute")
        #expect(try decoder.decode(draft, context: desktop(elements: [equals])).action == .typeText("12*7="))
    }
}
