import AppKit
import Foundation

/// Interprets an Accessibility snapshot as Copilot's chat interface.
///
/// Chat applications are built from ordinary controls, so finding "the prompt field" is a matter of
/// recognising a shape: one text input near the bottom, a send button beside it, a transcript
/// above, and a stop button that appears only while an answer is streaming.
///
/// The heuristics are a pure function of a snapshot, which is what makes them testable — and they
/// will need it, because chat interfaces are redesigned often. When the shape stops matching,
/// `CopilotBridge` reports that it could not find the prompt field rather than typing somewhere
/// unpredictable.
public struct CopilotInterfaceReader: Sendable {

    /// Labels that mark the control which sends a message.
    static let submitLabels = ["send", "submit", "send message", "send prompt"]
    /// Labels that only appear while an answer is being produced.
    static let busyLabels = ["stop", "stop generating", "stop responding", "cancel response"]
    /// Labels that switch Copilot into its deeper research mode.
    static let researcherLabels = ["researcher", "deep research", "research"]
    /// Words that mark a text field as the place a question goes.
    static let promptHints = ["ask", "message", "prompt", "chat", "copilot", "talk", "type"]

    public init() {}

    public func read(_ snapshot: AccessibilitySnapshot) -> CopilotInterface {
        let elements = snapshot.elements

        return CopilotInterface(
            promptField: Self.findPromptField(in: elements),
            submitControl: Self.findControl(in: elements, labelled: Self.submitLabels),
            responseText: Self.transcript(in: elements),
            isBusy: Self.findControl(in: elements, labelled: Self.busyLabels) != nil,
            researcherControl: Self.findControl(in: elements, labelled: Self.researcherLabels)
        )
    }

    /// Finds the field a question is typed into.
    ///
    /// Preference order matters. A focused text input is almost certainly the prompt, because a
    /// chat window puts the cursor there. Failing that, one whose label hints at asking. Failing
    /// that, the lowest text input on screen — chat composers sit at the bottom.
    static func findPromptField(in elements: [ElementReference]) -> ElementReference? {
        let inputs = elements.filter { $0.isTextInput && $0.isEnabled && $0.frame.height > 0 }
        guard !inputs.isEmpty else { return nil }

        if let focused = inputs.first(where: \.isFocused) { return focused }

        if let hinted = inputs.first(where: { input in
            guard let label = input.bestLabel?.lowercased() else { return false }
            return Self.promptHints.contains { label.contains($0) }
        }) {
            return hinted
        }

        return inputs.max { $0.frame.minY < $1.frame.minY }
    }

    static func findControl(in elements: [ElementReference], labelled labels: [String])
        -> ElementReference?
    {
        elements.first { element in
            guard element.isEnabled, !element.actions.isEmpty else { return false }
            guard let label = element.bestLabel?.lowercased().trimmed else { return false }
            return labels.contains(label) || labels.contains { label.hasPrefix($0) }
        }
    }

    /// The conversation text on screen.
    ///
    /// Assembled from the static text above the composer, in reading order. Controls are excluded
    /// so that button labels and toolbar titles do not end up inside the answer.
    static func transcript(in elements: [ElementReference]) -> String {
        let composerTop = findPromptField(in: elements)?.frame.minY ?? .greatestFiniteMagnitude

        return elements
            .filter { element in
                // A read-only transcript is an AXTextArea in some builds and static text in
                // others; the composer is excluded by position rather than by role, since it is
                // usually an AXTextArea too.
                (element.role == "AXStaticText" || element.role == "AXTextArea")
                    && element.frame.minY < composerTop
                    && element.frame.height > 0
            }
            .sorted { lhs, rhs in
                if abs(lhs.frame.minY - rhs.frame.minY) > 4 { return lhs.frame.minY < rhs.frame.minY }
                return lhs.frame.minX < rhs.frame.minX
            }
            .compactMap { $0.value ?? $0.title }
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// Drives Copilot through the Accessibility APIs.
///
/// Accessibility is preferred over clicking positions here for the same reason it is everywhere
/// else, and more so: a chat window's layout shifts as the conversation grows, so a coordinate
/// recorded a second ago is worth very little.
public struct AccessibilityCopilotSurface: CopilotSurface {

    private let locator: ApplicationLocator
    private let accessibility: AccessibilityService
    private let keyboard: KeyboardController
    private let reader: CopilotInterfaceReader
    private let reference: ApplicationReference

    public init(
        reference: ApplicationReference = ApplicationReference(name: "Copilot"),
        locator: ApplicationLocator = ApplicationLocator(),
        accessibility: AccessibilityService = AccessibilityService(),
        keyboard: KeyboardController = KeyboardController(),
        reader: CopilotInterfaceReader = CopilotInterfaceReader()
    ) {
        self.reference = reference
        self.locator = locator
        self.accessibility = accessibility
        self.keyboard = keyboard
        self.reader = reader
    }

    public var isInstalled: Bool {
        locator.applicationURL(for: reference) != nil
    }

    public func activate() async throws {
        if let running = locator.runningApplication(matching: reference) {
            running.activate()
        } else {
            guard let url = locator.applicationURL(for: reference) else {
                throw AIBridgeError.unavailable("Microsoft Copilot is not installed.")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        // A window that has just come forward is not yet readable; its Accessibility tree fills in
        // a moment later.
        try await Task.sleep(for: .milliseconds(600))
    }

    public func readInterface() async throws -> CopilotInterface {
        guard let processIdentifier = processIdentifier() else {
            throw AIBridgeError.unavailable("Copilot is not running.")
        }
        let snapshot = await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                continuation.resume(
                    returning: accessibility.snapshot(
                        processIdentifier: processIdentifier,
                        bundleIdentifier: reference.bundleIdentifier,
                        maximumElements: 400,
                        maximumDepth: 16
                    )
                )
            }
        }
        return reader.read(snapshot)
    }

    public func enterPrompt(_ text: String, into field: ElementReference) async throws {
        guard let processIdentifier = processIdentifier() else {
            throw AIBridgeError.unavailable("Copilot is not running.")
        }
        do {
            try accessibility.focus(field, processIdentifier: processIdentifier)
        } catch {
            throw AIBridgeError.promptFieldNotFound
        }
        // Typed rather than assigned: chat composers commonly watch for input events to enable
        // their send button, and a value set straight onto the field leaves it disabled.
        try keyboard.type(text)
    }

    public func submit(_ interface: CopilotInterface) async throws {
        guard let processIdentifier = processIdentifier() else {
            throw AIBridgeError.unavailable("Copilot is not running.")
        }
        if let control = interface.submitControl, control.isPressable {
            try accessibility.perform("AXPress", on: control, processIdentifier: processIdentifier)
            return
        }
        // No send button exposed, which is common; Return is the universal fallback in a composer.
        try keyboard.press(.returnKey)
    }

    public func selectMode(_ mode: CopilotMode, using control: ElementReference) async throws {
        guard mode == .researcher else { return }
        guard let processIdentifier = processIdentifier() else {
            throw AIBridgeError.unavailable("Copilot is not running.")
        }
        guard control.isPressable else {
            throw AIBridgeError.unavailable("Copilot's research mode could not be switched on.")
        }
        try accessibility.perform("AXPress", on: control, processIdentifier: processIdentifier)
        try await Task.sleep(for: .milliseconds(400))
    }

    private func processIdentifier() -> pid_t? {
        locator.runningApplication(matching: reference)?.processIdentifier
    }
}
