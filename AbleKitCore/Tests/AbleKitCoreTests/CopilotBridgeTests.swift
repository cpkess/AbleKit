import CoreGraphics
import Foundation
import Testing

@testable import AbleKitCore

/// A Copilot whose interface is scripted reading by reading.
private final class FakeCopilotSurface: CopilotSurface, @unchecked Sendable {
    var isInstalled = true
    var readings: [CopilotInterface]
    var enterPromptError: (any Error)?
    var selectModeError: (any Error)?

    private(set) var activated = false
    private(set) var enteredPrompt: String?
    private(set) var submitted = false
    private(set) var selectedMode: CopilotMode?
    private var index = 0

    init(readings: [CopilotInterface]) {
        self.readings = readings
    }

    func activate() async throws { activated = true }

    func readInterface() async throws -> CopilotInterface {
        defer { index += 1 }
        return readings[min(index, readings.count - 1)]
    }

    func enterPrompt(_ text: String, into field: ElementReference) async throws {
        if let enterPromptError { throw enterPromptError }
        enteredPrompt = text
    }

    func submit(_ interface: CopilotInterface) async throws { submitted = true }

    func selectMode(_ mode: CopilotMode, using control: ElementReference) async throws {
        if let selectModeError { throw selectModeError }
        selectedMode = mode
    }
}

/// A clock that jumps forward instead of waiting, so a two-minute timeout tests instantly.
private final class FakeClock: BridgeClock, @unchecked Sendable {
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { instant }
    func sleep(for duration: Duration) async throws {
        instant = instant.advanced(by: duration)
    }
}

private let composer = ElementReference(
    id: "composer", role: "AXTextField", title: "Ask Copilot",
    frame: CGRect(x: 100, y: 700, width: 600, height: 40), isFocused: true
)

private func interface(
    response: String = "",
    busy: Bool = false,
    researcher: ElementReference? = nil
) -> CopilotInterface {
    CopilotInterface(
        promptField: composer,
        responseText: response,
        isBusy: busy,
        researcherControl: researcher
    )
}

@Suite("Copilot bridge")
struct CopilotBridgeTests {

    @Test("A question is typed, sent, and its settled answer returned")
    func happyPath() async throws {
        let surface = FakeCopilotSurface(readings: [
            interface(),  // initial read
            interface(busy: true),  // started working
            interface(response: "Milestone 2", busy: true),
            interface(response: "Milestone 2 slipped a week."),
            interface(response: "Milestone 2 slipped a week."),
            interface(response: "Milestone 2 slipped a week."),
        ])
        let bridge = CopilotBridge(surface: surface, clock: FakeClock())

        let result = try await bridge.ask(prompt: "What is the status?", context: BridgeContext())

        #expect(surface.activated)
        #expect(surface.enteredPrompt == "What is the status?")
        #expect(surface.submitted)
        #expect(result.text == "Milestone 2 slipped a week.")
        #expect(result.mode == .standard)
    }

    @Test("Only the new part of the transcript is returned")
    func stripsExistingConversation() async throws {
        let existing = "Earlier question\nEarlier answer"
        let surface = FakeCopilotSurface(readings: [
            interface(response: existing),
            interface(response: existing, busy: true),
            interface(response: existing + "\nThe new answer."),
            interface(response: existing + "\nThe new answer."),
            interface(response: existing + "\nThe new answer."),
        ])
        let bridge = CopilotBridge(surface: surface, clock: FakeClock())

        let result = try await bridge.ask(prompt: "and now?", context: BridgeContext())

        #expect(result.text == "The new answer.")
    }

    @Test("An answer that never arrives times out rather than returning nothing as success")
    func timesOut() async {
        let surface = FakeCopilotSurface(readings: [interface(busy: true)])
        let bridge = CopilotBridge(surface: surface, clock: FakeClock())

        await #expect(throws: AIBridgeError.timedOut(.seconds(5))) {
            _ = try await bridge.ask(
                prompt: "hello", context: BridgeContext(timeout: .seconds(5))
            )
        }
    }

    @Test("A missing prompt field is reported, not guessed around")
    func missingPromptField() async {
        let surface = FakeCopilotSurface(readings: [CopilotInterface()])
        let bridge = CopilotBridge(surface: surface, clock: FakeClock())

        await #expect(throws: AIBridgeError.promptFieldNotFound) {
            _ = try await bridge.ask(prompt: "hello", context: BridgeContext())
        }
    }

    @Test("Copilot not being installed is reported plainly")
    func notInstalled() async {
        let surface = FakeCopilotSurface(readings: [interface()])
        surface.isInstalled = false
        let bridge = CopilotBridge(surface: surface, clock: FakeClock())

        await #expect(throws: AIBridgeError.self) {
            _ = try await bridge.ask(prompt: "hello", context: BridgeContext())
        }
    }

    @Test("Research mode is used when the interface offers it")
    func usesResearcherMode() async throws {
        let control = ElementReference(
            id: "r", role: "AXButton", title: "Researcher",
            frame: CGRect(x: 10, y: 10, width: 80, height: 20), actions: ["AXPress"]
        )
        let surface = FakeCopilotSurface(readings: [
            interface(researcher: control),
            interface(researcher: control),
            interface(busy: true),
            interface(response: "A researched answer."),
            interface(response: "A researched answer."),
            interface(response: "A researched answer."),
        ])
        let bridge = CopilotBridge(surface: surface, clock: FakeClock())

        let result = try await bridge.ask(
            prompt: "research this", context: BridgeContext(mode: .researcher)
        )

        #expect(surface.selectedMode == .researcher)
        #expect(result.mode == .researcher)
        #expect(result.modeFallbackReason == nil)
    }

    @Test("A build with no research mode says so instead of passing off a standard answer")
    func reportsResearcherUnavailable() async throws {
        let surface = FakeCopilotSurface(readings: [
            interface(),
            interface(busy: true),
            interface(response: "A standard answer."),
            interface(response: "A standard answer."),
            interface(response: "A standard answer."),
        ])
        let bridge = CopilotBridge(surface: surface, clock: FakeClock())

        let result = try await bridge.ask(
            prompt: "research this", context: BridgeContext(mode: .researcher)
        )

        #expect(result.mode == .standard)
        #expect(result.modeFallbackReason?.contains("no research mode") == true)
    }

    @Test("Shared desktop context is labelled in the prompt, and only as text")
    func composesPromptWithContext() {
        let composed = CopilotBridge.composePrompt(
            "What needs updating?", sharedContext: "Programme: Atlas\nStatus: Amber"
        )
        #expect(composed.contains("What needs updating?"))
        #expect(composed.contains("Context from my screen:"))
        #expect(composed.contains("Programme: Atlas"))
    }

    @Test("A prompt with no shared context is sent unchanged")
    func composesPromptWithoutContext() {
        #expect(CopilotBridge.composePrompt("Hello", sharedContext: nil) == "Hello")
        #expect(CopilotBridge.composePrompt("Hello", sharedContext: "  ") == "Hello")
    }

    @Test("When the transcript has reflowed, the whole text is returned rather than a guess")
    func newContentFallsBackToWholeText() {
        let result = CopilotBridge.newContent(in: "Entirely different", after: "Old baseline")
        #expect(result == "Entirely different")
    }
}

@Suite("Answer completion detection")
struct ResponseStabilityDetectorTests {

    @Test("An answer is complete once it stops changing")
    func settlesWhenStable() {
        var detector = ResponseStabilityDetector(requiredStableReadings: 3)
        #expect(detector.observe(text: "Part", isBusy: false) == .pending)
        #expect(detector.observe(text: "Part one", isBusy: false) == .pending)
        #expect(detector.observe(text: "Part one", isBusy: false) == .pending)
        #expect(detector.observe(text: "Part one", isBusy: false) == .settled("Part one"))
    }

    @Test("A pause between tokens is not the end of the answer")
    func busyPreventsSettling() {
        var detector = ResponseStabilityDetector(requiredStableReadings: 2)
        #expect(detector.observe(text: "Half", isBusy: true) == .pending)
        #expect(detector.observe(text: "Half", isBusy: true) == .pending)
        #expect(detector.observe(text: "Half", isBusy: true) == .pending)
        // Only once the interface stops working does stability start counting.
        #expect(detector.observe(text: "Half", isBusy: false) == .pending)
        #expect(detector.observe(text: "Half", isBusy: false) == .settled("Half"))
    }

    @Test("An empty transcript never settles")
    func emptyNeverSettles() {
        var detector = ResponseStabilityDetector(requiredStableReadings: 2)
        for _ in 0..<5 {
            #expect(detector.observe(text: "", isBusy: false) == .pending)
        }
        #expect(detector.observedText == nil)
    }
}

@Suite("Reading Copilot's interface")
struct CopilotInterfaceReaderTests {
    private let reader = CopilotInterfaceReader()

    private func snapshot(_ elements: [ElementReference]) -> AccessibilitySnapshot {
        AccessibilitySnapshot(bundleIdentifier: "com.microsoft.copilot", elements: elements)
    }

    @Test("The focused text field is taken as the composer")
    func prefersFocusedField() {
        let other = ElementReference(
            id: "search", role: "AXTextField", title: "Search",
            frame: CGRect(x: 0, y: 0, width: 200, height: 24)
        )
        let result = reader.read(snapshot([other, composer]))
        #expect(result.promptField?.id == "composer")
    }

    @Test("Failing that, a field whose label hints at asking")
    func fallsBackToLabelHint() {
        let ask = ElementReference(
            id: "ask", role: "AXTextField", title: "Message Copilot",
            frame: CGRect(x: 0, y: 500, width: 400, height: 30)
        )
        let unrelated = ElementReference(
            id: "other", role: "AXTextField", title: "Filename",
            frame: CGRect(x: 0, y: 100, width: 200, height: 24)
        )
        let result = reader.read(snapshot([unrelated, ask]))
        #expect(result.promptField?.id == "ask")
    }

    @Test("Failing that, the lowest field on screen, where composers live")
    func fallsBackToLowestField() {
        let top = ElementReference(
            id: "top", role: "AXTextField", title: "A",
            frame: CGRect(x: 0, y: 100, width: 200, height: 24)
        )
        let bottom = ElementReference(
            id: "bottom", role: "AXTextField", title: "B",
            frame: CGRect(x: 0, y: 800, width: 200, height: 24)
        )
        let result = reader.read(snapshot([top, bottom]))
        #expect(result.promptField?.id == "bottom")
    }

    @Test("A stop button means an answer is still streaming")
    func detectsBusy() {
        let stop = ElementReference(
            id: "stop", role: "AXButton", title: "Stop responding",
            frame: CGRect(x: 600, y: 700, width: 60, height: 24), actions: ["AXPress"]
        )
        #expect(reader.read(snapshot([composer, stop])).isBusy)
        #expect(!reader.read(snapshot([composer])).isBusy)
    }

    @Test("The transcript is read in order and excludes the composer")
    func readsTranscript() {
        let first = ElementReference(
            id: "t1", role: "AXStaticText", title: nil, value: "Question?",
            frame: CGRect(x: 100, y: 100, width: 400, height: 20)
        )
        let second = ElementReference(
            id: "t2", role: "AXStaticText", title: nil, value: "Answer.",
            frame: CGRect(x: 100, y: 140, width: 400, height: 20)
        )
        let result = reader.read(snapshot([second, first, composer]))
        #expect(result.responseText == "Question?\nAnswer.")
    }

    @Test("An interface that matches nothing yields no prompt field, not a wrong one")
    func unrecognisedInterface() {
        let button = ElementReference(
            id: "b", role: "AXButton", title: "Quit",
            frame: CGRect(x: 0, y: 0, width: 40, height: 20), actions: ["AXPress"]
        )
        #expect(reader.read(snapshot([button])).promptField == nil)
    }
}
